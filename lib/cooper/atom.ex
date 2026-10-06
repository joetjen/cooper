defmodule Cooper.Atom do
  @moduledoc """
  The CASC atoms `:true`, `:false` and `:nil` (CASC.md §6.4).

  CASC keeps an atom named after a reserved word apart from the value the
  word stands for: `enabled = :true` is an atom, `enabled = true` the
  boolean. On the BEAM those three atoms *are* the values -- `:true ===
  true` -- so a native atom cannot carry the difference. They load as this
  struct instead; every other atom, `:inf` included, stays a native atom.

  Loading them as the values, as this once did, made `:true` and `true`
  the same configuration, which the copies of this library (where an atom
  and a boolean are different things) did not.
  """

  @enforce_keys [:name]
  defstruct [:name]

  @type t :: %__MODULE__{name: String.t()}

  @reserved ~w(true false nil)

  @doc """
  The atom named `text`: a `Cooper.Atom` for `true`, `false` or `nil`, a
  native atom for anything else.
  """
  @spec new(String.t()) :: t() | atom()
  def new(text) when text in @reserved, do: %__MODULE__{name: text}
  def new(text), do: String.to_atom(text)

  defimpl String.Chars do
    def to_string(%{name: name}), do: name
  end

  defimpl Inspect do
    def inspect(%{name: name}, _opts), do: "#Cooper.Atom<:#{name}>"
  end
end
