defmodule Cooper.IPv4 do
  @moduledoc """
  A parsed IPv4 address, with an optional CIDR prefix (CASC.md §6.7 --
  `127.0.0.1` or `127.0.0.1/32`). `new/2` is the only way to build one,
  and it's the same validation `Cooper.Actions` runs on a bare literal
  at parse time -- an out-of-range octet or CIDR prefix is a load-time
  `Ichor.Error`, never a crash or a silently-accepted garbage value.
  """

  alias Cooper.CIDR

  @enforce_keys [:address]
  defstruct address: nil, prefix: nil

  @type t :: %__MODULE__{address: :inet.ip4_address(), prefix: 0..32 | nil}

  @bits 32
  @part_bits 8

  @doc """
  Builds a validated address. `address` must be a 4-tuple of `0..255`
  integers; `prefix`, if given, must be `0..32`.
  """
  @spec new(:inet.ip4_address(), 0..32 | nil) :: {:ok, t()} | {:error, String.t()}
  def new(address, prefix \\ nil)

  def new({a, b, c, d} = address, prefix)
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    case CIDR.validate_prefix(prefix, @bits) do
      :ok -> {:ok, %__MODULE__{address: address, prefix: prefix}}
      {:error, _} = err -> err
    end
  end

  def new(address, _prefix), do: {:error, "invalid IPv4 address: #{inspect(address)}"}

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

  @doc "The block's broadcast address (its own prefix carried through unchanged)."
  @spec broadcast(t()) :: t()
  def broadcast(%__MODULE__{} = cidr) do
    int = CIDR.broadcast_int(cidr.address, cidr.prefix, @bits, @part_bits)
    %__MODULE__{address: CIDR.from_int(int, @bits, @part_bits), prefix: cidr.prefix}
  end

  @doc "The netmask implied by the block's prefix, as a bare address (no prefix of its own)."
  @spec netmask(t()) :: t()
  def netmask(%__MODULE__{} = cidr) do
    mask = CIDR.mask(cidr.prefix, @bits)
    %__MODULE__{address: CIDR.from_int(mask, @bits, @part_bits), prefix: nil}
  end

  @doc """
  The first usable host address in the block. For a /31 or /32, where
  every address is usable (no address is reserved as a pure network
  id), this is the network address itself.
  """
  @spec first_host(t()) :: t()
  def first_host(%__MODULE__{} = cidr) do
    {first, _last} = CIDR.host_range(cidr.address, cidr.prefix, @bits, @part_bits)
    %__MODULE__{address: CIDR.from_int(first, @bits, @part_bits), prefix: nil}
  end

  @doc """
  The last usable host address in the block. For a /31 or /32, where
  every address is usable (no address is reserved as a pure broadcast
  id), this is the broadcast address itself.
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
    def inspect(ip, _opts), do: "#Cooper.IPv4<#{ip}>"
  end
end
