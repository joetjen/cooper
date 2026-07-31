# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
  root. See `CONTRIBUTION.md`'s "Making a change" §4.

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
