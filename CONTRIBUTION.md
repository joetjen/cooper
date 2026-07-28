# Contributing to Cooper

Thanks for considering a contribution. This document covers what you need
to know before opening an issue or a pull request.

## Getting started

Cooper depends on Ichor as a local path dependency
(`{:ichor, path: "../ichor"}` in `mix.exs`) — clone both repositories
as siblings before doing anything else:

```sh
git clone <this repository>
git clone <ichor's repository> ../ichor   # must sit next to cooper/
cd cooper
mix deps.get
mix test
```

That should complete with no failures on a clean checkout. If it
doesn't, please open an issue before doing anything else — that's a bug
in its own right.

## Project layout

- `lib/cooper/grammar.ex`, `lib/cooper/actions.ex`,
  `priv/grammar/casc.aether` — the CASC grammar itself and its
  `Ichor.Actions` implementation (lexing/parsing into flattened ops and
  native Elixir literal values).
- `lib/cooper/loop.ex`, `lib/cooper/loader.ex`, `lib/cooper/merge.ex`,
  `lib/cooper/resolver.ex` — the rest of the pipeline: loop expansion,
  import resolution, merge, and reference resolution (`@{}`/`${}`/`%{}`/
  `!{}`/`!Name()`).
- `lib/cooper/interp_grammar.ex`, `lib/cooper/interp_actions.ex`,
  `priv/grammar/casc_interp.aether` — the smaller sub-grammar for
  references embedded inside a double-quoted string's own text.
- `lib/cooper/ref/`, `lib/cooper/merge/layered.ex`,
  `lib/cooper/interp/text.ex` — the unresolved AST node types
  `Cooper.Resolver` walks.
- `lib/cooper.ex`, `lib/cooper/secret.ex` — the public API
  (`load_file/2`/`load_string/2`) and `Cooper.Secret`.
- `test/` — one file per pipeline stage, plus `test/SPEC_COVERAGE.md`
  (a traceability table mapping every CASC.md section to its test(s))
  and `test/fixtures/` for on-disk import fixtures.
- `bench/native_vs_vm.exs` — the `Grammar.Native` vs. `Grammar.VM`
  benchmark.
- `guides/` — the documentation published via ExDoc alongside the
  generated module docs; `guides/casc/CASC.md` is the language
  reference itself.

## Making a change

1. **Tests first, or at least alongside.** A grammar or resolver change
   should come with a test exercising real input/output behavior, not
   just "does this parse." `test/SPEC_COVERAGE.md` exists so a gap in
   coverage is visible rather than assumed away — update it alongside
   any change to what's covered.
2. **Both backends, where it applies.** `Grammar.Native` (the default)
   and `Grammar.VM` (kept for parity/benchmarking) are required to
   agree on every grammar's behavior — `test/cooper/backend_parity_test.exs`
   checks this directly. A change to the grammar or to `Cooper.Actions`
   needs verification against both, not just whichever one you happened
   to be testing against.
3. **Run the full verification pass before opening a PR:**

   ```sh
   mix format
   mix compile --warnings-as-errors --force
   mix test
   mix docs
   ```

4. **Match the existing documentation style.** Default to no comments;
   when one is warranted, explain a non-obvious *why* (a hidden
   constraint, a subtle invariant, the specific bug class it prevents),
   not what the code already makes obvious by being well-named.
   Moduledocs should be self-contained — cite `CASC.md` sections where
   relevant, not an external design document or a numbered build phase,
   since neither exists in this repository; document the library as it
   actually is.
5. **Cross-check against `CASC.md` directly, not just the existing
   tests.** More than one real bug in this library's history was a case
   the spec's own worked examples covered but the test suite hadn't
   gotten to yet — when in doubt, find (or write) the relevant CASC.md
   worked example and confirm the implementation actually produces its
   documented `Result`.

## Reporting bugs

Please include: the CASC source (or a minimal excerpt reproducing the
issue), the options passed to `load_file/2`/`load_string/2`, what you
expected, and what actually happened (including the full
`%Ichor.Error{}`, if one was raised). "Doesn't parse" and "doesn't
work" are much harder to act on than a specific input/expected/actual
triple.

## License

By contributing, you agree that your contributions will be licensed
under the project's [MIT license](LICENSE.txt).
