defmodule Cooper.Merge.Layered do
  @moduledoc """
  A path whose value is a lazy base (a `for`-loop's `from <template>`,
  CASC.md §5.5, resolved by `Cooper.Resolver` against the *final* merged
  tree) with literal statements layered on top as overrides --
  `Cooper.Merge` builds this whenever a later op writes underneath a
  path currently holding a `Cooper.Ref.Config`. `overrides` mirrors the
  assembled tree's own shape (a plain nested map, itself possibly
  containing more `Layered` values at deeper paths); `Cooper.Resolver`
  resolves `base`, deep-merges `overrides` on top, and that's this
  path's final value.
  """

  @enforce_keys [:base, :overrides]
  defstruct base: nil, overrides: %{}

  @type t :: %__MODULE__{base: Cooper.Ref.Config.t(), overrides: map()}
end
