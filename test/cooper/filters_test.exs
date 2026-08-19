defmodule Cooper.FiltersTest do
  use ExUnit.Case, async: true

  # `${NAME | filter}` (CASC.md §7.2), shared across `@{}`/`${}`/`%{}` the same
  # way `ref_suffix` is, plus the parameterless `!trim`/`!downcase`/`!upcase`
  # tags (§7.5) that cover the same ground for a whole value.
  #
  # Every case here is also a parity case: a bare reference is parsed by
  # `casc.aether`, while the same reference inside a double-quoted string is
  # hand-parsed by `Cooper.InterpActions`. Both paths landed a distinct bug
  # during development — the hand parser split on the filter's own `:`, and an
  # inline `arg:(DQ_STRING | SQ_STRING)` capture group skipped the token's
  # unescaping so the argument silently kept its quotes — so both spellings are
  # asserted for everything.
  #
  # These sigils use `~s(...)` rather than `~s|...|` for the obvious reason.

  defp load!(source, opts \\ []) do
    {:ok, tree, vars} = Cooper.Grammar.run_tree("#@version = 1.0\n" <> source)
    {:ok, result} = Cooper.Resolver.resolve(tree, Keyword.put_new(opts, :vars, vars))
    result
  end

  defp load(source, opts \\ []) do
    {:ok, tree, vars} = Cooper.Grammar.run_tree("#@version = 1.0\n" <> source)
    Cooper.Resolver.resolve(tree, Keyword.put_new(opts, :vars, vars))
  end

  describe "parameterless filters" do
    test "trim, downcase and upcase apply to an env reference" do
      env = %{"PADDED" => "  x  ", "MIXED" => "AbC"}

      source = ~s(a = ${PADDED | trim}\nb = ${MIXED | downcase}\nc = ${MIXED | upcase})

      assert load!(source, env: env) == %{"a" => "x", "b" => "abc", "c" => "ABC"}
    end

    test "an argument on a parameterless filter is an error" do
      assert {:error, error} = load(~s(a = ${X | trim: "y"}), env: %{"X" => "v"})
      assert error.message =~ "takes no argument"
    end
  end

  describe "parameterized filters" do
    test "trim_suffix strips the given suffix" do
      # The motivating case: a deployment supplies a scheme inconsistently, and
      # composing "${SCHEME}://host" would otherwise yield "https://://host".
      assert load!(~s(a = ${SCHEME | trim_suffix: "://"}), env: %{"SCHEME" => "https://"}) ==
               %{"a" => "https"}
    end

    test "trim_prefix strips the given prefix" do
      assert load!(~s(a = ${P | trim_prefix: "/api"}), env: %{"P" => "/api/v1"}) == %{
               "a" => "/v1"
             }
    end

    test "a suffix that is not present leaves the value alone" do
      assert load!(~s(a = ${SCHEME | trim_suffix: "://"}), env: %{"SCHEME" => "https"}) ==
               %{"a" => "https"}
    end

    test "a missing argument is an error" do
      assert {:error, error} = load(~s(a = ${X | trim_suffix}), env: %{"X" => "v"})
      assert error.message =~ "requires an argument"
    end

    test "single and double quoted arguments are equivalent" do
      env = %{"SCHEME" => "https://"}

      assert load!(~s(a = ${SCHEME | trim_suffix: '://'}), env: env) ==
               load!(~s(a = ${SCHEME | trim_suffix: "://"}), env: env)
    end
  end

  describe "chaining and ordering" do
    test "filters apply left to right" do
      assert load!(~s(a = ${S | trim_suffix: "://" | upcase}), env: %{"S" => "https://"}) ==
               %{"a" => "HTTPS"}
    end

    test "a filter applies after a default has been substituted" do
      # Filtering before the suffix settled would mean transforming a value you
      # might not even have.
      assert load!(~s(a = ${MISSING:"  padded  " | trim}), env: %{}) == %{"a" => "padded"}
    end

    test "a filter applies to the value when the reference is set" do
      assert load!(~s(a = ${S:"unused" | trim}), env: %{"S" => "  set  "}) == %{"a" => "set"}
    end
  end

  describe "shared across reference forms" do
    test "a variable reference filters" do
      assert load!(~s(@padded = "  v  "\na = @{padded | trim})) == %{"a" => "v"}
    end

    test "a config reference filters" do
      assert load!(~s(raw = "  v  "\na = %{raw | trim})) == %{"raw" => "  v  ", "a" => "v"}
    end
  end

  describe "parse-path parity" do
    test "a bare reference and the same reference in a string agree" do
      env = %{"SCHEME" => "https://"}

      bare = load!(~s(a = ${SCHEME | trim_suffix: '://'}), env: env)
      interpolated = load!(~s(a = "${SCHEME | trim_suffix: '://'}"), env: env)

      assert bare == interpolated
      assert bare == %{"a" => "https"}
    end

    test "chained filters agree across both paths" do
      env = %{"SCHEME" => "https://"}

      assert load!(~s(a = ${SCHEME | trim_suffix: '://' | upcase}), env: env) ==
               load!(~s(a = "${SCHEME | trim_suffix: '://' | upcase}"), env: env)
    end

    test "a pipe inside a quoted default is not a filter" do
      # The hand parser has to be quote-aware here; the aether path gets this
      # for free.
      assert load!(~s(a = ${MISSING:"a|b"}), env: %{}) == %{"a" => "a|b"}
    end
  end

  describe "errors" do
    test "an unknown filter names the known ones" do
      assert {:error, error} = load(~s(a = ${X | nope}), env: %{"X" => "v"})
      assert error.message =~ "unknown filter"
      assert error.message =~ "trim_suffix"
    end

    test "filtering a non-string value is an error rather than a coercion" do
      assert {:error, error} = load(~s(n = 42\na = %{n | trim}))
      assert error.message =~ "not a string"
    end
  end

  describe "normalizing tags" do
    test "the parameterless tags cover a whole value" do
      source = ~S"""
      a = !trim("  x  ")
      b = !downcase("AbC")
      c = !upcase("dEf")
      """

      assert load!(source) == %{"a" => "x", "b" => "abc", "c" => "DEF"}
    end

    test "a tag applied to a non-string is an error" do
      source = ~S"""
      a = !trim(42)
      """

      assert {:error, error} = load(source)
      assert error.message =~ "not a string"
    end
  end
end
