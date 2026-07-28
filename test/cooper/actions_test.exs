defmodule Cooper.ActionsTest do
  use ExUnit.Case, async: true

  defp value(literal) do
    {:ok, %{"v" => value}} = Cooper.Grammar.run("#@version = 1.0\nv = #{literal}")
    value
  end

  describe "nil and booleans (CASC.md §6.1-6.2)" do
    test "nil" do
      assert value("nil") == nil
    end

    test "booleans" do
      assert value("true") == true
      assert value("false") == false
    end
  end

  describe "numbers (CASC.md §6.3)" do
    test "integers" do
      assert value("-17") == -17
      assert value("0") == 0
      assert value("+99") == 99
    end

    test "hex, octal, binary" do
      assert value("0xDEAD_BEEF") == 0xDEADBEEF
      assert value("0o755") == 0o755
      assert value("0b11010110") == 0b11010110
    end

    test "floats" do
      assert value("3.1415") == 3.1415
      assert value("-0.01") == -0.01
    end

    test "exponents" do
      assert value("5e+22") == 5.0e22
      assert value("-2E-2") == -2.0e-2
    end

    test "digit separators" do
      assert value("1_000_000") == 1_000_000
    end

    test "infinity" do
      assert value("inf") == :infinity
      assert value("+inf") == :infinity
      assert value("-inf") == :neg_infinity
    end
  end

  describe "atoms (CASC.md §6.4)" do
    test "reserved words take precedence over the atom rule" do
      assert value("nil") == nil
      assert value("true") == true
      assert value("false") == false
    end

    test "a bare identifier is an atom" do
      assert value("info") == :info
    end

    test "an optional leading colon" do
      assert value(":info") == :info
    end

    test "a colon is required to reach a reserved-word-named atom" do
      assert value(":true") == true
      assert value(":false") == false
      assert value(":nil") == nil
      assert value(":inf") == :inf
    end
  end

  describe "strings (CASC.md §6.5)" do
    test "double-quoted strings process escapes" do
      assert value(~S("line1\nline2")) == "line1\nline2"
      assert value(~S("a \"quote\"")) == ~S(a "quote")
      assert value(~S("tab\there")) == "tab\there"
    end

    test "double-quoted strings with no references stay plain strings" do
      assert value(~S("hello world")) == "hello world"
    end

    test "double-quoted strings containing a reference become an unresolved Cooper.Interp.Text" do
      assert value(~S("hello @{name}")) ==
               %Cooper.Interp.Text{
                 segments: ["hello ", %Cooper.Ref.Var{name: "name", index: nil, suffix: nil}]
               }
    end

    test "single-quoted strings are fully literal" do
      assert value(~S('no \n escapes here')) == "no \\n escapes here"
    end
  end
end
