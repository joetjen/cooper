defmodule Cooper.MergeTest do
  use ExUnit.Case, async: true

  # CASC.md §8.4's own worked example produces exactly the documented
  # result, and deep-merge at 3+ levels behaves correctly regardless of
  # which surface form wrote which layer.

  defp run!(source) do
    {:ok, result} = Cooper.Grammar.run("#@version = 1.0\n" <> source)
    result
  end

  describe "§8.1 blocks/maps deep-merge by default" do
    test "two statements at different sub-paths merge, not overwrite" do
      assert run!("""
             a { b = 1 }
             a { c = 2 }
             """) == %{"a" => %{"b" => 1, "c" => 2}}
    end

    test "deep-merge at 3+ levels, regardless of which surface form wrote which layer" do
      assert run!("""
             a.b.c.d = 1
             a { b { c { e = 2 } } }
             a.b.f = 3
             """) == %{"a" => %{"b" => %{"c" => %{"d" => 1, "e" => 2}, "f" => 3}}}
    end
  end

  describe "§8.2 lists replace wholesale by default" do
    test "a later plain assignment replaces the whole list, not merges it" do
      assert run!("""
             tags = ["a", "b"]
             tags = ["c"]
             """) == %{"tags" => ["c"]}
    end
  end

  describe "§8.4's own worked example, end to end" do
    test "produces exactly the documented result" do
      source = """
      server { host = "0.0.0.0", port = 8080 }
      tags = ["a", "b", "c"]
      feature.legacy_mode = true

      ~server { port = 9090 }
      +tags = ["d"]
      -tags = ["b"]
      -feature.legacy_mode
      """

      assert run!(source) == %{
               "server" => %{"port" => 9090},
               "tags" => ["a", "c", "d"],
               "feature" => %{}
             }
    end
  end

  describe "§8.3 tuples never merge" do
    test "a plain later assignment still just replaces a tuple wholesale" do
      assert run!("""
             loc = (1, 2)
             loc = (3, 4)
             """) == %{"loc" => {3, 4}}
    end

    test "+ against a tuple is a load-time error, not a silent no-op" do
      source = """
      loc = (1, 2)
      +loc = [3]
      """

      assert {:error, %Ichor.Error{stage: :merge}} =
               Cooper.Grammar.run("#@version = 1.0\n" <> source)
    end

    test "- against a tuple is a load-time error" do
      source = """
      loc = (1, 2)
      -loc = [1]
      """

      assert {:error, %Ichor.Error{stage: :merge}} =
               Cooper.Grammar.run("#@version = 1.0\n" <> source)
    end

    test "~ against a path currently holding a tuple is a load-time error" do
      source = """
      loc = (1, 2)
      ~loc { x = 1 }
      """

      assert {:error, %Ichor.Error{stage: :merge}} =
               Cooper.Grammar.run("#@version = 1.0\n" <> source)
    end
  end

  describe "bare delete (-key.path)" do
    test "removes the path entirely, regardless of value type" do
      assert run!("""
             a.b = 1
             a.c = 2
             -a.b
             """) == %{"a" => %{"c" => 2}}
    end
  end

  describe "secret propagation (inferred: a later op's secret? wins at the same path)" do
    test "a later plain write over a secret path is no longer wrapped" do
      {:ok, entries} =
        Cooper.Grammar.run_ops("#@version = 1.0\n*password = \"x\"\npassword = \"y\"")

      assert {:ok, %{"password" => "y"}} = Cooper.Merge.assemble(entries)
    end

    test "a later secret write over a plain path is wrapped" do
      {:ok, entries} =
        Cooper.Grammar.run_ops("#@version = 1.0\npassword = \"x\"\n*password = \"y\"")

      assert {:ok, %{"password" => %Cooper.Secret{value: "y"}}} = Cooper.Merge.assemble(entries)
    end
  end

  describe "for-loop `from` interaction (Cooper.Loop's lazy Cooper.Ref.Config base)" do
    test "wraps the lazy base with Cooper.Merge.Layered, overrides layered on top" do
      source = """
      defaults.replica { cpu = 1, memory_mb = 512 }

      @instances = ["a", "b"]
      for @instance in @{instances} from defaults.replica as replicas."@{instance}" {
        cpu = 2
      }
      """

      assert {:ok, entries} = Cooper.Grammar.run_ops("#@version = 1.0\n" <> source)
      assert {:ok, tree} = Cooper.Merge.assemble(entries)

      assert %Cooper.Merge.Layered{
               base: %Cooper.Ref.Config{path: ["defaults", "replica"]},
               overrides: %{"cpu" => 2}
             } = tree["replicas"]["a"]

      assert %Cooper.Merge.Layered{
               base: %Cooper.Ref.Config{path: ["defaults", "replica"]},
               overrides: %{"cpu" => 2}
             } = tree["replicas"]["b"]
    end
  end
end
