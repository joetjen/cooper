defmodule Cooper.Ref.Var do
  @moduledoc """
  An unresolved `@{name}` variable reference (CASC.md §7.1). Eager --
  `Cooper.Resolver` resolves these against the per-file variable
  environment, independent of the final merged tree.
  """

  @enforce_keys [:name]
  defstruct name: nil, index: nil, suffix: nil, filters: []

  @type suffix :: nil | {:default, term()} | {:substitute, term()} | {:required, String.t()}
  @type t :: %__MODULE__{name: String.t(), index: non_neg_integer() | nil, suffix: suffix()}
end
