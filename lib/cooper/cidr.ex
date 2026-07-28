defmodule Cooper.CIDR do
  @moduledoc """
  Shared bitwise CIDR math for `Cooper.IPv4`/`Cooper.IPv6` -- both
  address families need the identical operations (prefix -> mask,
  address <-> integer, network/broadcast/host-range math), differing
  only in bit width (32 vs 128) and part width (8-bit octets vs 16-bit
  hextets), so this holds one implementation instead of two
  near-copies. Not meant to be called directly -- use `Cooper.IPv4`/
  `Cooper.IPv6`'s own functions, which already know their own bit width.
  """

  import Bitwise

  @doc false
  @spec validate_prefix(non_neg_integer() | nil, non_neg_integer()) ::
          :ok | {:error, String.t()}
  def validate_prefix(nil, _max), do: :ok
  def validate_prefix(prefix, max) when is_integer(prefix) and prefix in 0..max//1, do: :ok

  def validate_prefix(prefix, max) do
    {:error, "invalid CIDR prefix #{inspect(prefix)} (must be 0..#{max})"}
  end

  @doc false
  @spec to_int(tuple(), pos_integer()) :: non_neg_integer()
  def to_int(address, part_bits) do
    address
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> bsl(acc, part_bits) + part end)
  end

  @doc false
  @spec from_int(non_neg_integer(), pos_integer(), pos_integer()) :: tuple()
  def from_int(int, bits, part_bits) do
    part_mask = bsl(1, part_bits) - 1
    parts = div(bits, part_bits)

    for i <- (parts - 1)..0//-1 do
      int |> bsr(i * part_bits) |> band(part_mask)
    end
    |> List.to_tuple()
  end

  # `prefix: nil` (no CIDR suffix at all) means "this one address," the
  # same as the narrowest possible prefix -- a full host mask.
  @doc false
  @spec mask(non_neg_integer() | nil, pos_integer()) :: non_neg_integer()
  def mask(nil, bits), do: mask(bits, bits)

  def mask(prefix, bits) do
    full = bsl(1, bits) - 1
    full |> bsl(bits - prefix) |> band(full)
  end

  @doc false
  @spec network_int(tuple(), non_neg_integer() | nil, pos_integer(), pos_integer()) ::
          non_neg_integer()
  def network_int(address, prefix, bits, part_bits) do
    to_int(address, part_bits) |> band(mask(prefix, bits))
  end

  @doc false
  @spec broadcast_int(tuple(), non_neg_integer() | nil, pos_integer(), pos_integer()) ::
          non_neg_integer()
  def broadcast_int(address, prefix, bits, part_bits) do
    full = bsl(1, bits) - 1
    network_int(address, prefix, bits, part_bits) ||| bxor(full, mask(prefix, bits))
  end

  # A block with 2 or fewer addresses (/31, /32 for v4; /127, /128 for
  # v6) has no address reserved as a pure network/broadcast id -- every
  # address in it is a usable host (RFC 3021 for the v4 /31 case).
  @doc false
  @spec host_range(tuple(), non_neg_integer() | nil, pos_integer(), pos_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  def host_range(address, prefix, bits, part_bits) do
    network = network_int(address, prefix, bits, part_bits)
    broadcast = broadcast_int(address, prefix, bits, part_bits)
    effective_prefix = prefix || bits

    if effective_prefix >= bits - 1 do
      {network, broadcast}
    else
      {network + 1, broadcast - 1}
    end
  end

  @doc false
  @spec contains?(tuple(), non_neg_integer() | nil, tuple(), pos_integer(), pos_integer()) ::
          boolean()
  def contains?(cidr_address, cidr_prefix, other_address, bits, part_bits) do
    m = mask(cidr_prefix, bits)
    (to_int(cidr_address, part_bits) &&& m) == (to_int(other_address, part_bits) &&& m)
  end
end
