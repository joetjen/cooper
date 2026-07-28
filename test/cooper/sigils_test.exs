defmodule Cooper.SigilsTest do
  use ExUnit.Case, async: true

  # These test the grammar/flattening in isolation, at the raw-op
  # level (`Cooper.Grammar.run_ops/1`) -- *interpreting* these sigils
  # (deep-merge, whole-subtree replace, list append/remove, tuple guard)
  # is `Cooper.Merge`'s job; see test/cooper/merge_test.exs for CASC.md
  # §8.4's own worked example, exercised end to end.

  defp ops(source), do: Cooper.Grammar.run_ops("#@version = 1.0\n" <> source)

  describe "merge control sigils (CASC.md §5.7)" do
    test "no sigil produces the :merge sigil" do
      assert {:ok, [{:op, %Cooper.Op{path: ["port"], sigil: :merge, value: 9090}}]} =
               ops("port = 9090")
    end

    test "~ produces :replace on every leaf op a block flattens to, plus a leading clear-scope marker" do
      assert {:ok, ops_list} = ops("~server { host = \"0.0.0.0\", port = 9090 }")

      assert [
               {:clear, ["server"]},
               {:op, %Cooper.Op{path: ["server", "host"], sigil: :replace, value: "0.0.0.0"}},
               {:op, %Cooper.Op{path: ["server", "port"], sigil: :replace, value: 9090}}
             ] = ops_list
    end

    test "+ produces :append" do
      assert {:ok, [{:op, %Cooper.Op{path: ["tags"], sigil: :append, value: ["d"]}}]} =
               ops(~S(+tags = ["d"]))
    end

    test "- with a value produces :remove" do
      assert {:ok, [{:op, %Cooper.Op{path: ["tags"], sigil: :remove, value: ["b"]}}]} =
               ops(~S(-tags = ["b"]))
    end

    test "- with no value (bare) produces :delete" do
      assert {:ok,
              [{:op, %Cooper.Op{path: ["feature", "legacy_mode"], sigil: :delete, value: nil}}]} =
               ops("-feature.legacy_mode")
    end
  end

  describe "secret?/public? marker detection (regression: name:X? on a quantified capture" <>
             " silently degrades to a generic non-empty span, making a naive presence check" <>
             " always true -- see Cooper.RefCommon.marker_present?/2)" do
    test "a plain key is not secret" do
      assert {:ok, [{:op, %Cooper.Op{path: ["foo"], secret?: false}}]} = ops("foo = 1")
    end

    test "a *-prefixed key is secret" do
      assert {:ok, [{:op, %Cooper.Op{path: ["bar"], secret?: true}}]} = ops("*bar = 2")
    end

    test "a plain public var decl" do
      assert {:ok, [{:var, %Cooper.VarDecl{name: "x", public?: true}}]} = ops("@x = 1")
    end

    test "a @*-prefixed var decl is private" do
      assert {:ok, [{:var, %Cooper.VarDecl{name: "x", public?: false}}]} = ops("@*x = 1")
    end
  end

  describe "the full §8.4 worked example flattens to the expected ops" do
    test "produces one op per sigil'd statement" do
      source = """
      ~server { port = 9090 }
      +tags = ["d"]
      -tags = ["b"]
      -feature.legacy_mode
      """

      assert {:ok, ops_list} = ops(source)

      assert [
               {:clear, ["server"]},
               {:op, %Cooper.Op{path: ["server", "port"], sigil: :replace, value: 9090}},
               {:op, %Cooper.Op{path: ["tags"], sigil: :append, value: ["d"]}},
               {:op, %Cooper.Op{path: ["tags"], sigil: :remove, value: ["b"]}},
               {:op, %Cooper.Op{path: ["feature", "legacy_mode"], sigil: :delete, value: nil}}
             ] = ops_list
    end
  end
end
