defmodule Cooper.InterpGrammar do
  @moduledoc """
  Loads `casc_interp.aether`. Used only for a double-quoted string's
  content (CASC.md §7) -- see that grammar file's own moduledoc-style
  comment for why bare interpolated values in the main grammar don't go
  through here.

  This sub-grammar is invoked dynamically -- once per double-quoted
  string literal rather than once overall -- which turns out to make
  `Grammar.Native` an even bigger win here than for the main grammar:
  under `Grammar.VM` (`Cooper.Test.VMParity.run_interp_vm/1`, kept for
  the backend-parity test/benchmark, `test/support/` only), *every
  single string literal* in a parsed file re-parsed
  `casc_interp.aether`'s own source text from scratch; `Grammar.Native`
  (`Cooper.NativeInterpGrammar`, compiled ahead of time by `mix
  ichor.gen`, the only backend this module still calls into) compiles
  it exactly once, ahead of Cooper's own build, regardless of how many
  string literals a given file has.
  """

  @doc """
  Parses `text` (already escape-processed by `Cooper.Actions`) into an
  ordered list of literal string runs and `Cooper.Ref.*` nodes.
  """
  @spec run(String.t()) :: {:ok, list()} | {:error, Ichor.Error.t() | [Ichor.Error.t()]}
  def run(text) do
    Cooper.NativeInterpGrammar.run(text)
  end
end
