defmodule Cooper.IPv6 do
  @moduledoc """
  A parsed IPv6 address, with an optional CIDR prefix (CASC.md §6.7 --
  `::1` or `::1/128`). `new/2` is the only way to build one, and it's
  the same validation `Cooper.Actions` runs on a bare literal at parse
  time -- a malformed address or an out-of-range CIDR prefix is a
  load-time `Ichor.Error`, never a crash or a silently-accepted garbage
  value.

  Unlike `Cooper.IPv4`, there's no `broadcast/1` here -- IPv6 has no
  broadcast address; its closest relative (multicast) isn't a function
  of a single CIDR block the way an IPv4 broadcast address is, so
  faking one would be misleading.
  """

  alias Cooper.CIDR

  @enforce_keys [:address]
  defstruct address: nil, prefix: nil

  @type t :: %__MODULE__{address: :inet.ip6_address(), prefix: 0..128 | nil}

  @bits 128
  @part_bits 16

  @doc """
  Builds a validated address. `address` must be an 8-tuple of `0..65535`
  integers; `prefix`, if given, must be `0..128`.
  """
  @spec new(:inet.ip6_address(), 0..128 | nil) :: {:ok, t()} | {:error, String.t()}
  def new(address, prefix \\ nil)

  def new({a, b, c, d, e, f, g, h} = address, prefix)
      when a in 0..65_535 and b in 0..65_535 and c in 0..65_535 and d in 0..65_535 and
             e in 0..65_535 and f in 0..65_535 and g in 0..65_535 and h in 0..65_535 do
    case CIDR.validate_prefix(prefix, @bits) do
      :ok -> {:ok, %__MODULE__{address: address, prefix: prefix}}
      {:error, _} = err -> err
    end
  end

  def new(address, _prefix), do: {:error, "invalid IPv6 address: #{inspect(address)}"}

  @doc "Whether `other`'s address falls within `cidr`'s block."
  @spec contains?(t(), t()) :: boolean()
  def contains?(%__MODULE__{} = cidr, %__MODULE__{} = other) do
    CIDR.contains?(cidr.address, cidr.prefix, other.address, @bits, @part_bits)
  end

  @doc "The block's network address (its own prefix carried through unchanged)."
  @spec network(t()) :: t()
  def network(%__MODULE__{} = cidr) do
    int = CIDR.network_int(cidr.address, cidr.prefix, @bits, @part_bits)
    %__MODULE__{address: CIDR.from_int(int, @bits, @part_bits), prefix: cidr.prefix}
  end

  @doc "The netmask implied by the block's prefix, as a bare address (no prefix of its own)."
  @spec netmask(t()) :: t()
  def netmask(%__MODULE__{} = cidr) do
    mask = CIDR.mask(cidr.prefix, @bits)
    %__MODULE__{address: CIDR.from_int(mask, @bits, @part_bits), prefix: nil}
  end

  @doc """
  The first usable host address in the block. For a /127 or /128, where
  every address is usable, this is the network address itself.
  """
  @spec first_host(t()) :: t()
  def first_host(%__MODULE__{} = cidr) do
    {first, _last} = CIDR.host_range(cidr.address, cidr.prefix, @bits, @part_bits)
    %__MODULE__{address: CIDR.from_int(first, @bits, @part_bits), prefix: nil}
  end

  @doc """
  The last usable host address in the block. For a /127 or /128, where
  every address is usable, this is the highest address in the block.
  """
  @spec last_host(t()) :: t()
  def last_host(%__MODULE__{} = cidr) do
    {_first, last} = CIDR.host_range(cidr.address, cidr.prefix, @bits, @part_bits)
    %__MODULE__{address: CIDR.from_int(last, @bits, @part_bits), prefix: nil}
  end

  defimpl String.Chars do
    def to_string(%{address: address, prefix: nil}) do
      address |> :inet.ntoa() |> List.to_string()
    end

    def to_string(%{address: address, prefix: prefix}) do
      "#{address |> :inet.ntoa() |> List.to_string()}/#{prefix}"
    end
  end

  defimpl Inspect do
    def inspect(ip, _opts), do: "#Cooper.IPv6<#{ip}>"
  end
end
