# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Planned as `0.6.0`: the version line is shared with the Praxis port
(`praxis/libs_prx/cooper`), which released `0.5.0` and recorded that
this implementation's next release is `0.6.0`.

### Fixed

Places this implementation contradicted CASC.md, found while porting it
to PHP (`php-cooper`):

- **`key "value"` -- an assignment without `=` to a string, CASC.md
  §5.3's own example -- failed with `expected "import", got "key"`.**
  `import_statement` matches any identifier followed by a quoted string;
  a non-`import` keyword there is now built as that assignment.
- **A `#`-disabled statement (§5.6) took effect.** It was evaluated and
  only its entries dropped, so `#@name = ...` still defined the
  variable, `#import "..."` still loaded the file (failing the load if
  it was missing), and a bad literal inside one still raised. It is now
  never evaluated.
- **A merge sigil inside a block lost its meaning.** Every inner op took
  the enclosing statement's sigil, so `a { +tags = ["d"] }` replaced the
  list and `a { -b }` set `b = nil`. An inner `+`/`-`/`~` now wins; only a
  plain inner op takes the block's.
- **`-key.path` followed by another statement failed to parse.** The
  grammar is newline-insensitive, so the next line's key became the
  remove value (`-a.b = c`, then a stray `= 1`). A bare delete followed
  by a complete statement is now a delete -- the rule is added to
  CASC.md §5.7.
- **`+info`/`-info` failed to parse**: `+inf` out-munched `+`, leaving
  `o`. A signed `inf` no longer matches when an identifier character
  follows.
- **An interpolated key outside a `for` loop (§4.2) became the map key
  unresolved** -- the `Cooper.Interp.Text` struct itself. Keys are now
  resolved before merging, from `@{...}` and `${...}` (a `%{...}`,
  resolver, or tag in a key is an error naming why), under the same
  rules as a built `%{...}` key.
- **`for` loops:** a `~key { }` in the body cleared the *top-level*
  `key`, once per iteration, instead of the one under the generated
  destination; a binding was never substituted into a `%{...}` path
  segment (§7.2's own `%{tokens."supervisor-@{id}"}`), a default, or a
  filter argument, so it failed as an undefined variable; and a key
  mixing a binding with an ordinary variable was refused. All three now
  work.
- **Interpolating a list produced raw bytes** (`[1, 2]` read as iodata)
  **and a tuple or map crashed**; each is now a `:resolve` error.
- **An impossible date or time literal (`2023-02-30`) crashed** the
  load through `Date.from_iso8601!/1`; it is now an `:action` error
  naming the literal.
- **A `${NAME}` in an import path was never watched by the cache**, so a
  cached tree kept importing the file the old value selected. It is now
  tracked and polled like a `${?NAME}` guard, as is a `${NAME}` in an
  interpolated key; the docs that still called `${...}` in an import
  path unsupported are corrected.

Places the copies (`node-cooper`, `php-cooper`) and a shared corpus of
conformance cases showed this implementation contradicting CASC.md, or
itself:

- **A comment before `#@version` failed the load.** Comments are
  trivia everywhere (§3.2); the header now follows any leading ones.
- **`1_000ms` failed to parse.** A duration takes `_` the way an
  integer does (§6.3, §6.8).
- **`${PORT:+1}` was a default of `+1`.** `:+` always introduces a
  substitute; a signed number after `:` is a default only when it is
  negative (`${PORT:-1}`).
- **One private variable could not read another** (`@*b = "v@{a}"` over
  `@*a`), and **a private variable did not shadow an imported public
  one** of the same name. Private variables now resolve first.
- **`+key = @{list}` appended the reference itself** when the operand
  was declared later in the file, and `+`/`-` in a `for ... from` body
  edited a list it could not see yet. Both are now deferred until the
  values resolve.
- **`+key = nil` appended nothing** (`List.wrap/1` reads `nil` as no
  elements); it now appends `nil`, as every other scalar is appended,
  and `-key = nil` removes it.
- **A loop value lost its filters**: `@{x | upcase}` in a body gave `x`
  unfiltered. It now keeps an index, a suffix, and filters.
- **A key built from a loop binding skipped the interpolated-key
  rules**: `out."@{x}"` over `"a.b"` or `""` built a key the same text
  is refused for outside a loop. Both are now `:resolve` errors.
- **A loop iterable could build its variable's name**; it must name it.
- **A secret could not be filtered** (`%{pw | trim}` failed as "not a
  string"). The value is filtered and stays a secret.
- **The message of `:?"..."` crashed the load when it interpolated**;
  it now resolves like any double-quoted string.
- **A filter argument that interpolated crashed the load**
  (`trim_suffix: "@{sep}"`, in a loop or not): it reached the filter
  unresolved. It is now resolved first; one with no string form is a
  `:resolve` error, and one read from a secret makes the result secret.
- **`inf` in a string read `infinity`**; it now reads `inf`/`-inf`.
- **A scheme import that imported itself recursed** instead of
  reporting the cycle a file import reports.
- **`Cooper.Cache` re-baselined the environment on every load**, so a
  change landing between two loads was never seen. The baseline is now
  the one the entry was first watched with.

- **`:true`, `:false` and `:nil` loaded as the values** `true`, `false`
  and `nil`, which CASC.md §6.4 says they are not: on the BEAM those
  atoms *are* the values. They now load as `%Cooper.Atom{name: "true"}`
  and so on; every other atom stays a native atom.

CASC.md now states how a value reads inside a string (§7), and that a
`+`/`-` operand that is not a list is one element, compared strictly
(§8.4).

## [0.4.0] - 2026-10-01

### Added

- An import path may now interpolate `${NAME}` or `${NAME:default}`:

      import "env/${MIX_ENV:dev}.casc"

  which is how one document selects among several without the selection living
  in the consuming application's code.

  Only `${...}` is permitted. An import is resolved while the document is
  parsed, so a reference needing the finished tree (`%{...}`) cannot exist yet
  and remains a load-time error. The environment is available at that point,
  which is what a `${?NAME}` guard already reads.

  Unset and empty are treated alike, as everywhere else. An unset variable
  **without** a default is an error rather than an empty segment: a path that
  silently became `env/.casc` would import the wrong file, or none.

- `!module("Name")`, a built-in tag naming a module of the host language:

      client_module = !module("ASCO.Redis.TestClient")
      formatter = !module("${LOG_FORMATTER}")

  §6.4's atoms are bare identifiers, so a dotted module name cannot be written
  as a literal — and a module is often deployment-selected, arriving through
  `${...}` as a string. There was no way to express either.

  **The tag is the same in every Cooper implementation; the shape it accepts is
  not.** What counts as a module name belongs to the language an implementation
  targets, so a document naming a module stays readable across ports even where
  the convention differs. This implementation accepts dot-separated identifiers,
  mapping an upper-case initial to an Elixir module (`Foo.Bar` →
  `Elixir.Foo.Bar`) and anything else to an Erlang module (`crypto` →
  `:crypto`), and rejects anything longer than 512 bytes.

  Like a bare atom literal, this creates an atom, with the same caveat: fine for
  a fixed, trusted set of configuration files, not for untrusted input.

- A reference's **name** may now be built by interpolation, given as a
  double-quoted string:

      @which = "HOST"
      host = ${"APP_@{which}"}     # reads APP_HOST

  which, with a loop, is how a document follows a deployment convention of one
  variable per tenant — something it previously could not express at all, since
  CASC reads named variables and cannot enumerate the environment:

      @supervisor_ids = ["1", "2", "3"]

      for @id in @{supervisor_ids} as tokens {
        "@{id}" = ${"TOKEN_@{id}"}
      }

  The same applies to `@{"..."}` and to a `%{...}` path segment. A built
  `${...}`/`@{...}` name must resolve to an identifier; a `%{...}` key may be
  any single segment; neither may be built from a secret, since names reach
  error messages unredacted. Only the bare form may be built — a reference
  nested inside a larger string keeps a plain name, the same scope trim that
  position's `:default` grammar already has.

  This is interpolation pointed at the name, not a new expression form. There
  is still deliberately no concatenation operator.

### Fixed

- An interpolated `%{...}` path segment (`%{tokens."supervisor-@{id}"}`) parsed
  but never resolved: the unresolved struct reached `Enum.join/2` and raised
  `Protocol.UndefinedError` instead of either working or failing cleanly. It now
  resolves.

- A `for` loop's bindings did not substitute into a **body key**, only into
  values. An interpolated key stayed an unresolved `Cooper.Interp.Text` used as
  a map key, so every iteration collapsed onto that single struct key and only
  the last survived:

      for @id in @{ids} as out {
        "@{id}" = "value-@{id}"     # previously produced one entry, not one per id
      }

- Private (`@*name`) variables were not file-local. Visibility was applied to
  the *declaration* environment while `@{...}` references were resolved later,
  against the single flattened result of the whole import tree — by which point
  the file a reference had been written in was no longer known. Three
  consequences, all now fixed:

  - A private variable declared in an importing file was visible inside the
    files it imported.
  - A private variable declared in an *imported* file could not be used by that
    file's own values at all, failing with `undefined reference` — the
    declaration was filtered out before resolution ever ran.
  - A private name was therefore global in one direction and unusable in the
    other, the opposite of what CASC.md §5.2 specifies.

  Every `@{...}` reference is now attributed to the file that wrote it (see
  `Cooper.Scope`), and each file's private declarations are resolved only for
  references carrying that file's scope.

  Existing documents that use only public `@name` variables are unaffected.
  Documents relying on a private variable leaking into an imported file will now
  see it as undefined, which is the specified behaviour.

### Changed

- CASC.md §5.2 now states the visibility rules in full. Public variables are
  visible in **both** directions — to a file's importers and to the files it
  imports — which is what makes an entry document able to declare values its
  shared includes consume. This is a documentation fix: it is what the
  implementation has always done for public names, and it was previously
  described as flowing only towards importers.

- `Cooper.Ref.Var` carries a new `scope` field, and `Cooper.Grammar.run_tree/2`
  now returns its variable environment as `{public, private_by_scope}`.
  `Cooper.Resolver` still accepts a plain `%{name => value}` map for `:vars`,
  so callers resolving a hand-built tree need no change.

## [0.3.0] - 2026-08-19

### Added

- Reference filters: `${NAME | trim}`, `| downcase`, `| upcase`,
  `| trim_prefix: "..."` and `| trim_suffix: "..."`. Filters are one
  rule shared by `@{...}`, `${...}` and `%{...}`, exactly like the
  existing suffix grammar, and apply after the suffix has settled so a
  filter always sees the value that will actually be used — including
  one that came from a default. They chain left to right.

  This is for the case where a deployment supplies a value in a spelling
  you did not choose: `${SCHEME | trim_suffix: "://"}` accepts both
  `https` and `https://` without the composing code having to normalize
  what it reads back.

  Arguments may be single- or double-quoted. Single quotes are what make
  a filter usable *inside* an interpolated string, where a double-quoted
  argument has nowhere to nest:
  `"${SCHEME | trim_suffix: '://'}://%{host}"`.

  Filters normalize; they do not convert. A non-string value, an unknown
  filter name, a missing argument, and an argument given to a filter
  that takes none are all load-time errors rather than silent coercions.

- `!trim`, `!downcase` and `!upcase` tagged values, which do for a whole
  value what the matching filter does for one reference.

### Changed

- **BREAKING (behaviour):** `.env` files no longer outrank the real
  environment. The layering is now
  `.env` → `.env.<env>` → `.env.local` → `System.get_env/0` → `:env`,
  where it was `System.get_env/0` → the files → `:env`.

  A deployment sets variables in the environment it controls, and a file
  in the working directory silently beating them is a debugging trap
  rather than a feature. It also matches what dotenv implementations in
  other ecosystems do by default — Ruby's and Node's both decline to
  overwrite an already-set variable.

  **Nothing errors when this changes which value wins**, so check any
  setup that relies on a `.env` shadowing an exported variable. Pass the
  new `dotenv_override: true` option to `Cooper.load_file/2`,
  `load_string/2`, or `Cooper.Dotenv.env/1` to restore the previous
  ordering.

- `mix.exs`'s `docs/0` now sets `source_url` and `homepage_url`
  (`https://github.com/joetjen/cooper` and
  `https://joetjen.github.io/cooper`), and `package/0`'s `links` gained
  a `"Docs"` entry alongside `"GitHub"`, so generated docs (both
  HexDocs and the GitHub Pages copy `.github/workflows/docs.yml`
  deploys) link back to the right places instead of leaving ExDoc to
  guess. README.md and CONTRIBUTING.md now link to the published
  GitHub Pages docs site too.

## [0.2.2] - 2026-08-03

### Changed

- Bumped `ichor_runtime` to `~> 0.2` (from `~> 0.1.0`) and the dev/test-only
  `ichor` to `~> 0.3` (from `~> 0.2.1`, the minimum that depends on
  `ichor_runtime ~> 0.2` in turn), and dropped the patch component from
  both requirements (`~> 0.2`/`~> 0.3` rather than pinning a specific
  patch). `ichor_runtime` 0.2.0's breaking change is internal to the
  parse pipeline: raw capture data (`Ichor.Capture.node_t/0`'s `:rule`
  variant) is now an ordered `[{name, value}]` list instead of a plain
  map, fixing sibling-capture evaluation order depending on a map's own
  (cross-OTP-version-unstable) iteration order rather than true
  first-occurrence source order. `lib/cooper/native_grammar/native.ex`
  and `lib/cooper/native_interp_grammar/native.ex` (both `mix ichor.gen`
  output for `priv/grammar/casc.aether`/`casc_interp.aether`) were
  regenerated to match; `lib/cooper/native_grammar/capture_shapes.ex`
  (`scripts/gen_capture_shapes.exs`) was regenerated too but came out
  unchanged, since which captures are repeatable is orthogonal to this
  fix. No hand-written code needed updating: `Cooper.Actions`/
  `Cooper.InterpActions` only ever see the already-evaluated `captures`
  map `handle_rule/3` callbacks receive (unaffected by the change), and
  both modules implement an exhaustive catch-all `handle_rule/3` clause,
  so `Ichor.Actions`' own default fallback -- the only place the old
  buggy ordering could actually surface -- was never reachable from
  Cooper's own grammars in the first place. No observable behavior
  change for anything calling into `Cooper`'s public API.

## [0.2.1] - 2026-07-31

### Fixed

- `test/fixtures/dotenv/empty/`, used by `Cooper.DotenvTest`'s
  "missing files are never a load-time error" and "System.get_env/0
  is always the floor" cases, was a genuinely empty directory -- Git
  doesn't track empty directories, so it was never actually committed
  despite existing locally, and any fresh checkout (CI included) was
  missing it entirely, failing both tests with a `File.Error` on
  `File.cd!/1`. No code behavior changed; added a `.gitkeep`
  placeholder so the directory itself is tracked.

## [0.2.0] - 2026-07-31

### Added

- `.env` file support: `Cooper.load_file/2`/`load_string/2` now layer
  `.env`, `.env.<env>`, and `.env.local` (project root, later winning)
  into `${...}` resolution, on by default, via the new optional
  `:dotenvy` dependency and `Cooper.Dotenv` module. A missing file is
  never an error. `:dotenv: false` disables just the `.env` file
  layers; `:dotenv_env` picks the per-environment file, defaulting to
  live `Mix.env/0` when Mix is loaded, else
  `Application.compile_env(:cooper, :dotenv_env)` (opt in from a host
  release with `config :cooper, dotenv_env: config_env()` in its own
  `config/config.exs` -- deliberately *not* a bare `Mix.env/0` read
  from inside Cooper's own source, which Mix always compiles under
  `:prod` regardless of the host app's real build env, confirmed
  empirically against `mix help deps`'s documented dependency-env
  isolation); `:dotenv_files` fully replaces the default four-file
  list.
- `Cooper.Cache`: caches everything up to the final `${...}`-resolution
  step, keyed by mtime across the entry file and every transitively
  bare-imported file (a GenServer-owned, `:public` ETS table with
  stampede protection — concurrent misses on the same file coalesce
  into one load). `${...}` resolution itself is never cached — it
  re-runs against a freshly-computed `:env` on every call, hit or
  miss, so an ordinary value read is always current.
  `Cooper.Cache.invalidate/1` and `Cooper.Cache.clear/0` bust a
  specific entry or everything. One documented limitation: a
  `${?NAME}` guard's decision is baked in at populate time and only
  refreshes when the cache entry itself invalidates, not on every
  access. (`${...}` inside an `import "..."` path is unrelated --
  CASC.md §5.1 doesn't support it at all, so it's always an
  unconditional load-time error, never something cached.)
- Cooper is now a proper OTP application (`mix.exs` gains a `mod:`
  entry): a new internal application module starts a small supervision
  tree owning `Cooper.Cache`'s process. Idle (no background work) until
  the first `load_file/2` call, and no polling timer until the first
  call whose file references the environment (see `watch_env` below).
- `Cooper.Cache` emits `:telemetry` (new, non-optional dependency)
  events: `[:cooper, :cache, :file_changed]`, always, when a
  previously-cached entry's fingerprint no longer matches disk (never
  on first load); `[:cooper, :cache, :env_changed]`, via `load_file/2`'s
  new `watch_env` option (defaults to `true` for a file that references
  `${...}` at all -- an ordinary value, a `${?NAME}` guard, or both --
  `false` otherwise; pass it explicitly to override), when a watched
  `${NAME}` changes -- a real `System.put_env/2` or a `.env` file edit,
  either one, checked against `Cooper.Dotenv.env/1` on a poll timer
  (`Application.get_env(:cooper, :env_poll_interval, 5_000)`), since
  neither has an OS-level push notification to hook into. A genuine
  external OS environment change (outside the running app entirely) is
  never observable by anything, Cooper included -- documented, not a
  gap to close. A detected change also invalidates the cache entry, so
  a `${?NAME}` guard depending on a watched name refreshes within one
  poll interval instead of only on a file change. `Cooper.Resolver`
  gained `resolve_with_env_names/2` (the ordinary-value-read tracking
  this relies on, alongside `Cooper.Actions`'/`Cooper.Loader`'s new
  guard-name tracking) next to the unchanged `resolve/2`.

### Changed

- **Breaking:** `Cooper.load_file/2` now caches by default (see
  `Cooper.Cache`, above) -- previously it always did a full fresh
  parse+merge+resolve on every call. For an unchanged file, the result
  is identical, just faster on repeat calls; the one real behavior
  difference is that a `${?NAME}` guard's decision is now sticky until
  the cache entry invalidates, rather than re-evaluated on every single
  call (mitigated by `watch_env`'s own default -- see above). Pass
  `cache: false` to restore the old always-fresh behavior for a
  specific call. `Cooper.load_string/2` is unaffected -- it never
  caches, since there is no file to key a cache on.
- **Breaking:** `:env` is now an override layer, not the sole source of
  `${...}` resolution. The full precedence chain, later winning, is
  `System.get_env/0` < `.env` < `.env.<dotenv_env>` < `.env.local` <
  `:env`. Previously, passing `:env` fully replaced `System.get_env/0`
  and nothing else was consulted; now `System.get_env/0` (and any
  `.env` file) is always in the mix, and `:env` guarantees a value only
  for the names it explicitly defines — a `${...}` reference to any
  other name still falls through to the real environment/`.env` files,
  exactly as if `:env` weren't passed. Code (including tests) that
  relied on `:env` fully isolating resolution from the real environment
  needs to either give every relevant name its own explicit `:env`
  entry, or pass `dotenv: false` if only the `.env` file layers (not
  `System.get_env/0`) need ruling out. Per SemVer's pre-1.0 rules, this
  will ship as a `0.x` bump, not `1.0.0`.

## [0.1.0] - 2026-07-31

### Added

- `Cooper.load_file/2` and `Cooper.load_string/2`, loading a CASC
  config file (or source string) into native Elixir terms end to end:
  lex+parse, loop expansion, import resolution, merge, reference
  resolution, and secret-wrapping.
- A complete CASC grammar (`priv/grammar/casc.aether`, built on Ichor,
  a sibling grammar-compiler library): version headers, comments,
  disabled statements, key paths and nested blocks, dotted and quoted
  key segments, secret keys (`*key`), and every literal form CASC.md §6
  defines — nil, booleans, integers (decimal/hex/octal/binary), floats,
  atoms, dates and times, durations, byte sizes, strings
  (double/single/triple-quoted), lists, and tuples (kept as real Elixir
  tuples, never coerced to lists).
- `Cooper.IPv4`/`Cooper.IPv6` (CASC.md §6.7): dedicated, validated
  types for IP address literals (`127.0.0.1`, `::1/128`) — an
  out-of-range octet, malformed address, or CIDR prefix outside
  `0..32`/`0..128` fails at load time with a named error, never a
  crash. Both support CIDR containment (`contains?/2`) and network math
  (`network/1`, `netmask/1`, `first_host/1`, `last_host/1`, plus
  `broadcast/1` on `Cooper.IPv4`).
- Variables (`@name`/`@*name`, public/private) and all five
  interpolation/reference forms (CASC.md §7): `@{}` variables, `${}`
  environment reads (with `:default`, `:+alt`, `:?"required"`, list,
  and indexed forms), `%{}` lazy config references (resolved against
  the final merged tree, with cycle detection), `!{resolver:payload}`
  extensible dispatch, and `!Name(arg)` tagged values — five built-in
  tags (`int`/`float`/`bool`/`duration`/`bytes`) plus consumer-registered
  ones via the `:tags` option.
- The merge model (CASC.md §8): deep-merge by default, `~key { ... }`
  whole-subtree replace, `+key`/`-key` list append/remove, `-key.path`
  delete, and a hard error (never a silent coercion) merging into a
  tuple.
- `for` loops (CASC.md §5.5): index and element bindings, parallel
  (zipped) multi-binding iteration, interpolated destination paths, and
  `from <template>` (a lazy base resolved against the final tree, with
  the loop body layered on top as overrides).
- `import` statements (CASC.md §5.1): bare paths (with `{a,b}` brace
  and `**` glob expansion), `scheme://` dispatch via the
  `:import_schemes` option, import-cycle detection, and public-variable
  propagation across import boundaries.
- `Cooper.Secret`, wrapping every `*key`-prefixed value — `inspect/1`
  and `to_string/1` redact unconditionally; `Cooper.Secret.reveal/1` is
  the only way to the real value. Wrapping happens at merge time and
  travels with the value through any later `%{...}` reference or `for
  ... from` template copy, rather than staying pinned to the value's
  original declared path. A secret embedded inside a larger
  interpolated string redacts only its own portion, not the whole
  string, and independently for each of several secrets interpolated
  into the same string.
- Two interchangeable backends per grammar (`Grammar.Native` by
  default, `Grammar.VM` kept for parity/benchmarking) — see
  `bench/native_vs_vm.exs` and `test/cooper/backend_parity_test.exs`.
- `test/SPEC_COVERAGE.md`, a traceability table mapping every section
  of CASC.md to the test(s) covering it, plus one documented gap:
  backslash-continued strings (CASC.md §6.5's fifth string form) are
  not implemented, since the spec gives no worked example to validate
  an implementation against.
- `guides/EXAMPLES.md`, `guides/casc/TUTORIAL.md`,
  `guides/casc/CASC_EXAMPLES.md`, and `guides/casc/CASC_CHEATSHEET.md`
  — every example in all four is verified against a real
  `Cooper.load_string/2` call, not just written by hand.
- `mix precommit` (an alias in `mix.exs`): `format`, `compile
  --warnings-as-errors`, `credo --strict`, `sobelow`, `test`,
  `dialyzer`, in that fast-to-slow order, all under `MIX_ENV=test` so
  Credo/Dialyzer see `test/support/` too. Backing dev/test dependencies:
  `credo`, `dialyxir` (PLT built with `:mix`/`:ichor` added explicitly,
  since `ichor`'s `runtime: false` hides it from dialyxir's automatic
  OTP-app discovery even though `test/support/vm_parity.ex` genuinely
  calls into it), `sobelow`, `excoveralls`, plus `mox`/`faker`/
  `stream_data` available for tests that need them (none do yet).
  `.credo.exs` and `.dialyzer_ignore.exs` (the latter narrowly scoped
  to two known-benign Dialyzer findings around `MapSet`'s opaque type
  in generated code, not a blanket suppression) are new at the repo
  root. See `CONTRIBUTING.md`'s "Making a change" §4.

### Changed

- Ichor split into `ichor` (the Aether front-end, `Grammar.Analysis`,
  both codegen backends -- dev-time-only) and `ichor_runtime` (the
  small support library generated code actually calls at runtime):
  `priv/grammar/casc.aether`/`casc_interp.aether` are now compiled
  *ahead of time* by `mix ichor.gen` into checked-in modules
  (`lib/cooper/native_grammar/native.ex`,
  `lib/cooper/native_interp_grammar/native.ex`) instead of at Cooper's
  own compile time via `use Ichor, grammar:, actions:`, and
  `lib/cooper/native_grammar/capture_shapes.ex`
  (`scripts/gen_capture_shapes.exs`) does the same for the one other
  piece `Cooper.Grammar`'s `run_with_context/3` needed from `ichor`
  proper at runtime. `mix.exs` now depends on `ichor_runtime` as an ordinary
  runtime dependency and `ichor` itself `only: [:dev, :test], runtime:
  false` -- confirmed via `MIX_ENV=prod mix deps`/`mix compile` that a
  release build now touches only `ichor_runtime`. The `Grammar.VM`
  parity backend (`bench/native_vs_vm.exs`,
  `test/cooper/backend_parity_test.exs`) moved out of `lib/` into
  `test/support/vm_parity.ex` accordingly, since it still needs `ichor`
  proper and `lib/` compiles in every environment including `:prod`.
- `ichor`/`ichor_runtime` now depend on their Hex-published releases
  (`ichor ~> 0.2.1`, `ichor_runtime ~> 0.1.0`) instead of Ichor's
  pre-merge `feature/runtime` git branch -- `ichor_runtime` is its own
  independently-published, independently-versioned package now (not a
  subdirectory of `ichor`'s own repo), so no `override:`/`sparse:`
  wiring is needed the way there was while both lived behind one
  `git:` spec. `lib/cooper/native_grammar/native.ex`,
  `lib/cooper/native_interp_grammar/native.ex`, and
  `lib/cooper/native_grammar/capture_shapes.ex` regenerated against
  0.2.1's `mix ichor.gen`; behavior unchanged (0.2.x's own changes were
  the `ichor`/`ichor_runtime` split and docs -- see Ichor's own
  CHANGELOG.md).
- `RESOLVER_REF_RAW` (`!{resolver:payload}`'s token, in both
  `casc.aether` and `casc_interp.aether`) now uses Ichor 0.1.1's
  `@native(...)` token-position escape hatch (new module:
  `Cooper.Native.ResolverRef`) instead of a fixed
  one-level-of-nested-braces combinator form — a payload may now
  brace-nest to any depth, matching CASC.md §7.4's own
  "brace-balanced" wording exactly, rather than the previous
  implementation's slightly narrower approximation of it.
- The `Grammar.VM` parity backend (now `Cooper.Test.VMParity.run_with_context_vm/3`,
  see above) updated for Ichor 0.1.1's `Grammar.VM.Lexer` →
  `Grammar.VM.Tokenizer` rename and its new
  `custom_lexemes`/`@keywords`/`@refine`-reclassification pipeline
  stages.

### Fixed

- `Cooper.Loader`'s per-import `sub_ctx` now carries `:env` forward —
  previously, a `${?NAME}` conditional statement (CASC.md §7.2) inside
  an *imported* file crashed with `KeyError: key :env not found`
  instead of reading the importer's own environment, since the
  imported file's own parse-time context silently dropped that key.
