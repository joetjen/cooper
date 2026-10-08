defmodule Cooper.Merge.ListEdit do
  @moduledoc """
  A `+key`/`-key` list edit (CASC.md §8.4) whose base or operand is not
  known until resolution -- `+tags = @{more}`, an edit of a list that is
  itself still a reference, or an edit of a key a `for ... from` template
  supplies. `Cooper.Merge` leaves one at the path; `Cooper.Resolver`
  resolves both sides and applies the edit element-wise.

  Applying the edit at merge time instead, as was once done, appended an
  unresolved reference as one element (`["a", ["b", "c"]]` for `tags =
  ["a"]` then `+tags = @{more}`) and ignored a template's list entirely.

  `base` is a `Cooper.Ref.Config` defaulting to `Cooper.Merge.Absent` when
  it reads from a `for ... from` template, so a template without the key
  is distinguishable from one whose key is `nil`. `path` is only for
  error messages.
  """

  @enforce_keys [:base, :op, :operand, :path]
  defstruct [:base, :op, :operand, :path]

  @type t :: %__MODULE__{
          base: term(),
          op: :append | :remove,
          operand: term(),
          path: [String.t()]
        }
end
