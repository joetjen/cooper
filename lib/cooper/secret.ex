defmodule Cooper.Secret do
  @moduledoc """
  Wraps a secret leaf value (CASC.md §4.3's `*key`-prefixed keys) in the
  final result `Cooper.load_file/2`/`Cooper.load_string/2` return, so it
  never leaks by accident: `inspect/1` (via `IO.inspect/2`, pattern-match
  failures, logging, ...) and `to_string/1` both redact regardless of the
  wrapped value. Reach the real value deliberately via `reveal/1` (or the
  `:value` field directly) -- the wrapping is only ever a display-time
  concern, never a barrier to the developer's own deliberate use of the
  real value; there would be no point config-loading a secret otherwise.

  This is an ergonomics tax on purpose -- `config.database.password ==
  expected` needs `Cooper.Secret.reveal(config.database.password) ==
  expected` instead. Worth it for a library whose whole point is not
  leaking credentials by accident.

  ## Partial redaction

  A secret value embedded inside a larger interpolated string (CASC.md
  §7 -- `"postgres://user:%{database.password}@host"`) redacts only the
  embedded portion, not the whole string -- `to_string/1`/`inspect/1`
  render `"postgres://user:[~~REDACTED~~]@host"`, and a string with
  several secrets interpolated into it redacts each independently at
  its own position. `:redacted` carries that precomputed display text;
  `nil` (the default, used for an ordinary whole-value secret like a
  bare `*password = "..."`, no interpolation involved) falls back to
  the blanket `[~~REDACTED~~]` marker. Either way, `:value`/`reveal/1`
  still give back the real, fully unmasked value -- redaction is
  display-only.
  """

  @enforce_keys [:value]
  defstruct value: nil, redacted: nil

  @type t :: %__MODULE__{value: term(), redacted: String.t() | nil}

  @doc "Unwraps a `Cooper.Secret`, returning the real, fully unmasked value underneath."
  @spec reveal(t()) :: term()
  def reveal(%__MODULE__{value: value}), do: value

  defimpl Inspect do
    def inspect(%{redacted: nil}, _opts), do: "[~~REDACTED~~]"
    def inspect(%{redacted: redacted}, _opts), do: Kernel.inspect(redacted)
  end

  defimpl String.Chars do
    def to_string(%{redacted: nil}), do: "[~~REDACTED~~]"
    def to_string(%{redacted: redacted}), do: redacted
  end
end
