defmodule Cooper.ByteSize do
  @moduledoc """
  A byte size (CASC.md §6.9): `512MiB`, `10GB`, `!bytes("1.5GiB")`, held
  in bytes.

  **A value of its own, not a tagged tuple**, for the reason
  `Cooper.Duration` gives: `{:bytes, n}` was also what a document's
  tuple `(bytes, 5)` read as.

      iex> {:ok, %{"m" => m}} = Cooper.load_string("#@version = 1.0\\nm = 2KiB", dotenv: false)
      iex> m
      %Cooper.ByteSize{bytes: 2048}
  """

  @enforce_keys [:bytes]
  defstruct [:bytes]

  @type t :: %__MODULE__{bytes: integer()}
end
