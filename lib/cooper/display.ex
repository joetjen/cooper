defmodule Cooper.Display do
  @moduledoc """
  Stringifies a resolved value for embedding into a string-interpolation
  segment -- shared by `Cooper.Loop` (a loop-bound value substituted into
  an interpolated destination path or body string) and `Cooper.Resolver`
  (an ordinary `@{}`/`${}`/`%{}`/`!{}`/`!Name()` result embedded the same
  way, CASC.md §7).
  """

  @doc false
  @spec to_string(term()) :: String.t()
  def to_string(v) when is_binary(v), do: v
  def to_string(v) when is_integer(v) or is_float(v), do: Kernel.to_string(v)
  def to_string(true), do: "true"
  def to_string(false), do: "false"
  def to_string(v) when is_atom(v), do: Atom.to_string(v)
  # A bare tagged tuple (unlike %Cooper.IPv4{}/%Cooper.IPv6{}, which
  # already implement String.Chars and fall through to the last clause
  # below) has no protocol to dispatch on, so it needs an explicit
  # clause here -- without one, embedding a duration/byte-size value in
  # an interpolated string crashed outright (`Kernel.to_string/1` has
  # no String.Chars implementation for a plain tuple). Both render in
  # their base unit, which is also valid CASC syntax if fed back in.
  def to_string({:duration, ns}), do: "#{ns}ns"
  def to_string({:bytes, n}), do: "#{n}B"
  def to_string(v), do: Kernel.to_string(v)
end
