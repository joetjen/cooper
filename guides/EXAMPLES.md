# Examples

The [tutorial](TUTORIAL.md) builds one example — an orders service
config — up from nothing. This page walks through several more,
each focused on one thing you're likely to actually need `Cooper` for.
For examples focused on CASC *syntax* rather than the surrounding
Elixir, see [CASC_EXAMPLES.md](casc/CASC_EXAMPLES.md).

## Application config with a real secrets manager

The common shape: config loaded once at boot, with secrets fetched
from wherever your organization actually keeps them, never landing in
source control or a log line.

```elixir
defmodule MyApp.Config do
  def load! do
    resolvers = %{"vault" => &fetch_from_vault/1}

    case Cooper.load_file("config/app.casc", resolvers: resolvers) do
      {:ok, config} -> config
      {:error, %Ichor.Error{} = error} -> raise "invalid config: #{error.message}"
    end
  end

  defp fetch_from_vault(path) do
    case MyVaultClient.read(path) do
      {:ok, %{"value" => value}} -> {:ok, value}
      {:error, reason} -> {:error, "vault read failed: #{inspect(reason)}"}
    end
  end
end
```

```casc
#@version = 1.0

database {
  *password = !{vault:secret/data/orders-db#password}
  host = "db.internal"
  pool_size = !int(${DB_POOL_SIZE:10})
}
```

`config["database"]["password"]` comes back wrapped in
`Cooper.Secret` — safe to hold in application state and pass around;
`Cooper.Secret.reveal/1` is the one deliberate step needed to use the
real value (e.g. building an `Ecto.Repo` connection string).

## Layering base config with per-environment overlays

```casc
# config/base.casc
#@version = 1.0

server { host = "0.0.0.0", port = 8080 }
log_level = info
feature_flags.new_checkout = false
```

```casc
# config/prod.casc
#@version = 1.0

import "base.casc"

~server { port = 443 }
log_level = warning
feature_flags.new_checkout = true
```

```elixir
iex> Cooper.load_file("config/prod.casc")
{:ok,
 %{
   "server" => %{"port" => 443},
   "log_level" => :warning,
   "feature_flags" => %{"new_checkout" => true}
 }}
```

`import` splices `base.casc`'s statements in first; every statement
in `prod.casc` after it — including `~server { port = 443 }`, which
replaces the whole block rather than merging — overrides the base at
the same path. Adding `config/staging.casc` alongside `prod.casc`, each
importing `base.casc` and overriding just what differs, avoids
duplicating the shared two-thirds of the file across every environment.

For per-environment *values* rather than whole config files —
`${DB_PASSWORD}` differing per environment, not `server.port` — a
`.env.<env>` file does the same job without a second `.casc` file at
all; see the tutorial's [§11](TUTORIAL.md#11-env-files).

## Testing config-loading code without touching disk or the network

Every option that would otherwise reach for the real filesystem, OS
environment, or an external service is a plain function or map — which
means a config loader can be unit-tested the same way as any other pure
function, no fixtures directory or mocking library required:

```elixir
defmodule MyApp.ConfigTest do
  use ExUnit.Case, async: true

  test "prod overlay raises the connection pool and disables debug routes" do
    source = """
    #@version = 1.0

    import "mem://base"

    pool_size = !int(${POOL_SIZE:20})
    """

    schemes = %{
      "mem" => fn "base" ->
        {:ok, "#@version = 1.0\npool_size = 5\ndebug_routes = true\n"}
      end
    }

    assert {:ok, config} =
             Cooper.load_string(source,
               import_schemes: schemes,
               env: %{"POOL_SIZE" => "50"}
             )

    assert config == %{"pool_size" => 50, "debug_routes" => true}
  end
end
```

No real file named `base.casc` exists anywhere — `mem://base` is
resolved entirely in memory by the test's own `schemes` map.
`POOL_SIZE` specifically is guaranteed to be `"50"` regardless of the
real environment or any `.env` file, because `:env` always wins for a
name it defines — see the tutorial's [§11](TUTORIAL.md#11-env-files)
for why that's an override, not full isolation, and doesn't extend to
`${...}` names a test's `:env` map doesn't mention.

## IP allowlisting with real CIDR math

```casc
#@version = 1.0

allowed_networks = [10.0.0.0/8, 192.168.1.0/24, 203.0.113.7/32]
```

```elixir
defmodule MyApp.AccessControl do
  def allowed?(config, %Cooper.IPv4{} = candidate) do
    Enum.any?(config["allowed_networks"], &Cooper.IPv4.contains?(&1, candidate))
  end
end
```

```elixir
iex> {:ok, config} = Cooper.load_string(source)
iex> {:ok, request_ip} = Cooper.IPv4.new({10, 1, 2, 3})
iex> MyApp.AccessControl.allowed?(config, request_ip)
true
```

Every address in `allowed_networks` is a real `%Cooper.IPv4{}`,
validated at load time (a malformed address or an out-of-range CIDR
prefix is a load-time error, never a crash reachable by a bad config
file) — `contains?/2` does genuine bitwise network-membership math, not
a string prefix comparison.

## Generating per-shard config from one template

```casc
#@version = 1.0

defaults.shard {
  replicas = 1
  memory_limit = 512MiB
}

@shard_names = ["orders", "inventory", "billing"]
@shard_replicas = [3, 2, 1]

for @name in @{shard_names}, @replicas in @{shard_replicas}
  from defaults.shard as shards."@{name}" {
  replicas = @{replicas}
}
```

```elixir
iex> Cooper.load_string(source)
{:ok,
 %{
   "defaults" => %{"shard" => %{"replicas" => 1, "memory_limit" => {:bytes, 536_870_912}}},
   "shards" => %{
     "orders" => %{"replicas" => 3, "memory_limit" => {:bytes, 536_870_912}},
     "inventory" => %{"replicas" => 2, "memory_limit" => {:bytes, 536_870_912}},
     "billing" => %{"replicas" => 1, "memory_limit" => {:bytes, 536_870_912}}
   }
 }}
```

Each of the three shards starts as a full copy of `defaults.shard`
(`memory_limit` carries through unchanged to every one), with only
`replicas` overridden per shard from the parallel `@shard_replicas`
list — adding a fourth shard is one more entry in each of the two
lists, not a fourth copy-pasted block.

## A consumer-defined tagged value

Built-in tags (`!int`, `!float`, `!bool`, `!duration`, `!bytes`) cover
type coercion; `:tags` extends the same `!Name(arg)` syntax to your own
vocabulary — a real UUID validator here, not just a string pass-through:

```casc
#@version = 1.0

request_id = !uuid("550e8400-e29b-41d4-a716-446655440000")
```

```elixir
tags = %{
  "uuid" => fn arg ->
    case UUID.info(arg) do
      {:ok, _} -> {:ok, arg}
      {:error, reason} -> {:error, "invalid UUID: #{reason}"}
    end
  end
}

iex> Cooper.load_string(source, tags: tags)
{:ok, %{"request_id" => "550e8400-e29b-41d4-a716-446655440000"}}
```

A config file using `!uuid(...)` without `:tags` registered fails to
load with a load-time error naming `"uuid"` — never silently treated
as an opaque string.

## Turning a load failure into an actionable message

Every stage returns `{:error, %Ichor.Error{}}` rather than raising, so
a caller decides what "actionable" means for its own context — here,
a `mix` task exiting with a message pointing at the exact file and
line, instead of an Elixir stack trace:

```elixir
defmodule Mix.Tasks.Config.Validate do
  use Mix.Task

  def run([path]) do
    case Cooper.load_file(path) do
      {:ok, _config} ->
        Mix.shell().info("#{path}: OK")

      {:error, errors} ->
        errors
        |> List.wrap()
        |> Enum.each(fn %Ichor.Error{stage: stage, message: message, line: line} ->
          location = if line, do: "#{path}:#{line}", else: path
          Mix.shell().error("#{location} [#{stage}]: #{message}")
        end)

        Mix.raise("config validation failed")
    end
  end
end
```

`{:error, ...}` may be a single `Ichor.Error` or a list of them (the
parser's own multi-error recovery for a syntax error) — `List.wrap/1`
handles both uniformly rather than branching on shape.
