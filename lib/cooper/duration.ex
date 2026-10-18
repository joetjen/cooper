defmodule Cooper.Duration do
  @moduledoc """
  A duration (CASC.md §6.8): `500ms`, `1h30m`, `!duration("5m")`, held in
  nanoseconds.

  **A value of its own, not a tagged tuple.** It was `{:duration, ns}`,
  which a document could also write as a tuple, `(duration, 5)` -- and
  then the two read back as the same thing. A struct is something no
  document can write, so a duration is only ever a duration.

      iex> {:ok, %{"t" => t}} = Cooper.load_string("#@version = 1.0\\nt = 500ms", dotenv: false)
      iex> t
      %Cooper.Duration{nanoseconds: 500_000_000}
      iex> Cooper.Duration.to_milliseconds(t)
      500
  """

  @enforce_keys [:nanoseconds]
  defstruct [:nanoseconds]

  @type t :: %__MODULE__{nanoseconds: integer()}

  @doc """
  `duration` in whole milliseconds, truncated -- what most timeouts on
  the BEAM take.

      iex> Cooper.Duration.to_milliseconds(%Cooper.Duration{nanoseconds: 1_500_000})
      1
  """
  @spec to_milliseconds(t()) :: integer()
  def to_milliseconds(%__MODULE__{nanoseconds: ns}), do: div(ns, 1_000_000)
end
