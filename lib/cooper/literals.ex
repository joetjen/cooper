defmodule Cooper.Literals do
  @moduledoc """
  Duration (CASC.md §6.8) and byte-size (§6.9) text parsing, shared
  between `Cooper.Actions` (the bare `500ms`/`512MiB` literal forms) and
  `Cooper.Resolver` (the equivalent `!duration("5m")`/`!bytes("512MiB")`
  tagged-value forms, §7.5 -- "reachable ... for computed/interpolated
  values"). Same rules, same errors, one implementation.
  """

  # Deliberately permissive at the lexer -- see casc.aether's own comment
  # on `DURATION_UNIT`/`DURATION`. This is where CASC.md §6.8's real
  # rules (single-unit literals may be fractional; a compound literal's
  # components must be plain integers, strictly descending, no unit
  # repeated) actually get enforced.
  @duration_unit_ns %{
    "ns" => 1,
    "us" => 1_000,
    "µs" => 1_000,
    "ms" => 1_000_000,
    "s" => 1_000_000_000,
    "m" => 60 * 1_000_000_000,
    "h" => 60 * 60 * 1_000_000_000,
    "d" => 24 * 60 * 60 * 1_000_000_000
  }
  @duration_unit_rank %{
    "d" => 7,
    "h" => 6,
    "m" => 5,
    "s" => 4,
    "ms" => 3,
    "us" => 2,
    "µs" => 2,
    "ns" => 1
  }

  @doc "Parses a duration literal's text into total nanoseconds."
  @spec parse_duration(String.t()) :: {:ok, integer()} | {:error, String.t()}
  def parse_duration(text) do
    components =
      Regex.scan(~r/(\d+(?:\.\d+)?)(ns|us|µs|ms|d|h|m|s)/, text, capture: :all_but_first)

    # `Regex.scan/3` alone doesn't guarantee full coverage -- it happily
    # returns matches for "5msXYZ9s" too, skipping the garbage between
    # them. Re-joining every matched component and comparing back
    # against the original text is what actually rejects that; only a
    # text that's *entirely* amount-unit pairs back to back reaches
    # `validate_duration/2`.
    if Enum.map_join(components, &Enum.join(&1)) != text do
      {:error, "invalid duration literal #{inspect(text)}"}
    else
      validate_duration(components, text)
    end
  end

  defp validate_duration([[amount, unit]], _text) do
    factor = Map.fetch!(@duration_unit_ns, unit)

    value =
      if String.contains?(amount, "."),
        do: String.to_float(amount),
        else: String.to_integer(amount) * 1.0

    {:ok, round(value * factor)}
  end

  defp validate_duration(components, text) when length(components) > 1 do
    ranks = Enum.map(components, fn [_amount, unit] -> Map.fetch!(@duration_unit_rank, unit) end)

    cond do
      Enum.any?(components, fn [amount, _unit] -> String.contains?(amount, ".") end) ->
        {:error, "duration #{inspect(text)}: compound literals must use integer components"}

      ranks != Enum.uniq(ranks) ->
        {:error, "duration #{inspect(text)}: a unit is repeated"}

      ranks != Enum.sort(ranks, :desc) ->
        {:error, "duration #{inspect(text)}: units must be strictly descending"}

      true ->
        total =
          Enum.reduce(components, 0, fn [amount, unit], acc ->
            acc + String.to_integer(amount) * Map.fetch!(@duration_unit_ns, unit)
          end)

        {:ok, total}
    end
  end

  defp validate_duration([], text) do
    {:error, "invalid duration literal #{inspect(text)}"}
  end

  @byte_unit_multiplier %{
    "b" => 1,
    "kb" => 1_000,
    "mb" => 1_000_000,
    "gb" => 1_000_000_000,
    "tb" => 1_000_000_000_000,
    "pb" => 1_000_000_000_000_000,
    "kib" => 1024,
    "mib" => 1024 * 1024,
    "gib" => 1024 * 1024 * 1024,
    "tib" => 1024 * 1024 * 1024 * 1024,
    "pib" => 1024 * 1024 * 1024 * 1024 * 1024
  }

  @doc "Parses a byte-size literal's text into total bytes."
  @spec parse_bytes(String.t()) :: {:ok, integer()} | {:error, String.t()}
  def parse_bytes(text) do
    case Regex.run(~r/^(\d+(?:\.\d+)?)([a-zA-Z]+)$/, text) do
      [_, amount, unit] ->
        case Map.fetch(@byte_unit_multiplier, String.downcase(unit)) do
          {:ok, multiplier} ->
            value =
              if String.contains?(amount, "."),
                do: String.to_float(amount),
                else: String.to_integer(amount) * 1.0

            {:ok, round(value * multiplier)}

          :error ->
            {:error, "invalid byte-size unit in #{inspect(text)}"}
        end

      nil ->
        {:error, "invalid byte-size literal #{inspect(text)}"}
    end
  end
end
