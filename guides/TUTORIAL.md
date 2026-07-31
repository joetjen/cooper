# Cooper Tutorial

This tutorial builds up a small "orders service" config file, feature by
feature, until it exercises every part of CASC that Cooper implements.
By the end you'll know how to load config, handle secrets and errors,
and inject test-time environment/import values — and you'll have seen
enough CASC syntax to write and read real config files. For the full
language reference, see [CASC.md](casc/CASC.md); this tutorial only
introduces as much of it as the example needs.

## 1. The minimal file

Every CASC file needs a version header — a comment-shaped line that
also declares which version of the language the file is written
against:

```casc
#@version = 1.0
```

That alone is a complete, valid file:

```elixir
iex> Cooper.load_string("#@version = 1.0")
{:ok, %{}}
```

`Cooper.load_string/2` parses a CASC source string directly.
`Cooper.load_file/2` reads a file from disk first — use it for real
config files; `load_string/2` is convenient for tests and this
tutorial. Both return `{:ok, term()}` or `{:error, reason}`; see
[§6](#6-errors) for what `reason` looks like.

## 2. Plain values and blocks

Assignments look like ordinary key/value pairs. Nested blocks build
dotted paths automatically:

```casc
#@version = 1.0

app_name = "orders"
replicas = 3

server {
  host = "0.0.0.0"
  port = 8080
}
```

```elixir
iex> Cooper.load_string(source)
{:ok,
 %{
   "app_name" => "orders",
   "replicas" => 3,
   "server" => %{"host" => "0.0.0.0", "port" => 8080}
 }}
```

`server { host = ... }` and `server.host = ...` are equivalent — pick
whichever reads better for a given block. Values include the usual
scalars (strings, integers, floats, booleans, `nil`, atoms), plus a
few CASC-specific literals: dates/times, IP addresses/CIDRs, durations
(`500ms`, `1h30m`), and byte sizes (`512MiB`). Durations and byte sizes
come back as tagged tuples — `{:duration, nanoseconds}` and
`{:bytes, count}` — not bare integers, so they're never confused with
an ordinary number written in the same config. See
[CASC.md §6](casc/CASC.md) for the full literal grammar.

IP addresses are a real data type, not just parsed text — `127.0.0.1`
resolves to `%Cooper.IPv4{}`, `::1` to `%Cooper.IPv6{}`, both validated
at load time (an out-of-range octet or a CIDR prefix outside `0..32`/
`0..128` is a load-time error, never a crash). Both support CIDR
containment and network math directly:

```casc
#@version = 1.0

allowed_networks = [10.0.0.0/8, 192.168.1.0/24]
```

```elixir
iex> {:ok, config} = Cooper.load_string(source)
iex> [office, vpn] = config["allowed_networks"]
[#Cooper.IPv4<10.0.0.0/8>, #Cooper.IPv4<192.168.1.0/24>]
iex> {:ok, candidate} = Cooper.IPv4.new({10, 1, 2, 3})
iex> Cooper.IPv4.contains?(office, candidate)
true
```

See the [cheatsheet](CHEATSHEET.md) for the full `Cooper.IPv4`/
`Cooper.IPv6` API (`network/1`, `broadcast/1`, `first_host/1`,
`last_host/1`, `netmask/1`).

## 3. Variables and interpolation

`@name = value` declares a variable. It isn't itself part of the
output tree — it's only useful for reference elsewhere via `@{name}`:

```casc
#@version = 1.0

@region = "eu-west"

endpoint = "https://api.@{region}.example.com"
```

```elixir
iex> Cooper.load_string(source)
{:ok, %{"endpoint" => "https://api.eu-west.example.com"}}
```

`@{name}` also works as a bare, whole value (`region = @{other_var}`),
not just embedded in a string. `@*name = value` declares a *private*
variable — usable within the file (and files it imports, see §5), but
never inherited by whatever imports it back.

## 4. Environment references

`${NAME}` reads an OS (or injected, see §7) environment variable —
including one layered in from a `.env` file, on by default; see §11.
Unlike `@{...}`, it always resolves to a plain string — CASC never
guesses that a string "looks like" a number or boolean for you:

```casc
#@version = 1.0

region = ${REGION}
max_retries = !int(${MAX_RETRIES:3})
${?FEATURE_FLAG}
enabled = true
allowed_hosts = ${ALLOWED_HOSTS[]:["localhost"]}
```

With `REGION=eu-west` set and everything else unset:

```elixir
iex> Cooper.load_string(source, env: %{"REGION" => "eu-west"})
{:ok,
 %{"allowed_hosts" => ["localhost"], "max_retries" => 3, "region" => "eu-west"}}
```

A few things happened there:

- `${NAME:default}` falls back to `default` — parsed as an ordinary
  CASC value, so a bare `3` really is the integer `3`, not `"3"`.
- `!int(...)` is a **tagged value**: it wraps whatever's inside
  (typically a `${...}` read, since that's always a string) and
  converts it. `!int`, `!float`, `!bool`, `!duration`, and `!bytes`
  are built in; §5.5 of `Cooper`'s own docs covers registering more.
- `${?FEATURE_FLAG}` guards the *one statement that follows it* —
  with `FEATURE_FLAG` unset, `enabled = true` is skipped entirely
  (not evaluated-then-discarded — nothing inside a skipped statement
  can raise just because it happened to be skipped).
- `${NAME[]:default}` parses a set/unset env var as a comma-separated
  list.

## 5. Secrets

Prefixing any key segment with `*` marks it (and everything under it)
secret. Secret values load normally, but come back wrapped in
`Cooper.Secret`, which redacts itself on inspection:

```casc
#@version = 1.0

database {
  *password = ${DB_PASSWORD}
  host = "db.internal"
}
```

```elixir
iex> {:ok, config} = Cooper.load_string(source, env: %{"DB_PASSWORD" => "hunter2"})
iex> config
%{"database" => %{"host" => "db.internal", "password" => [~~REDACTED~~]}}
iex> IO.inspect(config)
%{"database" => %{"host" => "db.internal", "password" => [~~REDACTED~~]}}
iex> "connecting with #{config["database"]["password"]}"
"connecting with [~~REDACTED~~]"
iex> Cooper.Secret.reveal(config["database"]["password"])
"hunter2"
```

Both `inspect/1` and `to_string/1` redact unconditionally — there's no
"debug mode" flag to accidentally leave on in production. The only way
to get the real value is `Cooper.Secret.reveal/1` (or the struct's own
`:value` field), which makes "did I accidentally log a secret" a
type-level question you can grep for, not a runtime toggle you have to
trust everyone remembered to check.

The wrapping travels with the value, not just the key it was declared
at — a `%{...}` reference or a `for ... from` template that copies a
secret value somewhere else copies the wrapping right along with it,
so there's no path in the tree where the same underlying secret shows
up unprotected. And a secret embedded inside a *larger* interpolated
string only redacts its own portion, not the whole string — including
when more than one secret is interpolated into the same string, each
redacts independently at its own position:

```casc
url = "postgres://%{database.host}?password=%{database.password}"
```

```elixir
iex> config["url"]
"postgres://db.internal?password=[~~REDACTED~~]"
iex> Cooper.Secret.reveal(config["url"])
"postgres://db.internal?password=hunter2"
```

## 6. Errors

Every stage of loading can fail, and every failure comes back as
`{:error, %Ichor.Error{}}` (or a list of them, for the parser's own
multi-error recovery) — never a raised exception. `Ichor.Error`
carries a `:stage` telling you roughly where things went wrong
(`:lexer`, `:parser`, `:import`, `:merge`, `:resolve`, ...) alongside a
human-readable `:message`:

```elixir
iex> Cooper.load_string("#@version = 1.0\nvalue = !{missing:x}")
{:error,
 %Ichor.Error{message: "unregistered resolver \"missing\"", stage: :resolve, ...}}
```

Unregistered resolvers, unregistered tags, unregistered import
schemes, a `%{...}` reference cycle, and a mismatched-length loop
binding are all load-time errors naming the offender specifically —
Cooper never silently drops a reference or guesses at intent.

## 7. Imports and test-time injection

`import "path/to/file.casc"` splices another file's own statements in
at that point — later statements (including the importer's own,
following the import) override earlier ones at the same path, and any
*public* `@name` variable the imported file declares becomes visible
to the importer too:

```casc
#@version = 1.0

import "defaults.casc"

server.port = 9090
```

For a bare path, `Cooper.load_file/2` resolves relative imports
against the loaded file's own directory automatically; `load_string/2`
needs an explicit `:root` for that (or no imports at all).

You can also register your own `scheme://` import loader and resolver
functions — this is what makes it practical to unit-test config that
imports from, say, a secrets manager, without touching the filesystem
or a real network call:

```elixir
iex> source = """
...> #@version = 1.0
...> import "mem://extra"
...> app_name = "orders"
...> """
iex> schemes = %{"mem" => fn _rest -> {:ok, "#@version = 1.0\\nregion = \\"eu-west\\""} end}
iex> Cooper.load_string(source, import_schemes: schemes)
{:ok, %{"app_name" => "orders", "region" => "eu-west"}}
```

`:resolvers`/`:tags` work the same way — in-memory stand-ins for
whatever a real resolver would call out to, with no global state to set
up or tear down.

`:env` (every example in this tutorial already uses it) is a little
different: it's an **override**, not a replacement — see §11 for why
`env: %{"REGION" => "eu-west"}` guarantees `REGION` specifically but
doesn't isolate a test from the real environment or any `.env` file on
disk the way `:resolvers`/`import_schemes` do. Give every name a test
needs a deterministic value for its own explicit `:env` entry, rather
than relying on it being otherwise unset.

## 8. Merge control and loops

Later statements override earlier ones at the same path, and maps
deep-merge by default. A leading sigil on a key changes that:

```casc
#@version = 1.0

server { host = "0.0.0.0", port = 8080, tls { min_version = "1.2" } }
~server { port = 9090 }

tags = ["a", "b", "c"]
+tags = ["d"]
-tags = ["b"]
```

```elixir
iex> Cooper.load_string(source)
{:ok, %{"server" => %{"port" => 9090}, "tags" => ["a", "c", "d"]}}
```

`~key { ... }` replaces the *entire* subtree at `key`, not just the
fields the new block mentions — `host` and `tls` are gone, not merged.
`+`/`-` append/remove list elements by value. Tuples (CASC.md §6.11)
are never merged at all — only replaced wholesale — since Cooper has
no schema to know which position means what.

`for` loops generate many entries from one template:

```casc
#@version = 1.0

defaults.replica {
  cpu = 1
  memory_mb = 512
}

@instances = ["a", "b", "c"]
for @instance in @{instances} from defaults.replica as replicas."@{instance}" {
  cpu = 2
}
```

```elixir
iex> Cooper.load_string(source)
{:ok,
 %{
   "defaults" => %{"replica" => %{"cpu" => 1, "memory_mb" => 512}},
   "replicas" => %{
     "a" => %{"cpu" => 2, "memory_mb" => 512},
     "b" => %{"cpu" => 2, "memory_mb" => 512},
     "c" => %{"cpu" => 2, "memory_mb" => 512}
   }
 }}
```

Each generated `replicas.<instance>` starts as a copy of
`defaults.replica` (`from`, resolved lazily against the *final* merged
tree — it doesn't matter whether `defaults.replica` is written before
or after the loop), with the loop body layered on top as overrides.
See [CASC.md §5.5](casc/CASC.md) for parallel (zipped) multi-binding
loops and index bindings.

## 9. Config references

`%{path}` refers to another value in the *same, fully-merged* tree —
resolved lazily, after every import and merge, so it always sees the
final value regardless of where in the file (or which imported file)
the reference itself was written:

```casc
#@version = 1.0

server.host = "api.internal"
server.port = 8080
health_check.url = "http://%{server.host}:%{server.port}/health"
admin_email = %{contact.admin:"ops@example.com"}
```

```elixir
iex> Cooper.load_string(source)
{:ok,
 %{
   "admin_email" => "ops@example.com",
   "health_check" => %{"url" => "http://api.internal:8080/health"},
   "server" => %{"host" => "api.internal", "port" => 8080}
 }}
```

A `%{...}` cycle (directly or transitively referencing itself) is a
load-time error naming the full cycle path — never an infinite loop or
a silently partial value.

## 10. Putting it together

Everything above composes into one file and one call:

```casc
#@version = 1.0

@region = ${REGION:"eu-west"}

server {
  host = "0.0.0.0"
  port = !int(${PORT:8080})
}

database {
  *password = !{vault:secret/db/password}
  host = "db.@{region}.internal"
  timeout = 500ms
}

endpoints.health = "http://%{server.host}:%{server.port}/health"
```

```elixir
resolvers = %{"vault" => fn payload -> MyVault.fetch(payload) end}

case Cooper.load_file("config.casc", resolvers: resolvers) do
  {:ok, config} ->
    config

  {:error, %Ichor.Error{} = error} ->
    raise "invalid config: #{error.message}"
end
```

## 11. .env files

By default, `Cooper` layers `.env` files from the project root into
`${...}` resolution — no extra option needed. The full chain, later
winning:

```elixir
iex> Cooper.load_file("config.casc")
```

1. `System.get_env/0` — always the floor, whether or not `:env` is
   passed
2. `.env`
3. `.env.<env>` — `<env>` is `Mix.env/0` when Mix is loaded (pass
   `dotenv_env:` explicitly in a release, where Mix usually isn't
   available)
4. `.env.local` — a personal, usually-gitignored override
5. `:env`, if passed — always the final, highest-precedence override

A missing file (2-4) is never an error — `.env.<env>` in particular is
expected to be absent for every environment but the current one.

**`:env` overrides, it doesn't isolate.** `env: %{"REGION" =>
"eu-west"}` guarantees `REGION` resolves to `"eu-west"` — but any
`${...}` reference to a name *not* in that map still falls through to
`.env`/`.env.local`/the real OS environment, same as if `:env` weren't
passed at all:

```elixir
iex> Cooper.load_string(source, env: %{"REGION" => "eu-west"})
# REGION is guaranteed -- everything else still reads through to
# .env/.env.local/the real environment
```

`dotenv: false` disables just the `.env` file layers (2-4) —
`System.get_env/0` and `:env` still apply either way. `:dotenv_files`
fully replaces the default four-file list, for a non-standard layout.
This runs through the optional `:dotenvy` dependency — add
`{:dotenvy, "~> 1.1"}` to your own `mix.exs` deps. An explicit `dotenv:
true` without it installed is a load-time error naming it; the
*default*-enabled case just no-ops instead (same as no `.env` files
existing).

From here, [CASC.md](casc/CASC.md) is the full reference for anything
this tutorial only touched briefly, and the
[cheatsheet](CHEATSHEET.md) is a fast lookup for `Cooper`'s own public
API.
