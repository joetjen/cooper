# Spec coverage

Traceability table mapping every section of
[`CASC.md`](../guides/casc/CASC.md) to the test(s) covering it. Kept
honest rather than complete-looking -- the one genuine gap is called
out explicitly at the bottom, not glossed over.

Legend: ✅ covered · ⚠️ partially covered / known gap · N/A deliberately
out of scope (per the spec itself, not a Cooper gap).

| § | Topic | Status | Test(s) |
|---|---|---|---|
| 1 | Overview | ✅ | Exercised throughout; no standalone test (it's a summary section). |
| 2 | Mandatory header | ✅ | `grammar_test.exs` ("the minimal valid file...", "version header"); `spec_coverage_test.exs` ("missing version header") |
| 3.1 | Whitespace | ✅ | Implicit throughout (default `@skip` splicing); `grammar_test.exs`'s multi-line fixtures |
| 3.2 | Comments | ✅ | `grammar_test.exs` ("comments (CASC.md §3.2)") -- with/without following space, `#TODO` vs `# TODO` disambiguation |
| 4.1 | Key names, atoms, variable names | ✅ | `actions_test.exs` ("atoms"); `spec_coverage_test.exs` ("for/in/from/as are contextual") |
| 4.2 | Quoted key segments | ✅ | `grammar_test.exs` ("quoted key segments") -- double- and single-quoted, dotted position |
| 4.3 | Secret keys | ✅ | `grammar_test.exs` ("secret keys", all 3 prefix positions); `cooper_test.exs`/`secret_test.exs` -- wrapping, redaction, non-secret siblings; `resolver_test.exs` ("secrecy travels with a copied value" / "partial redaction of a secret embedded in a larger string") -- a `%{...}`/`for...from` copy, a tag or index applied to a secret, and multiple secrets interpolated into one string each stay independently redacted, never leaking via a path the wrapping wasn't originally tied to |
| 5.1 | Imports | ✅ | `loader_test.exs` (bare path, brace+glob, cycle detection, unregistered scheme, no-match error); `spec_coverage_test.exs` ("later imports override earlier") |
| 5.2 | Variable declarations | ✅ | `sigils_test.exs` (public/private marker regression); `loader_test.exs` (public visible across imports, private doesn't leak); `spec_coverage_test.exs` (transitive import-of-import) |
| 5.3 | Assignments (`=` optional) | ✅ | `grammar_test.exs` ("dotted paths, nested blocks, and explicit = { } all desugar identically" -- exercises both forms) |
| 5.4 | Key paths and blocks | ✅ | `grammar_test.exs` ("key paths and blocks"); `merge_test.exs` (deep-merge at 3+ levels) |
| 5.5 | Loops | ✅ | `loop_test.exs` (parallel/zipped iteration exact worked example, `from`-template exact worked example, mismatched-length error, index-only error, iterable validation) |
| 5.6 | Disabled statements | ✅ | `grammar_test.exs` ("disabled statements") -- both `#key` and `#*key {...}` forms |
| 5.7 | Merge control sigils + ordering | ✅ | `sigils_test.exs` (each sigil individually, §8.4 flattening); `spec_coverage_test.exs` ("sigil ordering combinations" -- `~*` and `#~*` together) |
| 6.1 | Nil | ✅ | `actions_test.exs` |
| 6.2 | Booleans | ✅ | `actions_test.exs` |
| 6.3 | Numbers | ✅ | `actions_test.exs` (int/hex/oct/bin/float/exponent/digit separators/infinity) |
| 6.4 | Atoms | ✅ | `actions_test.exs` (reserved-word precedence, bare, `:`-sigiled, reaching a reserved-word-named atom) |
| 6.5 | Strings | ⚠️ | `actions_test.exs` (double/single-quoted); `values_test.exs` (triple-quoted dedent); `spec_coverage_test.exs` (triple-quoted does *not* interpolate). **Gap:** backslash-continued strings are not implemented (see bottom of this file). |
| 6.6 | Dates and times | ✅ | `values_test.exs` -- all 4 forms (offset datetime, local datetime, local date, local time) |
| 6.7 | IP addresses | ✅ | `values_test.exs` -- IPv4, IPv4/CIDR, IPv6, IPv6/CIDR, out-of-range octet and CIDR prefix are load-time errors; `ipv4_test.exs`/`ipv6_test.exs` -- validation, `String.Chars`, CIDR containment and network math (`network/1`, `broadcast/1`, `netmask/1`, `first_host/1`, `last_host/1`), including `/31`-`/32` and `/127`-`/128` edge cases |
| 6.8 | Durations | ✅ | `values_test.exs` (basic + compound + fractional + error cases); `spec_coverage_test.exs` ("duration unit table" -- every unit, ns base confirmed) |
| 6.9 | Byte sizes | ✅ | `values_test.exs` (basic + fractional + case-insensitivity); `spec_coverage_test.exs` ("byte-size unit table" -- every decimal *and* binary unit) |
| 6.10 | Lists | ✅ | `values_test.exs` -- comma-separated, newline-separated, mixed types |
| 6.11 | Tuples | ✅ | `values_test.exs`; `cooper_test.exs` ("tuples come back as real Elixir tuples, not lists" -- `is_tuple/1` verified end to end, including through resolution) |
| 7.1 | Variables (`@{}`) | ✅ | `interpolation_test.exs` (unresolved AST); `resolver_test.exs` (resolved: bare, default, substitute, required, indexed, a variable whose own value is itself an unresolved ref, direct/transitive self-reference cycle error) |
| 7.2 | Environment expansion (`${}`) | ✅ | `interpolation_test.exs`; `resolver_test.exs` (spec's own worked example verbatim, never-coerces, unset error, empty-as-unset); `spec_coverage_test.exs` (`${?NAME}` -- spec's own worked example verbatim, guards exactly one statement, skipped content never evaluated) |
| 7.3 | Config references (`%{}`) | ✅ | `interpolation_test.exs`; `resolver_test.exs` (spec's own worked example verbatim, resolves against final tree regardless of declaration order, cycle detection with full path in error) |
| 7.4 | Extensible resolution (`!{}`) | ✅ | `interpolation_test.exs`; `resolver_test.exs` (dispatch, unregistered-name error) |
| 7.5 | Tagged values (`!Name()`) | ✅ | `interpolation_test.exs`; `resolver_test.exs` (all 5 built-ins, nested with `${}`, consumer-registered tag, unregistered-name error) |
| 8.1 | Blocks and maps (deep-merge) | ✅ | `merge_test.exs` |
| 8.2 | Lists (replace wholesale) | ✅ | `merge_test.exs` |
| 8.3 | Tuples (never merge) | ✅ | `merge_test.exs` -- plain replace works; `~`/`+`/`-` against a tuple all raise |
| 8.4 | Overriding the default (sigils) | ✅ | `merge_test.exs` ("§8.4's own worked example, end to end" -- exact documented result); `sigils_test.exs` (op-level) |
| 8.5 | Deferred: merge-by-key | N/A | Explicitly out of scope for this version per the spec itself. |
| 9.1 | Tagged values (extensibility) | ✅ | `resolver_test.exs` |
| 9.2 | Extensible resolvers | ✅ | `resolver_test.exs`; `cooper_test.exs` |
| 9.3 | Extensible import sources | ✅ | `loader_test.exs` (unregistered scheme); `cooper_test.exs` (registered scheme/tag/resolver working together) |
| 9.4 | Failure semantics (never silent) | ✅ | Every unregistered-{tag,resolver,scheme} test above; all raise naming the offender, none silently pass through |
| 10 | Minimal valid file | ✅ | `grammar_test.exs` |

## Open design questions CASC.md doesn't answer, each with a regression test

| # | Question | Resolution | Test |
|---|---|---|---|
| 1 | Do triple-quoted strings interpolate? | Assumed no | `spec_coverage_test.exs` ("triple-quoted strings do not interpolate") |
| 2 | Does `~key` replace every leaf op, or just the top path? | Whole subtree | `merge_test.exs` (§8.4 worked example: `host` disappears, not just `port` set) |
| 3 | Is public-variable visibility across imports transitive? | Assumed yes | `spec_coverage_test.exs` ("public variable visibility is transitive across import-of-import") |
| 4 | `-key = [...]` element removal: value or identity equality? | Value/structural equality | `merge_test.exs` / `sigils_test.exs` (`-tags = ["b"]` removes by value) |
| 5 | Secret-flag merge when a later plain write overwrites a secret path? | Later op's flag wins | `cooper_test.exs` ("a later plain write over a secret path is no longer secret"); `merge_test.exs` (both directions) |
| 6 | What base unit for durations? | Nanoseconds | `spec_coverage_test.exs` ("duration unit table") |

## Known gap

**Backslash-continued strings** (§6.5's fifth string form: "a bare value
starting with `\` at end-of-line joins onto the next line, dropping the
line break") is not implemented. CASC.md gives no worked `Result` block
for this form (unlike triple-quoting's `motd` example), so there was
nothing concrete to validate an implementation against without guessing
at the exact semantics -- flagged in code at `priv/grammar/casc.aether`
and `lib/cooper/actions.ex` wherever the other four string forms are
implemented, rather than silently omitted.
