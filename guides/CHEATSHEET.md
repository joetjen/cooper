# Cheatsheet

Quick reference for `Cooper`'s public API. See the
[tutorial](TUTORIAL.md) for a walkthrough, or
[CASC.md](casc/CASC.md) for the full language reference.

## Load config

```elixir
Cooper.load_file(path, opts \\ [])
#=> {:ok, term()} | {:error, Ichor.Error.t() | [Ichor.Error.t()]}

Cooper.load_string(source, opts \\ [])
#=> {:ok, term()} | {:error, Ichor.Error.t() | [Ichor.Error.t()]}
```

`load_file/2` reads `path` and derives `:root`/import-cycle detection
from it automatically — the ordinary way to load a real file.
`load_string/2` is for source that isn't (yet, or ever) in a file —
pass `:root` explicitly if it uses bare (non-`scheme://`) imports.

## Options

| Option | Shape | Default | Effect |
|---|---|---|---|
| `:env` | `%{String.t() => String.t()}` | `%{}` | **Override**, not replacement, for `${...}` resolution — always wins for a name it defines, but a name it doesn't define still falls through to `.env`/the real environment (see [.env files](#env-files)). |
| `:dotenv` | `boolean()` | `true` | Layer `.env` file(s) between `System.get_env/0` and `:env` (see [.env files](#env-files)). `false` disables just this layer. |
| `:dotenv_env` | `atom() \| nil` | `Mix.env/0` if Mix is loaded, else `nil` | Which `.env.<env>` file to read. |
| `:dotenv_files` | `[String.t()]` | `[".env", ".env.<dotenv_env>", ".env.local"]` | Fully replaces the default `.env` file list. |
| `:root` | `String.t()` | `path`'s directory (`load_file/2`) / `File.cwd!/0` (`load_string/2`) | Where a bare `import "..."` resolves relative to. |
| `:resolvers` | `%{String.t() => (payload :: String.t() -> {:ok, term()} \| {:error, term()})}` | `%{}` | One function per `!{resolver:...}` name (CASC.md §7.4). Unregistered use is a load-time error. |
| `:tags` | `%{String.t() => (arg :: term() -> {:ok, term()} \| {:error, term()})}` | `%{}` | One function per `!Name(...)` beyond the 5 built-ins (CASC.md §7.5). Unregistered use is a load-time error. |
| `:import_schemes` | `%{String.t() => (rest :: String.t() -> {:ok, String.t()} \| {:error, term()})}` | `%{}` | One loader per `import "scheme://..."` scheme (CASC.md §5.1). Unregistered use is a load-time error. |

## .env files

On by default. Layers, later winning:

```text
System.get_env/0 < .env < .env.<dotenv_env> < .env.local < :env
```

`.env`/`.env.<dotenv_env>`/`.env.local` are optional -- missing is
never an error. `:env`, if passed, always wins for the names it
defines, but doesn't isolate resolution from anything below it -- a
name not in `:env` still falls through to `.env`/the real environment.
Runs through the optional `:dotenvy` dependency — add
`{:dotenvy, "~> 1.1"}` to your own `mix.exs` deps. See the
[tutorial](TUTORIAL.md#11-env-files) for the full walkthrough.

## Built-in tags

`!int(arg)`, `!float(arg)`, `!bool(arg)`, `!duration(arg)`,
`!bytes(arg)` — always registered, need no `:tags` entry.
`!duration(...)` and a bare duration literal (`500ms`) both produce
`{:duration, nanoseconds}`; `!bytes(...)` and a bare byte-size literal
(`512MiB`) both produce `{:bytes, count}`.

## IP addresses and CIDR

A bare `127.0.0.1`/`127.0.0.1/32` (CASC.md §6.7) literal resolves to
`%Cooper.IPv4{}`; `::1`/`::1/128` resolves to `%Cooper.IPv6{}`. Both
are validated at load time — an out-of-range octet, a malformed
address, or a CIDR prefix outside `0..32`/`0..128` is a load-time
error, not a crash or a silently-accepted value.

```elixir
%Cooper.IPv4{address: :inet.ip4_address(), prefix: 0..32 | nil}
%Cooper.IPv6{address: :inet.ip6_address(), prefix: 0..128 | nil}

Cooper.IPv4.new(address, prefix \\ nil)   #=> {:ok, t()} | {:error, String.t()}
Cooper.IPv4.contains?(cidr, other)        #=> boolean() -- is `other` inside `cidr`'s block?
Cooper.IPv4.network(cidr)                 #=> the block's network address
Cooper.IPv4.broadcast(cidr)               #=> the block's broadcast address (IPv4 only -- IPv6 has no equivalent)
Cooper.IPv4.netmask(cidr)                 #=> the netmask implied by the block's prefix
Cooper.IPv4.first_host(cidr)              #=> first usable host address
Cooper.IPv4.last_host(cidr)               #=> last usable host address
```

`Cooper.IPv6` has the identical API minus `broadcast/1`. Both
implement `String.Chars`, rendering back in CASC's own literal syntax
(`"127.0.0.1/24"`), including when embedded in an interpolated string.

## Secrets

```elixir
%Cooper.Secret{value: term(), redacted: String.t() | nil}

Cooper.Secret.reveal(secret)
#=> the real, fully unmasked value
```

Any key segment prefixed with `*` (`*key`, CASC.md §4.3) comes back
wrapped in `Cooper.Secret`. `inspect/1` and `to_string/1` redact
unconditionally — `reveal/1` (or the `:value` field directly) is the
only way to the real value.

- **Whole-value secret** (`*password = "..."`) — `:redacted` is `nil`;
  `inspect`/`to_string` render the blanket `"[~~REDACTED~~]"` marker.
- **Secret embedded in a larger interpolated string**
  (`"conn=%{database.password}"`) — only that portion redacts, not the
  whole string (`"conn=[~~REDACTED~~]"`); several secrets interpolated
  into one string each redact independently at their own position.
- **Travels with the value, not just its declared path** — a `%{...}`
  reference or a `for ... from` template that copies a secret value
  elsewhere in the tree copies the wrapping too; a tag (`!int(...)`) or
  index (`[i]`) applied to a secret-sourced value re-wraps its result.

## Errors

Every stage returns `{:error, Ichor.Error.t() | [Ichor.Error.t()]}` on
failure — never a raised exception. `error.message` is a human-readable
string; `error.stage` says roughly where it came from:

| Stage | Raised for |
|---|---|
| `:lexer` / `:parser` | CASC syntax the grammar itself rejects. |
| `:action` | A literal that parses but fails semantic validation (e.g. a malformed duration/bytes/IP literal, an out-of-range CIDR prefix, an unexpected version-header token). |
| `:loop` | A `for` loop's bindings are invalid (index-only loop, mismatched element-list lengths, a `%{...}` used as an iterable). |
| `:import` | A file couldn't be read, an import cycle, or an unregistered `scheme://`. |
| `:merge` | A `~`/`+`/`-` sigil applied to a value it can't operate on (e.g. `+`/`-` against a tuple). |
| `:resolve` | An undefined `@{}`/`${}` reference with no default, a `${NAME:?"msg"}` failure, a `%{...}`/`@{...}` reference cycle, or an unregistered resolver/tag. |
| `:dotenv` | An `.env` file that exists but fails to parse, or `dotenv: true` explicitly requested without the optional `:dotenvy` dependency installed. |

## Test-time injection

`:resolvers`/`:import_schemes` fully replace whatever they'd otherwise
reach for — a plain function/map you supply, no global state involved:

```elixir
Cooper.load_string(source,
  resolvers: %{"vault" => fn payload -> {:ok, "stub:" <> payload} end},
  import_schemes: %{"mem" => fn _rest -> {:ok, other_source} end}
)
```

`:env` is different — it's an **override**, not an isolation
mechanism (see [.env files](#env-files)). `env: %{"DB_PASSWORD" =>
"test-secret"}` guarantees `DB_PASSWORD` specifically, but any other
`${...}` a test's source reads still falls through to `.env` files and
the real OS environment. Give every name the test depends on an
explicit `:env` entry rather than relying on it being otherwise unset;
`dotenv: false` additionally skips the `.env` file layers if a test
needs to rule those out too.

## Pipeline modules

Only relevant if you need to call a stage directly instead of going
through `Cooper.load_file/2`/`load_string/2`:

| Module | Stage |
|---|---|
| `Cooper.Dotenv` | Build the `${...}`-resolution env map (see [.env files](#env-files)). |
| `Cooper.Grammar` / `Cooper.Actions` | Lex + parse into flattened ops. |
| `Cooper.Loop` | Expand `for` statements into the ops they generate. |
| `Cooper.Loader` | Resolve and recursively load `import` statements. |
| `Cooper.Merge` | Fold flattened ops into a tree. |
| `Cooper.Resolver` | Resolve everything left unresolved (`@{}`/`${}`/`%{}`/`!{}`/`!Name()`). |
