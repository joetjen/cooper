defmodule Cooper.ValuesTest do
  use ExUnit.Case, async: true

  defp value(literal) do
    {:ok, %{"v" => value}} = Cooper.Grammar.run("#@version = 1.0\nv = #{literal}")
    value
  end

  describe "dates and times (CASC.md §6.6)" do
    test "offset datetime" do
      assert value("1979-05-27T07:32:00Z") == ~U[1979-05-27 07:32:00Z]
    end

    test "offset datetime with a numeric offset" do
      assert {:ok, expected, 7200} = DateTime.from_iso8601("1979-05-27T07:32:00+02:00")
      assert value("1979-05-27T07:32:00+02:00") == expected
    end

    test "local datetime" do
      assert value("1979-05-27T07:32:00") == ~N[1979-05-27 07:32:00]
    end

    test "local date" do
      assert value("1979-05-27") == ~D[1979-05-27]
    end

    test "local time" do
      assert value("07:32:00") == ~T[07:32:00]
    end
  end

  describe "IP addresses (CASC.md §6.7)" do
    test "IPv4" do
      assert value("127.0.0.1") == %Cooper.IPv4{address: {127, 0, 0, 1}, prefix: nil}
    end

    test "IPv4 with CIDR" do
      assert value("127.0.0.1/32") == %Cooper.IPv4{address: {127, 0, 0, 1}, prefix: 32}
    end

    test "IPv6" do
      assert value("::1") == %Cooper.IPv6{address: {0, 0, 0, 0, 0, 0, 0, 1}, prefix: nil}
    end

    test "IPv6 with CIDR" do
      assert value("::1/128") == %Cooper.IPv6{address: {0, 0, 0, 0, 0, 0, 0, 1}, prefix: 128}
    end

    test "an out-of-range octet is a load-time error, not a crash" do
      assert {:error, %Ichor.Error{stage: :action, message: message}} =
               Cooper.Grammar.run("#@version = 1.0\nv = 999.999.999.999")

      assert message =~ "invalid IP address"
    end

    test "a literal's load-time error says where the literal is" do
      assert {:error, %Ichor.Error{stage: :action, line: 3, column: 5}} =
               Cooper.Grammar.run("#@version = 1.0\na = 1\nv = 999.999.999.999")
    end

    test "an out-of-range CIDR prefix is a load-time error" do
      assert {:error, %Ichor.Error{stage: :action, message: message}} =
               Cooper.Grammar.run("#@version = 1.0\nv = 127.0.0.1/33")

      assert message == "invalid CIDR prefix 33 (must be 0..32)"

      assert {:error, %Ichor.Error{stage: :action, message: v6_message}} =
               Cooper.Grammar.run("#@version = 1.0\nv = ::1/129")

      assert v6_message == "invalid CIDR prefix 129 (must be 0..128)"
    end
  end

  describe "durations (CASC.md §6.8)" do
    test "a simple millisecond literal" do
      assert value("500ms") == %Cooper.Duration{nanoseconds: 500_000_000}
    end

    test "a compound literal" do
      assert value("1h30m") == %Cooper.Duration{nanoseconds: 5_400_000_000_000}
    end

    test "a fractional single-unit literal" do
      assert value("1.5h") == %Cooper.Duration{nanoseconds: 5_400_000_000_000}
    end

    test "rejects a fractional component in a compound literal" do
      assert {:error, _} = Cooper.Grammar.run("#@version = 1.0\nv = 1.5h30m")
    end

    test "rejects out-of-order units" do
      assert {:error, _} = Cooper.Grammar.run("#@version = 1.0\nv = 30m1h")
    end
  end

  describe "byte sizes (CASC.md §6.9)" do
    test "binary units" do
      assert value("512MiB") == %Cooper.ByteSize{bytes: 536_870_912}
    end

    test "decimal units" do
      assert value("10GB") == %Cooper.ByteSize{bytes: 10_000_000_000}
    end

    test "fractional numerals" do
      assert value("1.5GiB") == %Cooper.ByteSize{bytes: 1_610_612_736}
    end

    test "case-insensitive matching" do
      assert value("10gb") == %Cooper.ByteSize{bytes: 10_000_000_000}
      assert value("10Gb") == %Cooper.ByteSize{bytes: 10_000_000_000}
    end
  end

  describe "triple-quoted strings (CASC.md §6.5)" do
    test "strips the smallest common leading whitespace" do
      source = ~s(#@version = 1.0
        motd = """
            Welcome to the service.
            Status: operational
            """)

      assert {:ok, %{"motd" => "Welcome to the service.\nStatus: operational\n"}} =
               Cooper.Grammar.run(source)
    end
  end

  describe "lists (CASC.md §6.10)" do
    test "comma-separated" do
      assert value(~S(["a", "b", "c"])) == ["a", "b", "c"]
    end

    test "newline-separated, no commas" do
      source = "#@version = 1.0\nv = [\n  \"a\"\n  \"b\"\n]"
      assert {:ok, %{"v" => ["a", "b"]}} = Cooper.Grammar.run(source)
    end

    test "mixed value types" do
      assert value("[1, 2.5, true, nil, info]") == [1, 2.5, true, nil, :info]
    end
  end

  describe "tuples (CASC.md §6.11)" do
    test "become real Elixir tuples, not lists" do
      result = value("(52.5200, 13.4050)")
      assert result == {52.52, 13.405}
      assert is_tuple(result)
    end
  end

  describe "an impossible date or time is a load-time error, not a crash" do
    test "dates, times, and date-times" do
      for literal <- ["2023-02-30", "25:00:00", "2023-02-30T07:32:00", "2023-02-30T07:32:00Z"] do
        assert {:error, %Ichor.Error{stage: :action, message: message}} =
                 Cooper.Grammar.run("#@version = 1.0\nv = #{literal}")

        assert message =~ "invalid"
        assert message =~ literal
      end
    end
  end

  describe "duration and byte-size arithmetic" do
    test "is exact beyond 2^53, as a compound duration already was" do
      assert {:ok, 9_223_372_036_854_775_807} =
               Cooper.Literals.parse_duration("9223372036854775807ns")

      assert {:ok, 9_007_199_254_740_993} = Cooper.Literals.parse_bytes("9007199254740993B")
    end

    test "rounds a fraction half away from zero" do
      assert {:ok, 2} = Cooper.Literals.parse_duration("1.5ns")
      assert {:ok, 1} = Cooper.Literals.parse_duration("0.5ns")
      assert {:ok, 1001} = Cooper.Literals.parse_bytes("1.0005KB")
    end

    test "takes an amount too large for a float" do
      huge = String.duplicate("9", 400)
      assert {:ok, n} = Cooper.Literals.parse_duration(huge <> "ns")
      assert n == String.to_integer(huge)
    end
  end

  describe "a value of one kind never reads as another (CASC.md §6.8, §6.9, §6.4)" do
    # Durations, byte sizes and infinity are values of their own, so a
    # tuple or an atom a document writes can never come back as one of
    # them -- which it did while they were held as {:duration, ns},
    # {:bytes, n} and :infinity.
    test "a tuple whose first element is the atom duration is a tuple" do
      assert value("(duration, 5)") == {:duration, 5}
      assert value("(bytes, 5)") == {:bytes, 5}
    end

    test "the atom infinity is an atom, not inf" do
      assert value("infinity") == :infinity
      assert value("neg_infinity") == :neg_infinity
    end

    test "and inf is not an atom" do
      assert value("inf") == %Cooper.Infinity{sign: :positive}
      refute is_atom(value("inf"))
    end
  end
end
