defmodule Cooper.ModuleTagTest do
  use ExUnit.Case, async: true

  # `!module` (CASC.md §7.5). The tag name is deliberately the same in every
  # Cooper implementation while the shape it accepts is that implementation's
  # own, so a document naming a module stays readable across ports even though
  # what counts as a module name differs by language.

  defp load!(source) do
    {:ok, tree, vars} = Cooper.Grammar.run_tree("#@version = 1.0\n" <> source)
    {:ok, result} = Cooper.Resolver.resolve(tree, vars: vars)
    result
  end

  defp load(source) do
    {:ok, tree, vars} = Cooper.Grammar.run_tree("#@version = 1.0\n" <> source)
    Cooper.Resolver.resolve(tree, vars: vars)
  end

  describe "building a module" do
    test "an upper-case name becomes an Elixir module" do
      assert load!(~s<a = !module("Logger.Backends.Logfmt")>) == %{"a" => Logger.Backends.Logfmt}
    end

    test "a single upper-case segment works" do
      assert load!(~s<a = !module("String")>) == %{"a" => String}
    end

    test "a lower-case name becomes an Erlang module" do
      # `:crypto`, not `Elixir.crypto`.
      assert load!(~s<a = !module("crypto")>) == %{"a" => :crypto}
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
      assert error.message =~ "not a dot-separated module name"
    end

    test "an empty name" do
      assert {:error, error} = load(~s<a = !module("")>)
      assert error.message =~ "not a dot-separated module name"
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
