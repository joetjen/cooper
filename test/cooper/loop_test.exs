defmodule Cooper.LoopTest do
  use ExUnit.Case, async: true

  # CASC.md §5.5's own worked examples, run end to end through
  # Cooper.Grammar.run/1 -- unlike the merge-control sigils (whose
  # *interpretation* is `Cooper.Merge`'s job), loop expansion happens
  # entirely within `Cooper.Loop`, so most assertions here check a real,
  # fully-assembled result, not just an op list -- except for `from`,
  # where the generated base is a lazy %Cooper.Ref.Config{} that only
  # `Cooper.Resolver` can interpret; those assertions run at the op
  # level instead.

  defp ops(source), do: Cooper.Grammar.run_ops(source)

  describe "parallel (zipped) iteration, CASC.md §5.5's own example" do
    test "produces the documented endpoints map" do
      source = """
      #@version = 1.0
      @domains = ["us-east.example.com", "eu-west.example.com"]
      @ports = [8443, 8444]

      for @idx, @domain in @{domains}, @port in @{ports} as endpoints."domain-@{idx}" {
        url = "https://@{domain}:@{port}"
      }
      """

      assert {:ok,
              %{
                "endpoints" => %{
                  "domain-0" => %{"url" => "https://us-east.example.com:8443"},
                  "domain-1" => %{"url" => "https://eu-west.example.com:8444"}
                }
              }} = Cooper.Grammar.run(source)
    end

    test "a mismatched-length pair of bound lists is a load-time error naming both" do
      source = """
      #@version = 1.0
      @domains = ["us-east.example.com", "eu-west.example.com"]
      @ports = [8443]

      for @domain in @{domains}, @port in @{ports} as endpoints."@{domain}" {
        url = "@{port}"
      }
      """

      assert {:error, %Ichor.Error{message: message, stage: :loop}} = Cooper.Grammar.run(source)
      assert message =~ "domain"
      assert message =~ "2"
      assert message =~ "port"
      assert message =~ "1"
    end

    test "an index-only loop (no element binding) is a load-time error" do
      source = """
      #@version = 1.0
      for @idx as dest."@{idx}" {
        k = 1
      }
      """

      assert {:error, %Ichor.Error{stage: :loop}} = Cooper.Grammar.run(source)
    end

    test "an index binding placed after an element binding doesn't get mistaken for the trailing `as`" do
      source = """
      #@version = 1.0
      @names = ["a", "b"]

      for @name in @{names}, @idx as dest."@{name}" {
        position = "@{idx}"
      }
      """

      assert {:ok,
              %{
                "dest" => %{
                  "a" => %{"position" => "0"},
                  "b" => %{"position" => "1"}
                }
              }} = Cooper.Grammar.run(source)
    end
  end

  describe "`from <template>`, CASC.md §5.5's own example" do
    test "each iteration gets a lazy Cooper.Ref.Config base, overridden by the loop body" do
      source = """
      #@version = 1.0
      defaults.replica {
        cpu = 1
        memory_mb = 512
      }

      @instances = ["a", "b", "c"]
      for @instance in @{instances} from defaults.replica as replicas."@{instance}" {
        cpu = 2
      }
      """

      assert {:ok, entries} = ops(source)

      base_ops =
        for {:op, %Cooper.Op{path: ["replicas", name], value: %Cooper.Ref.Config{} = ref}} <-
              entries,
            do: {name, ref}

      override_ops =
        for {:op, %Cooper.Op{path: ["replicas", name, "cpu"], value: value}} <- entries,
            do: {name, value}

      assert base_ops == [
               {"a", %Cooper.Ref.Config{path: ["defaults", "replica"], index: nil, suffix: nil}},
               {"b", %Cooper.Ref.Config{path: ["defaults", "replica"], index: nil, suffix: nil}},
               {"c", %Cooper.Ref.Config{path: ["defaults", "replica"], index: nil, suffix: nil}}
             ]

      assert override_ops == [{"a", 2}, {"b", 2}, {"c", 2}]
    end
  end

  describe "loop iterable validation" do
    test "a literal list works directly, with no outer variable needed" do
      source = """
      #@version = 1.0
      for @x in ["p", "q"] as dest."@{x}" {
        k = 1
      }
      """

      assert {:ok, %{"dest" => %{"p" => %{"k" => 1}, "q" => %{"k" => 1}}}} =
               Cooper.Grammar.run(source)
    end

    test "an undefined variable as iterable is a load-time error" do
      source = """
      #@version = 1.0
      for @x in @{missing} as dest."@{x}" {
        k = 1
      }
      """

      assert {:error, %Ichor.Error{stage: :loop, message: message}} = Cooper.Grammar.run(source)
      assert message =~ "missing"
    end

    test "a %{...} config reference as iterable is refused (can't resolve before merge)" do
      source = """
      #@version = 1.0
      for @x in %{some.path} as dest."@{x}" {
        k = 1
      }
      """

      assert {:error, %Ichor.Error{stage: :loop}} = Cooper.Grammar.run(source)
    end
  end
end
