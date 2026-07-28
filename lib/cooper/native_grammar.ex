defmodule Cooper.NativeGrammar do
  @moduledoc """
  `casc.aether`, compiled to direct Elixir function calls at *Cooper's
  own* compile time (`use Ichor, grammar:, actions:`) instead of
  interpreted bytecode (`Grammar.VM`) -- ~2x throughput per Ichor's own
  docs, now that the grammar has stopped changing weekly. `use Ichor`
  bakes in `Cooper.Actions` as the actions module at compile time,
  generating `tokenize/1`, `parse/1`, and `run/1,2` directly on this
  module -- see `Cooper.Grammar`'s own `run_with_context/3` for why
  `run/2` itself still isn't used directly (same reason as under
  `Grammar.VM`: it discards the final context, and `Cooper.Loader`
  needs it back for cross-file variable propagation).
  """

  use Ichor, grammar: "../../priv/grammar/casc.aether", actions: Cooper.Actions
end
