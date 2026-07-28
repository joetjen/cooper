defmodule Cooper.IPv6Test do
  use ExUnit.Case, async: true

  describe "new/2 validation" do
    test "accepts a well-formed address with no prefix" do
      assert Cooper.IPv6.new({0, 0, 0, 0, 0, 0, 0, 1}) ==
               {:ok, %Cooper.IPv6{address: {0, 0, 0, 0, 0, 0, 0, 1}, prefix: nil}}
    end

    test "accepts a well-formed address with a valid prefix" do
      assert Cooper.IPv6.new({0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32) ==
               {:ok, %Cooper.IPv6{address: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, prefix: 32}}
    end

    test "rejects an out-of-range hextet" do
      assert {:error, message} = Cooper.IPv6.new({0x10000, 0, 0, 0, 0, 0, 0, 1})
      assert message =~ "invalid IPv6 address"
    end

    test "rejects an out-of-range prefix" do
      assert Cooper.IPv6.new({0, 0, 0, 0, 0, 0, 0, 1}, 129) ==
               {:error, "invalid CIDR prefix 129 (must be 0..128)"}
    end
  end

  describe "String.Chars" do
    test "renders without a prefix" do
      assert to_string(%Cooper.IPv6{address: {0, 0, 0, 0, 0, 0, 0, 1}}) == "::1"
    end

    test "renders with a prefix" do
      assert to_string(%Cooper.IPv6{address: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, prefix: 32}) ==
               "2001:db8::/32"
    end
  end

  describe "network/netmask/host-range math" do
    test "an ordinary /32 block" do
      {:ok, cidr} = Cooper.IPv6.new({0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32)

      assert Cooper.IPv6.network(cidr) ==
               %Cooper.IPv6{address: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, prefix: 32}

      assert Cooper.IPv6.netmask(cidr) ==
               %Cooper.IPv6{address: {0xFFFF, 0xFFFF, 0, 0, 0, 0, 0, 0}, prefix: nil}

      assert Cooper.IPv6.first_host(cidr) ==
               %Cooper.IPv6{address: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, prefix: nil}

      assert Cooper.IPv6.last_host(cidr) ==
               %Cooper.IPv6{
                 address: {0x2001, 0xDB8, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFE},
                 prefix: nil
               }
    end

    test "a /128 has no separate network -- every field is the address itself" do
      {:ok, cidr} = Cooper.IPv6.new({0, 0, 0, 0, 0, 0, 0, 1}, 128)

      assert Cooper.IPv6.network(cidr).address == {0, 0, 0, 0, 0, 0, 0, 1}
      assert Cooper.IPv6.first_host(cidr).address == {0, 0, 0, 0, 0, 0, 0, 1}
      assert Cooper.IPv6.last_host(cidr).address == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "a /127 (point-to-point) has both addresses usable" do
      {:ok, cidr} = Cooper.IPv6.new({0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 127)

      assert Cooper.IPv6.first_host(cidr).address == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}
      assert Cooper.IPv6.last_host(cidr).address == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
    end

    test "no prefix at all behaves like /128" do
      {:ok, cidr} = Cooper.IPv6.new({0, 0, 0, 0, 0, 0, 0, 1})
      assert Cooper.IPv6.network(cidr).address == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "/0 covers the entire address space" do
      {:ok, cidr} = Cooper.IPv6.new({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, 0)
      assert Cooper.IPv6.network(cidr).address == {0, 0, 0, 0, 0, 0, 0, 0}
      assert Cooper.IPv6.netmask(cidr).address == {0, 0, 0, 0, 0, 0, 0, 0}
    end
  end

  describe "contains?/2" do
    test "an address inside the block" do
      {:ok, cidr} = Cooper.IPv6.new({0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32)
      {:ok, addr} = Cooper.IPv6.new({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      assert Cooper.IPv6.contains?(cidr, addr)
    end

    test "an address outside the block" do
      {:ok, cidr} = Cooper.IPv6.new({0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32)
      {:ok, addr} = Cooper.IPv6.new({0x2001, 0xDB9, 0, 0, 0, 0, 0, 1})
      refute Cooper.IPv6.contains?(cidr, addr)
    end
  end

  describe "load-time validation via Cooper.Grammar" do
    test "a valid bare literal resolves to a Cooper.IPv6 struct" do
      assert {:ok, %{"v" => %Cooper.IPv6{address: {0, 0, 0, 0, 0, 0, 0, 1}, prefix: 128}}} =
               Cooper.Grammar.run("#@version = 1.0\nv = ::1/128")
    end
  end
end
