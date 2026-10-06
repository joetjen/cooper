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

  describe "statements CASC.md specifies that once failed to parse" do
    test "an assignment without `=` to a string value is not an import (§5.3)" do
      # `import_statement` matches any identifier followed by a string, so
      # this once failed with `expected "import", got "foo"`.
      assert Cooper.load_string(~s(#@version = 1.0\n@n = 1\nfoo "bar"\ninterp "x-@{n}"),
               dotenv: false
             ) == {:ok, %{"foo" => "bar", "interp" => "x-1"}}
    end

    test "a real import is still an import" do
      source = ~s(#@version = 1.0\nimport "mem://x"\n)
      schemes = %{"mem" => fn _ -> {:ok, "#@version = 1.0\nfrom_import = 1\n"} end}

      assert {:ok, %{"from_import" => 1}} = Cooper.Grammar.run(source, import_schemes: schemes)
    end

    test "a bare delete followed by another statement (§5.7)" do
      # Without the `followed_delete` alternative the next line's key was
      # read as the remove value: `-a.b = c`, then a stray `= 1`.
      source = """
      #@version = 1.0
      a.b = 1
      a.x = 2
      -a.b
      c = 1
      -a.x
      d { e = 1 }
      """

      assert {:ok, %{"a" => %{}, "c" => 1, "d" => %{"e" => 1}}} = Cooper.Grammar.run(source)
    end

    test "a remove still takes its value, with or without `=`" do
      source = """
      #@version = 1.0
      tags = ["a", "b", "c"]
      -tags = ["a"]
      -tags ["b"]
      """

      assert {:ok, %{"tags" => ["c"]}} = Cooper.Grammar.run(source)
    end

    test "+info and -info reach a key starting with `inf` (§5.7)" do
      # `+inf` once out-munched `+`, leaving `o` behind.
      source = """
      #@version = 1.0
      info = [1]
      +info = [2]
      infra = 1
      -infra
      neg = -inf
      """

      assert {:ok, %{"info" => [1, 2], "neg" => :neg_infinity}} = Cooper.Grammar.run(source)
    end
  end

  describe "disabled statements are never evaluated (§5.6)" do
    test "a disabled variable declaration defines nothing" do
      assert Cooper.load_string(~s(#@version = 1.0\n#@x = 1\nv = @{x:"fallback"}), dotenv: false) ==
               {:ok, %{"v" => "fallback"}}
    end

    test "a disabled import is not loaded" do
      assert {:ok, %{"v" => 1}} =
               Cooper.Grammar.run(~s(#@version = 1.0\n#import "nonexistent.casc"\nv = 1))
    end

    test "a bad literal inside a disabled statement does not fail the load" do
      assert {:ok, %{"v" => 1}} =
               Cooper.Grammar.run("#@version = 1.0\n#bad = 999.999.999.999\nv = 1")
    end
  end

  describe "where the copies showed this implementation contradicting CASC.md" do
    test "a comment before the version header is trivia, as it is everywhere else (§3.2)" do
      assert {:ok, %{"key" => 1}} =
               Cooper.Grammar.run("# leading comment\n\n#@version = 1.0\nkey = 1\n")
    end

    test "a duration takes `_` between digits, as every other number does (§6.3, §6.8)" do
      assert {:ok, %{"t" => {:duration, 1_000_000_000}}} =
               Cooper.Grammar.run("#@version = 1.0\nt = 1_000ms\n")
    end
  end
end
