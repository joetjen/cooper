defmodule Cooper.Ref.Config do
  @moduledoc """
  An unresolved `%{path}` config reference (CASC.md §7.3). Lazy --
  resolved by `Cooper.Resolver` only after `Cooper.Merge` has run,
  against the fully merged final tree; cycle detection happens there
  too.
  """

  @enforce_keys [:path]
  defstruct path: nil, index: nil, suffix: nil

  @type suffix :: nil | {:default, term()} | {:substitute, term()} | {:required, String.t()}
  @type t :: %__MODULE__{path: [String.t()], index: non_neg_integer() | nil, suffix: suffix()}
end
