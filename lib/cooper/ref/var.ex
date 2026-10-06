defmodule Cooper.Ref.Var do
  @moduledoc """
  An unresolved `@{name}` variable reference (CASC.md §5.2, §7.2).
  Eager, same timing as `Cooper.Ref.Env` -- resolved by
  `Cooper.Resolver`.

  `scope` carries the identity of the file this reference was *written
  in*, stamped by `Cooper.Scope.stamp/2` as soon as that file finishes
  parsing. It exists because visibility is a per-file property but
  resolution is not: `Cooper.Loader` splices every imported file's
  entries into one flat tree, and `Cooper.Resolver` then resolves the
  whole thing against a single variable environment. Without the stamp
  there is no way, at resolve time, to tell which file a given
  `@{name}` came from -- which is exactly what deciding whether it may
  see a private `@*name` requires. See `Cooper.Scope`'s own moduledoc
  for the full visibility model.

  `bound` is `{:ok, value}` for a reference to a `for` loop binding that
  also carries an index, a suffix, or filters (`@{x | upcase}`): the
  iteration's value is attached to the reference, which then resolves
  like any other -- rather than being replaced by the bare value, which
  dropped what it carried. See `Cooper.Loop`.
  """

  @enforce_keys [:name]
  defstruct name: nil, index: nil, suffix: nil, filters: [], scope: nil, bound: nil

  @type t :: %__MODULE__{
          name: String.t(),
          index: non_neg_integer() | nil,
          suffix: Cooper.Ref.Env.suffix(),
          filters: [term()],
          scope: String.t() | nil,
          bound: {:ok, term()} | nil
        }
end
