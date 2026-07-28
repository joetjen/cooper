# CASC Examples

Focused examples of individual CASC features, each a complete, valid
file small enough to read in one go. Every snippet is verified with
`Cooper.load_string/2`. For a walkthrough that introduces these one at
a time, see the [tutorial](TUTORIAL.md); for the exhaustive rules
behind any one of them, see [CASC.md](CASC.md). For examples of using
the `Cooper` *library* around a file like these (custom resolvers,
imports, testing patterns), see [Cooper's own examples](../EXAMPLES.md).

## Three equivalent ways to write the same tree

```casc
#@version = 1.0

logger.console.colors.enabled = true
```

```casc
#@version = 1.0

logger {
  console {
    colors.enabled = true
  }
}
```

```casc
#@version = 1.0

logger = { console = { colors = { enabled = true } } }
```

```elixir
iex> Cooper.load_string(source)
{:ok, %{"logger" => %{"console" => %{"colors" => %{"enabled" => true}}}}}
```

All three (and any mix of them) desugar to the identical tree before
merge ever runs (CASC.md §5.4) — pick whichever reads best for a given
shape; a deeply nested value often reads better as a dotted path, a key
with several siblings often reads better as a block.

## Quoted keys, for anything that isn't a plain identifier

```casc
#@version = 1.0

headers = {
  "Content-Type" = "application/json"
  "X-Request-Id" = "req-@{id}"
}

@id = "abc123"
```

```elixir
iex> Cooper.load_string(source)
{:ok,
 %{
   "headers" => %{
     "Content-Type" => "application/json",
     "X-Request-Id" => "req-abc123"
   }
 }}
```

A double-quoted key segment supports interpolation exactly like a
double-quoted string value does (CASC.md §4.2) — the only way to reach
a `@{...}`-interpolated key, since bare identifier keys can't contain
one.

## Numeric literal forms

```casc
#@version = 1.0

decimal   = 42
hex       = 0xFF
octal     = 0o17
binary    = 0b1010
grouped   = 1_000_000
float     = 3.14
exponent  = 5e+3
negative  = -17
infinite  = inf
```

```elixir
iex> Cooper.load_string(source)
{:ok,
 %{
   "decimal" => 42, "hex" => 255, "octal" => 15, "binary" => 10,
   "grouped" => 1_000_000, "float" => 3.14, "exponent" => 5.0e3,
   "negative" => -17, "infinite" => :infinity
 }}
```

## Durations and byte sizes as real types, not strings

```casc
#@version = 1.0

quick_retry   = 250ms
session_ttl   = 1h30m
request_body  = 10MB
cache_size    = 512MiB
```

```elixir
iex> Cooper.load_string(source)
{:ok,
 %{
   "quick_retry" => {:duration, 250_000_000},
   "session_ttl" => {:duration, 5_400_000_000_000},
   "request_body" => {:bytes, 10_000_000},
   "cache_size" => {:bytes, 536_870_912}
 }}
```

`1h30m` is a valid compound literal (strictly descending, no repeated
unit); `30m1h` or `1.5h30m` would both be load-time errors (CASC.md
§6.8). `MB` (decimal, ×1000) and `MiB` (binary, ×1024) are genuinely
different values for the same numeral — pick the one your system
actually measures in.

## A secret nested several levels deep

```casc
#@version = 1.0

services.payment_gateway {
  *api_key = "sk_live_abcdef123456"
  endpoint = "https://payments.example.com"
  retries { max = 3, backoff = 500ms }
}
```

```elixir
iex> {:ok, config} = Cooper.load_string(source)
iex> config
%{
  "services" => %{
    "payment_gateway" => %{
      "api_key" => [~~REDACTED~~],
      "endpoint" => "https://payments.example.com",
      "retries" => %{"max" => 3, "backoff" => {:duration, 500_000_000}}
    }
  }
}
iex> Cooper.Secret.reveal(config["services"]["payment_gateway"]["api_key"])
"sk_live_abcdef123456"
```

`*` only marks the segment it's directly attached to — `endpoint` and
`retries` next to `*api_key` are ordinary values, not swept up by the
same marker (CASC.md §4.3).

## `~`/`+`/`-` overriding a block written elsewhere

```casc
#@version = 1.0

server { host = "0.0.0.0", port = 8080, tls { min_version = "1.2" } }
allowed_ips = ["10.0.0.1", "10.0.0.2"]

~server { port = 9090 }
+allowed_ips = ["10.0.0.3"]
-allowed_ips = ["10.0.0.1"]
```

```elixir
iex> Cooper.load_string(source)
{:ok,
 %{
   "server" => %{"port" => 9090},
   "allowed_ips" => ["10.0.0.2", "10.0.0.3"]
 }}
```

`~server { port = 9090 }` replaces the *entire* `server` subtree —
`host` and `tls` are gone, not merged underneath the new `port`
(CASC.md §5.7/§8.4). This is the same mechanism a later `import`
uses to override an earlier one at the same path.

## Generating parallel structure with a zipped loop

```casc
#@version = 1.0

@regions = ["us-east", "eu-west", "ap-south"]
@capacities = [100, 50, 25]

for @idx, @region in @{regions}, @cap in @{capacities}
  as pools."@{region}" {
  index = @{idx}
  capacity = @{cap}
}
```

```elixir
iex> Cooper.load_string(source)
{:ok,
 %{
   "pools" => %{
     "us-east" => %{"index" => 0, "capacity" => 100},
     "eu-west" => %{"index" => 1, "capacity" => 50},
     "ap-south" => %{"index" => 2, "capacity" => 25}
   }
 }}
```

Two element bindings (`@region`/`@cap`) iterate **in parallel**, by
index — not a cartesian product of every region against every capacity
(CASC.md §5.5). A length mismatch between `@regions` and `@capacities`
would be a load-time error naming both lists, never a silent
truncation.

## `from` — cloning a template with per-iteration overrides

```casc
#@version = 1.0

defaults.worker {
  cpu = 1
  memory_mb = 256
  restart_policy = always
}

@names = ["ingest", "transform", "export"]
for @name in @{names} from defaults.worker as workers."@{name}" {
  cpu = 2
}
```

```elixir
iex> Cooper.load_string(source)
{:ok,
 %{
   "defaults" => %{"worker" => %{"cpu" => 1, "memory_mb" => 256, "restart_policy" => :always}},
   "workers" => %{
     "ingest" => %{"cpu" => 2, "memory_mb" => 256, "restart_policy" => :always},
     "transform" => %{"cpu" => 2, "memory_mb" => 256, "restart_policy" => :always},
     "export" => %{"cpu" => 2, "memory_mb" => 256, "restart_policy" => :always}
   }
 }}
```

Each generated `workers.<name>` starts as a full copy of
`defaults.worker`, with the loop body's `cpu = 2` layered on top —
`memory_mb`/`restart_policy` fall through unchanged. `from` resolves
lazily against the *final* tree, so `defaults.worker` could equally be
defined later in the file, or in an import processed after this one.

## Config references resolving after every import and merge

```casc
#@version = 1.0

server.host = "api.internal"
server.port = 8080

health_check.url = "http://%{server.host}:%{server.port}/health"
metrics.url = "http://%{server.host}:%{server.port}/metrics"
admin_contact = %{ops.email:"ops@example.com"}

server.port = 9443
```

```elixir
iex> Cooper.load_string(source)
{:ok,
 %{
   "server" => %{"host" => "api.internal", "port" => 9443},
   "health_check" => %{"url" => "http://api.internal:9443/health"},
   "metrics" => %{"url" => "http://api.internal:9443/metrics"},
   "admin_contact" => "ops@example.com"
 }}
```

Both `%{server.host}`/`%{server.port}` references pick up `9443` — the
*post-override* value — even though they're written above the
`server.port = 9443` statement that changes it (an ordinary later
assignment deep-merges on top of `server`, so `host` survives
unchanged; a `~server { port = 9443 }` replace instead would have
cleared `host` along with it — see the sigil example above). `%{...}`
always resolves against the fully merged final tree, never eagerly at
the point it's written (CASC.md §7.3). `admin_contact` falls back to
its default since `ops.email` is never defined here.

## Extensible resolvers and tagged values together

```casc
#@version = 1.0

database {
  *password = !{vault:secret/data/db#password}
  host = "db.internal"
  port = !int(${DB_PORT:5432})
  pool_size = !int("20")
}
```

```elixir
iex> resolvers = %{"vault" => fn payload -> {:ok, "fetched:" <> payload} end}
iex> {:ok, config} = Cooper.load_string(source, resolvers: resolvers, env: %{})
iex> Cooper.Secret.reveal(config["database"]["password"])
"fetched:secret/data/db#password"
iex> config["database"]["port"]
5432
iex> config["database"]["pool_size"]
20
```

`!{vault:...}` dispatches by name to whatever function the caller
registers under `:resolvers`; `!int(...)` is one of the five built-in
tagged values, needing no registration at all — see
[CASC.md §9](CASC.md#9-extensibility) for the full extensibility model.

## A conditional statement, feature-flagged by environment

```casc
#@version = 1.0

app_name = "orders"

${?ENABLE_DEBUG_ROUTES}
debug_routes_enabled = true

log_level = ${LOG_LEVEL:info}
```

```elixir
iex> Cooper.load_string(source, env: %{"LOG_LEVEL" => "debug"})
{:ok, %{"app_name" => "orders", "log_level" => "debug"}}

iex> Cooper.load_string(source, env: %{"ENABLE_DEBUG_ROUTES" => "1", "LOG_LEVEL" => "debug"})
{:ok,
 %{"app_name" => "orders", "debug_routes_enabled" => true, "log_level" => "debug"}}
```

With `ENABLE_DEBUG_ROUTES` unset, `debug_routes_enabled = true` is
skipped entirely — not evaluated and discarded, genuinely never run, so
nothing inside a guarded statement can fail just because it was skipped
(CASC.md §7.2).
