defmodule Cooper.ModuleTagTest do
  use ExUnit.Case, async: true

  # `!module` (CASC.md §7.5). A module name is written the same way for every
  # Cooper implementation -- dot-separated PascalCase -- and each translates
  # it into its own language's module, or takes it from the application's
  # `:modules` mapping first.

  defp load!(source) do
    {:ok, tree, vars} = Cooper.Grammar.run_tree("#@version = 1.0\n" <> source)
    {:ok, result} = Cooper.Resolver.resolve(tree, vars: vars)
    result
  end

  defp load(source, opts \\ []) do
    {:ok, tree, vars} = Cooper.Grammar.run_tree("#@version = 1.0\n" <> source)
    Cooper.Resolver.resolve(tree, [vars: vars] ++ opts)
  end

  describe "building a module" do
    test "an upper-case name becomes an Elixir module" do
      assert load!(~s<a = !module("Logger.Backends.Logfmt")>) == %{"a" => Logger.Backends.Logfmt}
    end

    test "a single upper-case segment works" do
      assert load!(~s<a = !module("String")>) == %{"a" => String}
    end

    test "a name in the application's mapping is what the mapping says" do
      assert {:ok, %{"a" => :crypto}} =
               load(~s<a = !module("Crypto")>, modules: %{"Crypto" => :crypto})
    end

    test "the mapping is asked by the name exactly as written" do
      assert {:ok, %{"a" => Crypto}} =
               load(~s<a = !module("Crypto")>, modules: %{"CRYPTO" => :crypto})
    end

    test "surrounding whitespace is ignored" do
      assert load!(~s<a = !module("  String  ")>) == %{"a" => String}
    end

    test "the result is an ordinary atom usable as a module" do
      %{"a" => module} = load!(~s<a = !module("String")>)

      assert is_atom(module)
      assert module.trim("  x  ") == "x"
    end
  end

  describe "composing with the rest of the language" do
    test "a module name may come from an environment variable" do
      # The motivating case: a document cannot write a dotted atom literally,
      # and the name is often deployment-selected.
      {:ok, tree, vars} = Cooper.Grammar.run_tree(~s<#@version = 1.0\na = !module("${CLIENT}")>)

      assert {:ok, %{"a" => String}} =
               Cooper.Resolver.resolve(tree, vars: vars, env: %{"CLIENT" => "String"})
    end

    test "a module sits inside a list like any other value" do
      assert load!(~s<a = [!module("String"), !module("Enum")]>) == %{"a" => [String, Enum]}
    end
  end

  describe "rejecting what is not a module name" do
    test "a name with invalid characters" do
      assert {:error, error} = load(~s<a = !module("Foo Bar")>)
      assert error.message =~ "not a dot-separated PascalCase module name"
    end

    test "an empty name" do
      assert {:error, error} = load(~s<a = !module("")>)
      assert error.message =~ "not a dot-separated PascalCase module name"
    end

    test "a segment that is not PascalCase, even one the mapping holds" do
      for name <- ["crypto", "Foo.bar", "Foo_Bar", "foo-bar", "./x.js"] do
        assert {:error, error} = load(~s<a = !module("#{name}")>, modules: %{name => :x})
        assert error.message =~ "PascalCase", name
      end
    end

    test "a name that is not a string" do
      assert {:error, error} = load(~s<a = !module(42)>)
      assert error.message =~ "not a string"
    end

    test "an unreasonably long name" do
      long = String.duplicate("A", 513)

      assert {:error, error} = load(~s<a = !module("#{long}")>)
      assert error.message =~ "longer than 512 bytes"
    end
  end
end
