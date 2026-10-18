defmodule Cooper.Infinity do
  @moduledoc """
  Infinity (CASC.md §6.3): `inf`, `+inf` or `-inf`. The BEAM's floats
  have no infinity, so CASC's is a value of its own.

  **Not the atoms `:infinity` and `:neg_infinity`**, which it once was:
  those are atoms a document can write -- `infinity` is not a reserved
  word -- and then the atom and the number read back as the same thing.

      iex> {:ok, %{"x" => x}} = Cooper.load_string("#@version = 1.0\\nx = -inf", dotenv: false)
      iex> x
      %Cooper.Infinity{sign: :negative}
  """

  @enforce_keys [:sign]
  defstruct [:sign]

  @type t :: %__MODULE__{sign: :positive | :negative}
end
