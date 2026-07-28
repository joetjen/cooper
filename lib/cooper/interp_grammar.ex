defmodule Cooper.InterpGrammar do
  @moduledoc """
  Loads `casc_interp.aether`. Used only for a double-quoted string's
  content (CASC.md §7) -- see that grammar file's own moduledoc-style
  comment for why bare interpolated values in the main grammar don't go
  through here.

  This sub-grammar is invoked dynamically -- once per double-quoted
  string literal rather than once overall -- which turns out to make
  `Grammar.Native` an even bigger win here than for the main grammar:
  under `Grammar.VM` (`run_vm/1`, kept for the backend-parity
  test/benchmark), *every single string literal* in a parsed file
  re-parsed `casc_interp.aether`'s own source text from scratch;
  `Grammar.Native` (`Cooper.NativeInterpGrammar`, the default here)
  compiles it exactly once, at Cooper's own build time, regardless of
  how many string literals a given file has.
  """

  @doc false
  @spec source() :: String.t()
  def source do
    :code.priv_dir(:cooper) |> Path.join("grammar/casc_interp.aether") |> File.read!()
  end

  @doc false
  @spec grammar() :: Aether.Grammar.t()
  def grammar do
    {:ok, grammar} = Aether.Parser.parse(source(), "casc_interp.aether")
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  @doc """
  Parses `text` (already escape-processed by `Cooper.Actions`) into an
  ordered list of literal string runs and `Cooper.Ref.*` nodes.
  """
  @spec run(String.t()) :: {:ok, list()} | {:error, Ichor.Error.t() | [Ichor.Error.t()]}
  def run(text) do
    Cooper.NativeInterpGrammar.run(text)
  end

  # Kept for `bench/native_vs_vm.exs` and the backend-parity test; not
  # used by any other code in this library anymore.
  @doc false
  @spec run_vm(String.t()) :: {:ok, list()} | {:error, Ichor.Error.t() | [Ichor.Error.t()]}
  def run_vm(text) do
    Grammar.VM.run(grammar(), text, Cooper.InterpActions, nil)
  end
end
