defmodule Cooper.NativeInterpGrammar do
  @moduledoc """
  `casc_interp.aether`, compiled the same way `Cooper.NativeGrammar` is
  (see its own moduledoc for the full ahead-of-time-generation
  rationale). This sub-grammar is invoked dynamically -- once per
  double-quoted string literal encountered during parsing, not once
  overall -- but that's an argument *for* native codegen here, not
  against it: under `Grammar.VM` (`Cooper.Test.VMParity.run_interp_vm/1`,
  `test/support` only), every one of those calls re-parses
  `casc_interp.aether`'s own source text from scratch; here it's
  compiled exactly once, ahead of Cooper's own build, regardless of how
  many string literals a given file has.

  Unlike `Cooper.NativeGrammar`, `run/2`'s discarded final context is
  never needed here -- `Cooper.InterpActions` never mutates context
  (interpolated string content only ever builds `Cooper.Ref.*` nodes) --
  so `Cooper.InterpGrammar.run/1` calls straight through to this
  module's own `run/2`, no `Ichor.Actions.evaluate/5`-plus-capture-shapes
  workaround needed the way `Cooper.NativeGrammar`'s does.

  Regenerate whenever `priv/grammar/casc_interp.aether` changes:

      mix ichor.gen priv/grammar/casc_interp.aether \\
        --module Cooper.NativeInterpGrammar.Native \\
        --actions Cooper.InterpActions \\
        --out lib/cooper/native_interp_grammar/native.ex
  """

  alias Cooper.NativeInterpGrammar.Native

  @doc "Tokenizes `input`. See `Native.tokenize/2`'s own doc for `context`."
  defdelegate tokenize(input, context \\ nil), to: Native

  @doc "Matches `input` against the grammar's root rule with no `Ichor.Actions` involved -- a bare recognizer."
  defdelegate parse(input, context \\ nil), to: Native

  @doc "Matches and evaluates `input` through `Cooper.InterpActions` -- what `Cooper.InterpGrammar.run/1` calls."
  defdelegate run(input, initial_context \\ nil), to: Native

  @doc "Like `run/2`, but evaluates `input` as a sequence of top-level matches, threading context from each into the next."
  defdelegate run_sequence(input, initial_context), to: Native
end
