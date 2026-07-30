defmodule Cooper.NativeGrammar do
  @moduledoc """
  `casc.aether`, compiled to direct Elixir function calls -- ~2x
  throughput per Ichor's own docs, now that the grammar has stopped
  changing weekly.

  The compiled lexer/parser itself lives in this module's own `Native`
  alias (`@moduledoc false` on purpose -- it's generated, not
  hand-authored), generated *ahead of time* by `mix ichor.gen`, checked
  in like any other source file, rather than produced by `use Ichor,
  grammar:, actions:` at *this module's own* compile time. That's a
  deliberate architectural choice, not just style: `use Ichor` needs
  `ichor` proper (the Aether front-end, `Grammar.Analysis`, the native
  codegen backend -- most of that library) at Cooper's own compile
  time, every single time Cooper compiles; a pre-generated `Native`
  module only ever calls into `ichor_runtime`, the small support
  library the generated code actually needs at *runtime* (capture
  dispatch, error formatting, the compiled Tokenizer/Parser). Generating
  ahead of time is what lets `mix.exs` mark `ichor` itself `only:
  [:dev, :test], runtime: false` -- the bulk of Ichor genuinely never
  ships in a `mix release` build of an app depending on `cooper`. This
  module exists so that split is invisible to every other caller in
  Cooper: `Cooper.Grammar`'s `run_with_context/3` and everything built
  on it still just calls `Cooper.NativeGrammar.parse/1`, exactly as if
  the grammar were compiled the old way.

  Regenerate whenever `priv/grammar/casc.aether` changes -- there's no
  automatic staleness check between the checked-in file and its source
  grammar:

      mix ichor.gen priv/grammar/casc.aether \\
        --module Cooper.NativeGrammar.Native \\
        --actions Cooper.Actions \\
        --out lib/cooper/native_grammar/native.ex

  `run/2` itself still isn't used directly by `Cooper.Grammar` -- it
  discards the final context, and `Cooper.Loader` needs it back for
  cross-file variable propagation (see `Cooper.Grammar`'s own
  `run_with_context/3` and this module's other generated companion,
  `CaptureShapes`, for how that's done without needing `ichor` proper
  at runtime either).
  """

  alias Cooper.NativeGrammar.Native

  @doc "Tokenizes `input`. See `Native.tokenize/2`'s own doc for `context`."
  defdelegate tokenize(input, context \\ nil), to: Native

  @doc "Matches `input` against the grammar's root rule with no `Ichor.Actions` involved -- a bare recognizer."
  defdelegate parse(input, context \\ nil), to: Native

  @doc """
  Matches and evaluates `input` through `Cooper.Actions`, discarding
  the final context -- not used by `Cooper.Grammar` itself (see this
  module's own moduledoc), but exposed for parity with what `use Ichor`
  would have generated directly on this module.
  """
  defdelegate run(input, initial_context \\ nil), to: Native

  @doc "Like `run/2`, but evaluates `input` as a sequence of top-level matches, threading context from each into the next."
  defdelegate run_sequence(input, initial_context), to: Native
end
