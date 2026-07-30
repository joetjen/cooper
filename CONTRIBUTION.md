# Contributing to Cooper

Thanks for considering a contribution. This document covers what you need
to know before opening an issue or a pull request.

## Getting started

```sh
git clone <this repository>
cd cooper
mix deps.get
mix test
```

That should complete with no failures on a clean checkout. If it
doesn't, please open an issue before doing anything else — that's a bug
in its own right. `.tool-versions` pins the exact Erlang/Elixir this
repo is developed against, if you use `asdf`.

Cooper depends on two Hex packages from Ichor's `ichor`/`ichor_runtime`
split (see `mix.exs`'s own comment on its `deps/0`): `ichor_runtime`,
an ordinary runtime dependency, and `ichor` itself, `only: [:dev,
:test]` — needed only by `mix ichor.gen` (regenerating
`lib/cooper/native_grammar/native.ex`/`lib/cooper/native_interp_grammar/native.ex`,
see "Changing the grammar" below) and by the `Grammar.VM` parity
backend under `test/support/`. Both are independently published and
maintained (`ichor_runtime` is its own repository, not a subdirectory
of `ichor`'s) — `mix deps.get` fetches both from Hex like any other
dependency, no local Ichor checkout needed.

## Project layout

- `lib/cooper/grammar.ex`, `lib/cooper/actions.ex`,
  `priv/grammar/casc.aether` — the CASC grammar itself and its
  `Ichor.Actions` implementation (lexing/parsing into flattened ops and
  native Elixir literal values).
- `lib/cooper/native_grammar.ex`, `lib/cooper/native_grammar/native.ex`,
  `lib/cooper/native_grammar/capture_shapes.ex` — the compiled parser:
  a thin hand-written wrapper, `mix ichor.gen`'s generated output (do
  not hand-edit, see "Changing the grammar" below), and a small
  ahead-of-time-generated companion (`scripts/gen_capture_shapes.exs`)
  `Cooper.Grammar`'s `run_with_context/3` needs to get the final parse
  context back without requiring `ichor` proper at runtime.
- `lib/cooper/loop.ex`, `lib/cooper/loader.ex`, `lib/cooper/merge.ex`,
  `lib/cooper/resolver.ex` — the rest of the pipeline: loop expansion,
  import resolution, merge, and reference resolution (`@{}`/`${}`/`%{}`/
  `!{}`/`!Name()`).
- `lib/cooper/interp_grammar.ex`, `lib/cooper/native_interp_grammar.ex`,
  `lib/cooper/native_interp_grammar/native.ex`, `lib/cooper/interp_actions.ex`,
  `priv/grammar/casc_interp.aether` — the smaller sub-grammar for
  references embedded inside a double-quoted string's own text.
- `lib/cooper/ref/`, `lib/cooper/merge/layered.ex`,
  `lib/cooper/interp/text.ex` — the unresolved AST node types
  `Cooper.Resolver` walks.
- `lib/cooper.ex`, `lib/cooper/secret.ex` — the public API
  (`load_file/2`/`load_string/2`) and `Cooper.Secret`.
- `test/` — one file per pipeline stage, plus `test/SPEC_COVERAGE.md`
  (a traceability table mapping every CASC.md section to its test(s)),
  `test/fixtures/` for on-disk import fixtures, and `test/support/` for
  the `Grammar.VM` parity backend (`ichor`-dependent, `:test`-only).
- `bench/native_vs_vm.exs` — the `Grammar.Native` vs. `Grammar.VM`
  benchmark (`MIX_ENV=test mix run bench/native_vs_vm.exs` -- see its
  own header comment for why).
- `scripts/gen_capture_shapes.exs` — regenerates
  `lib/cooper/native_grammar/capture_shapes.ex`; see "Changing the
  grammar" below.
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
   and `Grammar.VM` (kept for parity/benchmarking, `test/support/` only)
   are required to agree on every grammar's behavior —
   `test/cooper/backend_parity_test.exs` checks this directly. A change
   to the grammar or to `Cooper.Actions` needs verification against
   both, not just whichever one you happened to be testing against.
3. **Changing the grammar.** Editing `priv/grammar/casc.aether` or
   `priv/grammar/casc_interp.aether` requires regenerating the checked-in
   compiled parser afterward — there's no automatic staleness check
   between the two:

   ```sh
   mix ichor.gen priv/grammar/casc.aether \
     --module Cooper.NativeGrammar.Native \
     --actions Cooper.Actions \
     --out lib/cooper/native_grammar/native.ex

   mix ichor.gen priv/grammar/casc_interp.aether \
     --module Cooper.NativeInterpGrammar.Native \
     --actions Cooper.InterpActions \
     --out lib/cooper/native_interp_grammar/native.ex

   mix run scripts/gen_capture_shapes.exs
   ```

   The third command only matters for `casc.aether` (see
   `Cooper.Grammar`'s own moduledoc for why `casc_interp.aether` doesn't
   need it). Run `mix test` afterward — a grammar change that isn't
   regenerated will make `Cooper.NativeGrammar`'s behavior silently
   drift from `priv/grammar/casc.aether`'s own text, and the backend
   parity test above is what would eventually catch that, not a compile
   error.
4. **Run the full verification pass before opening a PR:**

   ```sh
   mix precommit
   mix docs
   ```

   `mix precommit` (an alias defined in `mix.exs`) runs `format`,
   `compile --warnings-as-errors`, `credo --strict`, `sobelow`, `test`,
   and `dialyzer`, in that fast-to-slow order, all under `MIX_ENV=test`
   (`cli/0`'s own `preferred_envs` -- needed so `test`, running as an
   alias step rather than the top-level command, doesn't refuse to run
   outside `:test`, and so Credo/Dialyzer see `test/support/` at all).
   `mix docs` isn't part of the alias (nothing fails a PR over stale
   generated HTML), but run it anyway if you touched a moduledoc or any
   file under `guides/` — broken cross-references between docs are easy
   to introduce and ExDoc doesn't fail the build over them (see the
   Sobelow/Dialyzer note below for the parallel case that *does* fail
   the build).

   First run only: Dialyzer needs to build a PLT (persistent lookup
   table), which takes a minute or two; every run after that is fast.
   New low-confidence Sobelow findings or Dialyzer warnings aren't
   automatically wrong — some are inherent to what a function does
   (e.g. `Cooper.load_file/2` reading a caller-supplied path *is*
   "directory traversal" by Sobelow's literal definition, and that's
   the function's entire job) or a known class of Dialyzer noise around
   opaque types (see `.dialyzer_ignore.exs`'s own comments) rather than
   a real bug — but treat each one as worth a specific justification,
   not a reflexive ignore-list entry.

5. **Match the existing documentation style.** Default to no comments;
   when one is warranted, explain a non-obvious *why* (a hidden
   constraint, a subtle invariant, the specific bug class it prevents),
   not what the code already makes obvious by being well-named.
   Moduledocs should be self-contained — cite `CASC.md` sections where
   relevant, not an external design document or a numbered build phase,
   since neither exists in this repository; document the library as it
   actually is.
6. **Cross-check against `CASC.md` directly, not just the existing
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
under the project's [MIT license](LICENSE).
