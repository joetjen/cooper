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
     "timeout" => %Cooper.Duration{nanoseconds: 500_000_000}
   }
 }}
```

Maps come back with string keys, durations/byte sizes as
`%Cooper.Duration{nanoseconds: n}`/`%Cooper.ByteSize{bytes: n}` structs,
infinity as `%Cooper.Infinity{}`, tuples as real
Elixir tuples (never coerced to lists, CASC.md §6.11), and any
`*key`-prefixed value wrapped in `Cooper.Secret` — redacted by
`inspect/1` and `to_string/1` by default; call
`Cooper.Secret.reveal/1` to get the real value back.

## Why use Cooper?

Configuration starts as a file of values and grows: a host written in
three places, a port that differs per environment, a password that must
never reach a log, a second file for what two services share. CASC is a
configuration language for that point. It stays data, not a program,
and adds the few things configuration keeps needing:

- **References instead of repetition.** `%{server.port}` points at
  another key, resolved against the final, merged configuration, so it
  follows that key wherever an import or override puts it. `@{region}`
  reads a variable.
- **The environment, with defaults and checks.** `${PORT:8080}` falls
  back, `${DB_URL:?"set DB_URL"}` refuses to load without it, and
  `${NAME | trim}` normalises it. `.env` files are read for you.
- **Imports and layering.** Split a document into files, import a glob
  of them, and override with explicit sigils: `+tags` appends, `-tags`
  removes, `~tls { ... }` replaces instead of merging.
- **Secrets marked where they are written.** `*password = ...` comes
  back wrapped, and is redacted wherever it is printed or logged --
  including inside a longer string built from it.
- **The types configuration uses.** Durations (`500ms`), byte sizes
  (`512MiB`), IP addresses and networks, dates and times, atoms and
  tuples arrive as values, not strings to parse later.
- **Extension points you control.** Tags (`!duration("5m")`) and
  resolvers (`!{vault:secret/db}`) your application registers; an
  unregistered one is a load error, never passed through silently.
- **One language, four implementations.** Elixir, Node, PHP and Praxis
  read the same file into the same structure. CASC has a written
  specification ([CASC.md](guides/casc/CASC.md)), and the implementations are held
  to one shared conformance suite, so a document means the same thing
  wherever it is read.
- **A parser generated from the grammar.** Cooper implements CASC
  with Ichor, a sibling grammar-compiler library, rather than
  hand-rolled string parsing -- so the interpreter's behaviour tracks
  the grammar, not the other way around.

### Compared with other configuration languages

| | JSON | YAML | TOML | INI / `.env` | CASC |
|---|---|---|---|---|---|
| Comments | no | yes | yes | yes | yes |
| References to other keys | no | anchors, within one document | no | some `.env` loaders expand `${VAR}` | `%{path}`, against the merged result |
| Environment variables | no | left to the loader | no | it *is* the environment | `${NAME}`, with defaults, checks and filters |
| Imports | no | left to the loader | no | no | files, globs, custom schemes |
| Values beyond strings and numbers | no | dates, and implicit typing (`no` can become `false`) | dates and times | no | durations, sizes, addresses, dates, tuples |
| Secrets | no | no | no | no | marked with `*`, redacted |

**HCL** comes closest in expressiveness, with expressions and
interpolation, but much of what makes it useful -- variables, modules,
`sensitive` -- belongs to the tool that embeds it, Terraform above all.
**Jsonnet, Dhall, CUE and Pkl** go further than CASC: they are
programmable, with functions and, in CUE, Dhall and Pkl, types and
schemas. CASC deliberately stops short of that. It has loops, but no
functions and no schemas, so a document stays something a person reads
top to bottom.

### Compared with each language's usual configuration

| Language | Usually | With Cooper |
|---|---|---|
| Elixir | `config/*.exs`: Elixir code, split between compile time and `runtime.exs`, reading the environment with `System.get_env/1` | [`cooper`](https://hex.pm/packages/cooper) reads CASC; [`cooper_config`](https://hex.pm/packages/cooper_config) replaces Mix's config sources -- `config/runtime.exs` through `Config.Provider` in a release |
| Node | JSON or YAML files and `dotenv`, often under a library such as `config` or `convict` | [`@joetjen/cooper`](https://www.npmjs.com/package/@joetjen/cooper) reads CASC; `@joetjen/cooper-config` loads it once at startup; `@joetjen/cooper-fastify` and `@joetjen/cooper-nestjs` hand it to Fastify and to `@nestjs/config` |
| PHP | PHP arrays and YAML: Laravel's `config/*.php` calling `env()`, Symfony's `config/packages/*.yaml` with `%env()%` | [`joetjen/cooper`](https://packagist.org/packages/joetjen/cooper) reads CASC; `joetjen/cooper-config` loads it once at startup; `joetjen/cooper-laravel` replaces `config/*.php`, `joetjen/cooper-symfony` replaces bundle configuration and container parameters |
| Praxis | CASC is its configuration language: `config/config.casc` | `cooper` reads it; `cooper_prx` loads it before the program starts and hands it to `praxis.app` |

Every one of them also reads `.env` files, the same way. So a service
in PHP and a worker in Node can share one configuration document and
read it identically.

### When something else fits better

If a handful of values is all there is, `.env` alone is enough. If
configuration has to be computed -- functions, generated structures --
or checked against a schema before it is used, Jsonnet, CUE, Dhall or
Pkl do what CASC does not try to.

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
project root automatically — on by default, no option needed — through
[`dotenvy`](https://hex.pm/packages/dotenvy), which Cooper depends on.

**The real OS environment outranks those files**, and an explicit `:env`
option outranks everything (but only for the names it defines — anything
else still falls through). A deployment sets variables in the environment
it controls, and a file sitting in the working directory must not silently
beat them; this is also what Ruby's and Node's dotenv do by default. Pass
`dotenv_override: true` if you want the files on top instead, which is
occasionally handy locally to shadow something exported in your shell.

See the tutorial's [§11](guides/TUTORIAL.md#11-env-files) for the full
layering rules.

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
    {:cooper, "~> 0.6.0"}
  ]
end
```

## Where to go next

- **[Full API documentation](https://joetjen.github.io/cooper/)** —
  generated module docs (also mirrored on
  [HexDocs](https://hexdocs.pm/cooper) once published).
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

Apache-2.0 — see [LICENSE](LICENSE). Releases before 0.5.0 were MIT.
