defmodule Cooper.Interp.Text do
  @moduledoc """
  A double-quoted string's content, once it's been found to contain at
  least one interpolation reference -- an ordered list of literal string
  runs and `Cooper.Ref.*` nodes. `Cooper.Resolver` resolves each segment
  and joins the results into the final string. A double-quoted string with *no*
  references at all is represented as a plain Elixir string instead
  (`Cooper.Actions` never wraps pure literal text in this struct) --
  keeps the common case cheap and keeps existing scalar-string
  assumptions elsewhere intact.
  """

  @enforce_keys [:segments]
  defstruct segments: []

  @type segment ::
          String.t()
          | Cooper.Ref.Var.t()
          | Cooper.Ref.Env.t()
          | Cooper.Ref.Config.t()
          | Cooper.Ref.Resolver.t()
          | Cooper.Ref.Tagged.t()
  @type t :: %__MODULE__{segments: [segment()]}
end
