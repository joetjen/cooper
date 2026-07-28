defmodule Cooper.VarDecl do
  @moduledoc """
  A parsed `@name = value` / `@*name = value` variable declaration
  (CASC.md §5.2). Resolution against a variable environment, and
  public/private visibility across imports, is `Cooper.Loader`/
  `Cooper.Resolver` territory -- this struct only carries what the
  grammar can determine locally.
  """

  @enforce_keys [:name, :value, :public?]
  defstruct name: nil, value: nil, public?: true

  @type t :: %__MODULE__{name: String.t(), value: term(), public?: boolean()}
end
