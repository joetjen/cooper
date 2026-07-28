# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- `ichor` is now a Hex dependency (`~> 0.1`) instead of a `path:`
  dependency, tracking its 0.1.1 release.
- `RESOLVER_REF_RAW` (`!{resolver:payload}`'s token, in both
  `casc.aether` and `casc_interp.aether`) now uses Ichor 0.1.1's
  `@native(...)` token-position escape hatch (new module:
  `Cooper.Native.ResolverRef`) instead of a fixed
  one-level-of-nested-braces combinator form — a payload may now
  brace-nest to any depth, matching CASC.md §7.4's own
  "brace-balanced" wording exactly, rather than the previous
  implementation's slightly narrower approximation of it.
- `Cooper.Grammar`'s `run_with_context_vm/3` (the `Grammar.VM` parity
  backend, not used by the default `Grammar.Native` path) updated for
  Ichor 0.1.1's `Grammar.VM.Lexer` → `Grammar.VM.Tokenizer` rename and
  its new `custom_lexemes`/`@keywords`/`@refine`-reclassification
  pipeline stages.

### Fixed

- `Cooper.Loader`'s per-import `sub_ctx` now carries `:env` forward —
  previously, a `${?NAME}` conditional statement (CASC.md §7.2) inside
  an *imported* file crashed with `KeyError: key :env not found`
  instead of reading the importer's own environment, since the
  imported file's own parse-time context silently dropped that key.

### Added

- `guides/EXAMPLES.md`, `guides/casc/TUTORIAL.md`,
  `guides/casc/CASC_EXAMPLES.md`, and `guides/casc/CASC_CHEATSHEET.md`
  — every example in all four is verified against a real
  `Cooper.load_string/2` call, not just written by hand.

## [0.1.0] - 2026-07-27

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
