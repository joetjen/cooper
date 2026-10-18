defmodule Cooper.Display do
  @moduledoc """
  Stringifies a resolved value for embedding into a string-interpolation
  segment -- shared by `Cooper.Loop` (a loop-bound value substituted into
  an interpolated destination path or body string) and `Cooper.Resolver`
  (an ordinary `@{}`/`${}`/`%{}`/`!{}`/`!Name()` result embedded the same
  way, CASC.md §7).

  A list, map, or tuple has no string form and is refused (`display/1`
  returns `{:error, message}`): without that, `Kernel.to_string/1` read a
  list as iodata -- `"@{ports}"` over `[8443, 8444]` became raw bytes --
  and crashed outright on a tuple or a map.
  """

  @doc false
  @spec display(term()) :: {:ok, String.t()} | {:error, String.t()}
  def display(v) when is_list(v) or is_tuple(v) or (is_map(v) and not is_struct(v)),
    do: {:error, "cannot interpolate #{inspect(v)} into a string"}

  def display(v), do: {:ok, __MODULE__.to_string(v)}

  @doc false
  @spec displayable?(term()) :: boolean()
  def displayable?(v), do: match?({:ok, _}, display(v))

  @doc false
  @spec to_string(term()) :: String.t()
  def to_string(v) when is_binary(v), do: v
  def to_string(v) when is_integer(v) or is_float(v), do: Kernel.to_string(v)
  def to_string(true), do: "true"
  def to_string(false), do: "false"
  # CASC's own spelling (§6.3), which reads back as the same value.
  def to_string(%Cooper.Infinity{sign: :positive}), do: "inf"
  def to_string(%Cooper.Infinity{sign: :negative}), do: "-inf"
  def to_string(v) when is_atom(v), do: Atom.to_string(v)
  # Both render in their base unit, which is also valid CASC syntax if
  # fed back in.
  def to_string(%Cooper.Duration{nanoseconds: ns}), do: "#{ns}ns"
  def to_string(%Cooper.ByteSize{bytes: n}), do: "#{n}B"
  def to_string(v), do: Kernel.to_string(v)
end
