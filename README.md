# Cooper

Cooper loads [CASC](guides/casc/CASC.md) config files — a hierarchical,
extensible config language with imports, variables, string
interpolation, environment/config references, loops, and
consumer-registered resolvers and tags — into native Elixir terms.

```text
# config.casc
#@version = 1.0

@region = "eu-west"

server {
  host = "0.0.0.0"
  port = 8080
}

database {
  *password = ${DB_PASSWORD}
  host = "db.@{region}.internal"
  pool_size = 10
  timeout = 500ms
}
```

```elixir
iex> Cooper.load_file("config.casc", env: %{"DB_PASSWORD" => "hunter2"})
{:ok,
 %{
   "server" => %{"host" => "0.0.0.0", "port" => 8080},
   "database" => %{
     "password" => [~~REDACTED~~],
     "host" => "db.eu-west.internal",
     "pool_size" => 10,
     "timeout" => {:duration, 500_000_000}
   }
 }}
```

Maps come back with string keys, durations/byte sizes as tagged
`{:duration, nanoseconds}`/`{:bytes, count}` tuples, tuples as real
Elixir tuples (never coerced to lists, CASC.md §6.11), and any
`*key`-prefixed value wrapped in `Cooper.Secret` — redacted by
`inspect/1` and `to_string/1` by default; call
`Cooper.Secret.reveal/1` to get the real value back.

## Why

Most config libraries either parse a fixed format (JSON/YAML/TOML) or
hand you a bespoke DSL with no formal grammar behind it. CASC has a
real specification ([`guides/casc/CASC.md`](guides/casc/CASC.md)), and
Cooper implements it via Ichor, a sibling grammar-compiler library,
rather than hand-rolled string parsing — so the interpreter's behavior
tracks the grammar, not the other way around.

## How it fits together

Loading a file runs one pipeline, each stage handing off to the next:

1. **Lex + parse** — `Cooper.Grammar` and `Cooper.Actions` turn CASC
   source into a flat list of assignments and variable declarations,
   with every literal value (numbers, durations, dates, strings, ...)
   already converted to its native Elixir form.
2. **Loop expansion** — `Cooper.Loop` expands each `for` statement
   (CASC.md §5.5) into the ops it generates.
3. **Import resolution** — `Cooper.Loader` recursively loads each
   `import` statement (CASC.md §5.1), splicing the imported file's own
   ops into the importer's list and propagating its public variables.
4. **Merge and secret-wrapping** — `Cooper.Merge` folds the flattened
   ops into a tree, honoring the merge-control sigils (`~`/`+`/`-`,
   CASC.md §5.7/§8), and wraps every `*key`-prefixed value in
   `Cooper.Secret` so it can't leak through an accidental
   `inspect`/log call.
5. **Reference resolution** — `Cooper.Resolver` resolves everything
   left unresolved: `@{}` variables, `${}` environment reads, `%{}`
   config references, `!{resolver:...}` dispatch, and `!Name(...)`
   tagged values (CASC.md §7) — including re-wrapping a secret that
   gets copied elsewhere by one of those references, so the redaction
   travels with the value, not just its original declared path.

See the [tutorial](guides/TUTORIAL.md) for a full walkthrough of both
the library and the CASC syntax it parses, or the
[cheatsheet](guides/CHEATSHEET.md) for a terse API reference.

## .env files

`${...}` reads pick up `.env`/`.env.<env>`/`.env.local` from the
project root automatically — on by default, no option needed — via the
optional [`dotenvy`](https://hex.pm/packages/dotenvy) dependency, layered
between the real OS environment and an explicit `:env` option (which
always wins, but only for the names it defines — anything else still
falls through). See the tutorial's
[§11](guides/TUTORIAL.md#11-env-files) for the full layering rules.

## Caching

`Cooper.load_file/2` caches everything up to the final `${...}`-resolution
step by default, keyed by file mtime (imports included) — a repeat call
for an unchanged file skips re-parsing entirely, while `${...}` values
themselves are always re-resolved fresh, hit or miss. Pass `cache:
false` to opt out for one call. It emits
[`:telemetry`](https://hex.pm/packages/telemetry) events too —
`[:cooper, :cache, :file_changed]` whenever a cached file's fingerprint
changes, and `[:cooper, :cache, :env_changed]` (on by default for any
file that references `${...}` at all, via `watch_env`) when an
actually-referenced `${NAME}` changes, a real `System.put_env/2` or a
`.env` file edit either one. See the tutorial's
[§12](guides/TUTORIAL.md#12-caching) for the invalidation rules and
`Cooper.Cache` for the module backing it.

## Installation

Add `cooper` to your list of dependencies in `mix.exs`. `ichor` comes
along as its own dependency automatically — no separate line needed:

```elixir
def deps do
  [
    {:cooper, "~> 0.2.0"}
  ]
end
```

Add `{:dotenvy, "~> 1.1"}` too if you want `.env` file support (see
above) — it's optional, so nothing pulls it in for you.

## Where to go next

- **[Tutorial](guides/TUTORIAL.md)** — loading config, secrets, guards,
  error handling, test-time env/import injection, `.env` files,
  caching, and enough CASC syntax to follow along.
- **[Examples](guides/EXAMPLES.md)** — layered per-environment config,
  a real secrets manager, IP allowlisting, generating per-shard config
  from a template, testing config-loading code without touching disk.
- **[Cheatsheet](guides/CHEATSHEET.md)** — quick reference for
  `Cooper`'s public API.
- **[CASC tutorial](guides/casc/TUTORIAL.md)** and
  **[CASC reference](guides/casc/CASC.md)** — everything about the
  language itself, independent of the surrounding library.

## Development

```sh
mix deps.get
mix precommit
```

`mix precommit` runs everything a change needs to pass before review —
formatting, `--warnings-as-errors` compilation, Credo, Sobelow, the
test suite, and Dialyzer, in that order. See
[CONTRIBUTING.md](CONTRIBUTING.md) for how to propose changes, and
[CHANGELOG.md](CHANGELOG.md) for release history.

## License

MIT — see [LICENSE](LICENSE).
