defmodule Cooper.GrammarTest do
  use ExUnit.Case, async: true

  test "the minimal valid file parses to an empty map (CASC.md §10)" do
    assert {:ok, %{}} = Cooper.Grammar.run("#@version = 1.0")
  end

  describe "version header" do
    test "accepts the operator-optional form" do
      assert {:ok, %{}} = Cooper.Grammar.run("#@version 1.0")
    end

    test "accepts bare, dotted, and triple-dotted versions" do
      assert {:ok, %{}} = Cooper.Grammar.run("#@version = 1")
      assert {:ok, %{}} = Cooper.Grammar.run("#@version = 1.0")
      assert {:ok, %{}} = Cooper.Grammar.run("#@version = 2.1.3")
    end

    test "rejects a mismatched header keyword" do
      assert {:error, _} = Cooper.Grammar.run("#@versio = 1.0")
    end
  end

  describe "comments (CASC.md §3.2)" do
    test "a comment with a following space is a plain comment" do
      source = """
      #@version = 1.0
      # a comment
      foo = 1
      """

      assert {:ok, %{"foo" => 1}} = Cooper.Grammar.run(source)
    end

    test "a comment with no following space, where the text isn't a valid statement, is a parse error" do
      source = """
      #@version = 1.0
      #TODO fix this
      """

      assert {:error, _} = Cooper.Grammar.run(source)
    end
  end

  describe "disabled statements (CASC.md §5.6)" do
    test "a disabled assignment produces nothing" do
      source = """
      #@version = 1.0
      section {
        #ignored = 1
        kept = true
      }
      """

      assert {:ok, %{"section" => %{"kept" => true}}} = Cooper.Grammar.run(source)
    end

    test "a disabled block statement produces nothing" do
      source = """
      #@version = 1.0
      section {
        #*sub { remove = yes }
        kept = true
      }
      """

      assert {:ok, %{"section" => %{"kept" => true}}} = Cooper.Grammar.run(source)
    end
  end

  describe "key paths and blocks (CASC.md §5.4)" do
    test "dotted paths, nested blocks, and explicit = { } all desugar identically" do
      for source <- [
            ~S(#@version = 1.0
               foo { bar { baz = "dronf" } }),
            ~S(#@version = 1.0
               foo { bar.baz "dronf" }),
            ~S(#@version = 1.0
               foo = { bar = { baz = "dronf" } }),
            ~S(#@version = 1.0
               foo.bar.baz "dronf")
          ] do
        assert {:ok, %{"foo" => %{"bar" => %{"baz" => "dronf"}}}} = Cooper.Grammar.run(source)
      end
    end

    test "two statements with different surface forms merge into one map" do
      source = """
      #@version = 1.0
      foo.bar.baz = 1
      foo = { bar = { qux = 2 } }
      """

      assert {:ok, %{"foo" => %{"bar" => %{"baz" => 1, "qux" => 2}}}} = Cooper.Grammar.run(source)
    end

    test "quoted key segments (CASC.md §4.2)" do
      source = ~S(#@version = 1.0
        headers = { "Content-Type" = "application/json" }
        foo."bar baz".dronf = "fnord")

      assert {:ok,
              %{
                "headers" => %{"Content-Type" => "application/json"},
                "foo" => %{"bar baz" => %{"dronf" => "fnord"}}
              }} = Cooper.Grammar.run(source)
    end
  end

  describe "secret keys (CASC.md §4.3)" do
    test "a leading secret prefix on a single-segment key" do
      source = ~S(#@version = 1.0
        *password = "hunter2")

      assert {:ok, %{"password" => %Cooper.Secret{value: "hunter2"}}} = Cooper.Grammar.run(source)
    end

    test "a secret prefix on a non-leading path segment" do
      source = ~S(#@version = 1.0
        db.*password = "hunter2")

      assert {:ok, %{"db" => %{"password" => %Cooper.Secret{value: "hunter2"}}}} =
               Cooper.Grammar.run(source)
    end

    test "a secret prefix on the whole path" do
      source = ~S(#@version = 1.0
        *db.password = "hunter2")

      assert {:ok, %{"db" => %{"password" => %Cooper.Secret{value: "hunter2"}}}} =
               Cooper.Grammar.run(source)
    end
  end
end
