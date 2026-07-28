defmodule Cooper.Ref.Tagged do
  @moduledoc """
  An unresolved `!Name(arg)` tagged value (CASC.md §7.5). The grammar
  only recognizes "a tag plus one parenthesized argument" -- `arg` is
  already a fully evaluated ordinary value (recursively -- it may
  itself be a nested ref); giving `name` meaning (built-in `int`/
  `float`/`bool`/`duration`/`bytes`, or a consumer-registered tag) is
  `Cooper.Resolver`'s job, via the `:tags` option (see `Cooper`).
  """

  @enforce_keys [:name, :arg]
  defstruct name: nil, arg: nil

  @type t :: %__MODULE__{name: String.t(), arg: term()}
end
