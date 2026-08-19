# CASC Tutorial

This tutorial introduces CASC — the configuration language itself — one
feature at a time, ending with a complete, realistic file. It assumes
nothing about the Elixir library beyond the one call needed to try each
snippet: `Cooper.load_string/2`. For how to *use* Cooper as a library
(secrets handling, error patterns, test-time injection), see
[Cooper's own tutorial](../TUTORIAL.md); for exhaustive detail on any
single feature here, see [the reference](CASC.md).

Every snippet below can be tried the same way:

```elixir
Cooper.load_string(source, opts \\ [])
```

## 1. The mandatory header

Every CASC file must begin with a version header — a `#@version = ...`
line, as the first non-blank, non-comment statement. This alone is a
complete, valid file:

```casc
#@version = 1.0
```

```elixir
iex> Cooper.load_string("#@version = 1.0")
{:ok, %{}}
```

The header shares its `#` prefix with comments and disabled statements
(§3.2) — it's recognized specifically because what follows the `#` is
`@`, not because of anything else about the line.

## 2. Assignments and the optional `=`

```casc
#@version = 1.0

name = "orders-service"
replicas 3
```

```elixir
iex> Cooper.load_string(source)
{:ok, %{"name" => "orders-service", "replicas" => 3}}
```

`=` is always optional — `key = value` and `key value` mean the same
thing. `=` is recommended for readability; nothing in CASC requires it.

## 3. Blocks and dotted paths are the same tree

```casc
#@version = 1.0

server.host = "0.0.0.0"
server.port = 8080

server {
  tls.min_version = "1.2"
}
```

```elixir
iex> Cooper.load_string(source)
{:ok,
 %{
   "server" => %{
     "host" => "0.0.0.0",
     "port" => 8080,
     "tls" => %{"min_version" => "1.2"}
   }
 }}
```

A dotted path (`server.host = ...`) and a block (`server { ... }`) both
desugar into the identical nested-map structure before anything else
runs — mixing both forms for the same top-level key, like `server`
above, merges into one tree, not two competing ones. There is no
separate "map" syntax in CASC; a block *is* a map, however its keys are
written.

## 4. Values

Every value form beyond plain strings and numbers:

```casc
#@version = 1.0

count       = 42
ratio       = 3.14
enabled     = true
missing     = nil
level       = info
status      = :info
name        = "double quoted, supports escapes and \"quotes\""
raw         = 'single quoted, literal'
motd        = """
    multi-line,
    common indentation stripped
    """
deploy_date = 2024-01-15
timeout     = 500ms
memory      = 512MiB
server_ip   = 10.0.0.1/24
coordinates = (52.52, 13.405)
tags        = ["a", "b", "c"]
```

```elixir
iex> Cooper.load_string(source)["timeout"]
{:duration, 500_000_000}
iex> Cooper.load_string(source)["coordinates"]
{52.52, 13.405}
```

`level = info` and `status = :info` produce the identical atom
`:info` — the leading `:` is only *required* to reach one of the six
reserved words (`nil`/`true`/`false`/`inf`/`+inf`/`-inf`) as an atom
(`:true`, not the boolean). Durations/byte sizes come back as tagged
tuples (`{:duration, ns}`/`{:bytes, bytes}`), never bare numbers, so
they're never confused with an ordinary integer written in the same
config. `coordinates` is a genuine Elixir tuple, fixed at 2 elements —
see §9 below for why that matters at merge time.

## 5. Secrets

```casc
#@version = 1.0

database {
  *password = "hunter2"
  host = "db.internal"
}
```

```elixir
iex> {:ok, config} = Cooper.load_string(source)
iex> config
%{"database" => %{"host" => "db.internal", "password" => [~~REDACTED~~]}}
iex> Cooper.Secret.reveal(config["database"]["password"])
"hunter2"
```

A `*` directly before a key segment marks that value (and everything
nested under it, if it's a block) secret. The value itself is
unaffected — only how a consumer chooses to *display* it changes; see
[Cooper's cheatsheet](../CHEATSHEET.md#secrets) for how `Cooper.Secret`
implements that.

## 6. Variables and interpolation

```casc
#@version = 1.0

@region = "eu-west"
@*build_id = "internal-only"

endpoint = "https://api.@{region}.example.com"
```

```elixir
iex> Cooper.load_string(source)
{:ok, %{"endpoint" => "https://api.eu-west.example.com"}}
```

`@name = value` **declares** a variable — it produces no output of its
own. `@{name}` **references** one, either embedded in a string or as a
bare whole value (`region = @{region}`). There's no bare `@name`
reference form — only `@{...}` reaches a variable's value; a bare `@`
prefix on its own always means a *declaration*. `@*name` declares a
*private* variable, visible only within the declaring file (relevant
once imports enter the picture, §11).

`@{name:default}`, `@{name:+alt}`, and `@{name:?"message"}` all work
the same way `${...}`'s suffix does — see the next section.

## 7. Environment expansion

```casc
#@version = 1.0

region = ${REGION}
port = !int(${PORT:8080})
${?FEATURE_FLAG}
beta_enabled = true
allowed = ${ALLOWED[]:["localhost"]}
```

```elixir
iex> Cooper.load_string(source, env: %{"REGION" => "eu-west"})
{:ok, %{"region" => "eu-west", "port" => 8080, "allowed" => ["localhost"]}}
```

`${NAME}` always resolves to a plain string — CASC never guesses that a
string "looks like" a number. `!int(...)` is a **tagged value**: it
wraps something (typically a `${...}` read) and converts it; `!int`,
`!float`, `!bool`, `!duration`, `!bytes` are built in. To *normalize* a
read rather than convert it, append a filter — `${SCHEME | trim_suffix:
"://"}` — which is how you accept a value a deployment spells
inconsistently without pushing the cleanup into application code.
`${?NAME}`
guards the *one statement immediately following it* — with
`FEATURE_FLAG` unset, `beta_enabled = true` is skipped entirely, not
evaluated and discarded. `${NAME[]:default}` parses a set env var as a
comma/semicolon-separated list.

## 8. Config references

```casc
#@version = 1.0

server.host = "api.internal"
server.port = 8080
health_check.url = "http://%{server.host}:%{server.port}/health"
```

```elixir
iex> Cooper.load_string(source)["health_check"]
%{"url" => "http://api.internal:8080/health"}
```

`%{path}` refers to another value in the *same, fully assembled* tree —
resolved lazily, after every statement in the file (and every import,
§11) has run, so it doesn't matter whether `server.host` is written
before or after the reference, or gets overridden later still (%{...}
always sees the *final* value). A `%{...}` cycle is a load-time error
naming the full chain, never an infinite loop.

## 9. Merge control sigils

```casc
#@version = 1.0

server { host = "0.0.0.0", port = 8080, tls.min_version = "1.2" }
tags = ["a", "b", "c"]

~server { port = 9090 }
+tags = ["d"]
-tags = ["b"]
```

```elixir
iex> Cooper.load_string(source)
{:ok, %{"server" => %{"port" => 9090}, "tags" => ["a", "c", "d"]}}
```

Blocks deep-merge and lists replace wholesale by default — three
leading sigils change that per key: `~key { ... }` **replaces** the
whole subtree instead of merging (`host`/`tls` are gone, not kept
alongside the new `port`); `+key`/`-key` **append**/**remove** list
elements by value. A tuple (§4 above) never accepts any of the three —
using one against a tuple is a load-time error, since there's no
schema to say which position means what.

## 10. Loops

```casc
#@version = 1.0

defaults.replica { cpu = 1, memory_mb = 512 }

@instances = ["a", "b", "c"]
for @idx, @instance in @{instances}
  from defaults.replica as replicas."@{instance}" {
  cpu = 2
  index = @{idx}
}
```

```elixir
iex> Cooper.load_string(source)
{:ok,
 %{
   "defaults" => %{"replica" => %{"cpu" => 1, "memory_mb" => 512}},
   "replicas" => %{
     "a" => %{"cpu" => 2, "memory_mb" => 512, "index" => 0},
     "b" => %{"cpu" => 2, "memory_mb" => 512, "index" => 1},
     "c" => %{"cpu" => 2, "memory_mb" => 512, "index" => 2}
   }
 }}
```

`for <binding>[, <binding>]* [from <template>] as <dest> { <body> }`
generates one entry per iteration. `@idx` (no `in`) is an **index
binding** — the iteration number; `@instance in @{instances}` is an
**element binding** — bound to a real list. With more than one element
binding, iteration is parallel (zipped by position), not a cartesian
product, and every bound list must share the same length. `from`
copies that path's value as each iteration's starting point, resolved
lazily like `%{...}` — the loop body's statements then layer on top as
overrides. Notice `@{idx}` in the body, not bare `@idx` — the same rule
as §6: only `@{...}` reaches a value, whether the variable came from an
ordinary `@name = ...` or a loop binding.

## 11. Imports

```casc
#@version = 1.0

import "defaults.casc"

server.port = 9090
```

`import "path"` splices another complete CASC file's own statements in
at that point — later statements (including the importer's own,
following the import) override earlier ones at the same path, exactly
like §9's merge rules. A bare path resolves relative to the *importing*
file's own directory; brace (`{a,b}`) and glob (`**.casc`) patterns
expand against the filesystem, loading matches in lexicographic order.
Any *public* `@name` variable the imported file declares (never a
private `@*name` one) becomes visible to the importer too. A
`scheme://` path instead dispatches entirely to a consumer-registered
loader — see [Cooper's tutorial §7](../TUTORIAL.md#7-imports-and-test-time-injection)
for registering one.

## 12. Disabled statements

```casc
#@version = 1.0

section {
  #ignored = 1
  kept = true
}
```

```elixir
iex> Cooper.load_string(source)
{:ok, %{"section" => %{"kept" => true}}}
```

A `#` directly before a key (or before another leading sigil) disables
that one statement entirely — syntactically checked, but produces
nothing. `ignored` is absent, not present-but-`nil`. This is different
from a `#` **comment** (§3.2): a comment needs whitespace (or anything
that isn't a letter/`@`/`*`) right after the `#`; `#ignored` with no
space is a disabled-statement attempt.

## 13. Extensible resolvers and tagged values

```casc
#@version = 1.0

*api_key = !{vault:secret/api-key}
port = !int("8080")
```

```elixir
iex> resolvers = %{"vault" => fn payload -> {:ok, "resolved:" <> payload} end}
iex> {:ok, config} = Cooper.load_string(source, resolvers: resolvers)
iex> Cooper.Secret.reveal(config["api_key"])
"resolved:secret/api-key"
```

`!{resolver:payload}` dispatches to a consumer-registered resolver by
name, passing `payload` through verbatim (the first `:` splits name
from payload; the payload itself may contain any number of further
`:`s or balanced `{`/`}` pairs). `!Name(arg)` — already seen as
`!int(...)` in §7 — is the same mechanism for constructing typed
values; `int`/`float`/`bool`/`duration`/`bytes` are built in, anything
else is consumer-registered the same way. Both fail loudly, naming the
offender, if the name used isn't registered — CASC never silently
passes an unrecognized extension point through as an opaque value.

## 14. Putting it together

Every feature above, in one file:

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

${?ENABLE_METRICS}
metrics.url = "http://%{server.host}:%{server.port}/metrics"

@shards = ["a", "b"]
for @shard in @{shards} as replicas."shard-@{shard}" {
  weight = 1
}
```

```elixir
resolvers = %{"vault" => fn payload -> MyVault.fetch(payload) end}

case Cooper.load_string(source, resolvers: resolvers, env: %{"ENABLE_METRICS" => "1"}) do
  {:ok, config} ->
    config

  {:error, %Ichor.Error{} = error} ->
    raise "invalid config: #{error.message}"
end
```

From here, [CASC.md](CASC.md) is the exhaustive reference for anything
touched only briefly above, [CASC_EXAMPLES.md](CASC_EXAMPLES.md) has
more complete, focused examples, and
[CASC_CHEATSHEET.md](CASC_CHEATSHEET.md) is a fast syntax lookup.
