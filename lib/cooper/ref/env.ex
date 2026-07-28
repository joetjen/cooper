defmodule Cooper.Ref.Env do
  @moduledoc """
  An unresolved `${NAME}` environment reference (CASC.md §7.2). Eager,
  same timing as `Cooper.Ref.Var` -- resolved by `Cooper.Resolver`,
  always to a string unless wrapped in a tagged value (`!int(...)` etc).
  """

  @enforce_keys [:name]
  defstruct name: nil, index: nil, list?: false, suffix: nil

  @type suffix :: nil | {:default, term()} | {:substitute, term()} | {:required, String.t()}

  @type t :: %__MODULE__{
          name: String.t(),
          index: non_neg_integer() | nil,
          list?: boolean(),
          suffix: suffix()
        }
end
