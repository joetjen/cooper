defmodule Cooper.IPv4Test do
  use ExUnit.Case, async: true

  describe "new/2 validation" do
    test "accepts a well-formed address with no prefix" do
      assert Cooper.IPv4.new({127, 0, 0, 1}) ==
               {:ok, %Cooper.IPv4{address: {127, 0, 0, 1}, prefix: nil}}
    end

    test "accepts a well-formed address with a valid prefix" do
      assert Cooper.IPv4.new({10, 0, 0, 0}, 8) ==
               {:ok, %Cooper.IPv4{address: {10, 0, 0, 0}, prefix: 8}}
    end

    test "rejects an out-of-range octet" do
      assert {:error, message} = Cooper.IPv4.new({256, 0, 0, 1})
      assert message =~ "invalid IPv4 address"
    end

    test "rejects an out-of-range prefix" do
      assert Cooper.IPv4.new({10, 0, 0, 0}, 33) ==
               {:error, "invalid CIDR prefix 33 (must be 0..32)"}
    end

    test "rejects a negative prefix" do
      assert Cooper.IPv4.new({10, 0, 0, 0}, -1) ==
               {:error, "invalid CIDR prefix -1 (must be 0..32)"}
    end
  end

  describe "String.Chars" do
    test "renders without a prefix" do
      assert to_string(%Cooper.IPv4{address: {127, 0, 0, 1}}) == "127.0.0.1"
    end

    test "renders with a prefix" do
      assert to_string(%Cooper.IPv4{address: {127, 0, 0, 1}, prefix: 32}) == "127.0.0.1/32"
    end
  end

  describe "network/broadcast/netmask/host-range math" do
    test "an ordinary /24 block" do
      {:ok, cidr} = Cooper.IPv4.new({192, 168, 1, 200}, 24)

      assert Cooper.IPv4.network(cidr) ==
               %Cooper.IPv4{address: {192, 168, 1, 0}, prefix: 24}

      assert Cooper.IPv4.broadcast(cidr) ==
               %Cooper.IPv4{address: {192, 168, 1, 255}, prefix: 24}

      assert Cooper.IPv4.netmask(cidr) ==
               %Cooper.IPv4{address: {255, 255, 255, 0}, prefix: nil}

      assert Cooper.IPv4.first_host(cidr) ==
               %Cooper.IPv4{address: {192, 168, 1, 1}, prefix: nil}

      assert Cooper.IPv4.last_host(cidr) ==
               %Cooper.IPv4{address: {192, 168, 1, 254}, prefix: nil}
    end

    test "a /32 has no separate network/broadcast -- every field is the address itself" do
      {:ok, cidr} = Cooper.IPv4.new({10, 0, 0, 5}, 32)

      assert Cooper.IPv4.network(cidr).address == {10, 0, 0, 5}
      assert Cooper.IPv4.broadcast(cidr).address == {10, 0, 0, 5}
      assert Cooper.IPv4.first_host(cidr).address == {10, 0, 0, 5}
      assert Cooper.IPv4.last_host(cidr).address == {10, 0, 0, 5}
    end

    test "a /31 (RFC 3021 point-to-point) has both addresses usable, no reserved network/broadcast" do
      {:ok, cidr} = Cooper.IPv4.new({10, 0, 0, 0}, 31)

      assert Cooper.IPv4.network(cidr).address == {10, 0, 0, 0}
      assert Cooper.IPv4.broadcast(cidr).address == {10, 0, 0, 1}
      assert Cooper.IPv4.first_host(cidr).address == {10, 0, 0, 0}
      assert Cooper.IPv4.last_host(cidr).address == {10, 0, 0, 1}
    end

    test "no prefix at all behaves like /32" do
      {:ok, cidr} = Cooper.IPv4.new({10, 0, 0, 5})

      assert Cooper.IPv4.network(cidr).address == {10, 0, 0, 5}
      assert Cooper.IPv4.netmask(cidr).address == {255, 255, 255, 255}
    end

    test "/0 covers the entire address space" do
      {:ok, cidr} = Cooper.IPv4.new({1, 2, 3, 4}, 0)

      assert Cooper.IPv4.network(cidr).address == {0, 0, 0, 0}
      assert Cooper.IPv4.broadcast(cidr).address == {255, 255, 255, 255}
      assert Cooper.IPv4.netmask(cidr).address == {0, 0, 0, 0}
    end
  end

  describe "contains?/2" do
    test "an address inside the block" do
      {:ok, cidr} = Cooper.IPv4.new({192, 168, 1, 0}, 24)
      {:ok, addr} = Cooper.IPv4.new({192, 168, 1, 200})
      assert Cooper.IPv4.contains?(cidr, addr)
    end

    test "an address outside the block" do
      {:ok, cidr} = Cooper.IPv4.new({192, 168, 1, 0}, 24)
      {:ok, addr} = Cooper.IPv4.new({192, 168, 2, 1})
      refute Cooper.IPv4.contains?(cidr, addr)
    end

    test "a nil-prefix cidr only contains its own exact address" do
      {:ok, cidr} = Cooper.IPv4.new({127, 0, 0, 1})
      {:ok, same} = Cooper.IPv4.new({127, 0, 0, 1})
      {:ok, other} = Cooper.IPv4.new({127, 0, 0, 2})
      assert Cooper.IPv4.contains?(cidr, same)
      refute Cooper.IPv4.contains?(cidr, other)
    end
  end

  describe "load-time validation via Cooper.Grammar" do
    test "a valid bare literal resolves to a Cooper.IPv4 struct" do
      assert {:ok, %{"v" => %Cooper.IPv4{address: {127, 0, 0, 1}, prefix: 32}}} =
               Cooper.Grammar.run("#@version = 1.0\nv = 127.0.0.1/32")
    end
  end
end
