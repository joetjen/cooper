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
    # Each component's digits may carry `_` separators (CASC.md §6.8), the
    # same shape the DURATION token accepts: a digit first, then digits or
    # `_`. They are dropped from the amounts once the text is known to be
    # nothing but components.
    components =
      Regex.scan(~r/(\d[\d_]*(?:\.\d[\d_]*)?)(ns|us|µs|ms|d|h|m|s)/u, text,
        capture: :all_but_first
      )

    # `Regex.scan/3` alone doesn't guarantee full coverage -- it happily
    # returns matches for "5msXYZ9s" too, skipping the garbage between
    # them. Re-joining every matched component and comparing back
    # against the original text is what actually rejects that; only a
    # text that's *entirely* amount-unit pairs back to back reaches
    # `validate_duration/2`.
    if Enum.map_join(components, &Enum.join(&1)) != text do
      {:error, "invalid duration literal #{inspect(text)}"}
    else
      components
      |> Enum.map(fn [amount, unit] -> [String.replace(amount, "_", ""), unit] end)
      |> validate_duration(text)
    end
  end

  defp validate_duration([[amount, unit]], _text) do
    {:ok, scaled(amount, Map.fetch!(@duration_unit_ns, unit))}
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

  # `amount` (digits, maybe a fraction) times `factor`, exactly, rounded
  # half away from zero to a whole number. Computing it through a float,
  # as this once did, lost precision above 2^53 -- `9223372036854775807ns`
  # became 2^63, though a compound duration was summed exactly -- and an
  # amount too large for a float crashed the load outright.
  defp scaled(amount, factor) do
    {whole, fraction} =
      case String.split(amount, ".") do
        [whole, fraction] -> {whole, fraction}
        [whole] -> {whole, ""}
      end

    numerator = String.to_integer(whole <> fraction) * factor
    denominator = Integer.pow(10, String.length(fraction))
    div(2 * numerator + denominator, 2 * denominator)
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
            {:ok, scaled(amount, multiplier)}

          :error ->
            {:error, "invalid byte-size unit in #{inspect(text)}"}
        end

      nil ->
        {:error, "invalid byte-size literal #{inspect(text)}"}
    end
  end
end
