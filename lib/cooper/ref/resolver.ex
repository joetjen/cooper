defmodule Cooper.Ref.Resolver do
  @moduledoc """
  An unresolved `!{resolver:payload}` extensible-resolver call (CASC.md
  §7.4). `payload` is carried verbatim (never parsed further) -- giving
  it meaning is entirely the consumer-registered resolver's job, wired
  up via `Cooper.Resolver` and the `:resolvers` option (see `Cooper`).
  An unregistered resolver name is a hard error at resolve time, never
  silently passed through.
  """

  @enforce_keys [:name, :payload]
  defstruct name: nil, payload: nil

  @type t :: %__MODULE__{name: String.t(), payload: String.t()}
end
