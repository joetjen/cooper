defmodule Cooper.NativeInterpGrammar do
  @moduledoc """
  `casc_interp.aether`, compiled at Cooper's own compile time the same
  way `Cooper.NativeGrammar` is. This sub-grammar is invoked
  dynamically -- once per double-quoted string literal encountered
  during parsing, not once overall -- but that's an argument *for*
  native codegen here, not against it: under `Grammar.VM`
  (`Cooper.InterpGrammar`'s own `run_vm/1`), every one of those calls
  re-parses `casc_interp.aether`'s own source text from scratch (its
  `grammar/0`); here it's compiled exactly once, at Cooper's own build
  time, regardless of how many string literals a given file has.
  """

  use Ichor, grammar: "../../priv/grammar/casc_interp.aether", actions: Cooper.InterpActions
end
