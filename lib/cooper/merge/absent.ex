defmodule Cooper.Merge.Absent do
  @moduledoc """
  Marks a key removed from what a lazy `for ... from` template supplies --
  `-key` in the loop body, or a list edit of a key the template turns out
  not to have. Only ever appears inside a `Cooper.Merge.Layered`'s
  overrides; resolving the `Layered` drops the key.

  Before it existed, a `-key` in such a loop body was a no-op: the key
  lives in the template, not in the tree the delete looked in.
  """

  defstruct []

  @type t :: %__MODULE__{}
end
