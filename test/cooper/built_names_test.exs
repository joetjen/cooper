defmodule Cooper.BuiltNamesTest do
  use ExUnit.Case, async: true

  # CASC.md §7.2: a reference's *name* may be built by interpolation
  # rather than written out -- `${"TOKEN_@{id}"}`. The motivating case
  # is a deployment convention of one environment variable per tenant,
  # which a document otherwise cannot follow at all: CASC reads named
  # variables and has no way to enumerate the environment.

  @env %{
    "TOKEN_1" => "tok-one",
    "TOKEN_2" => "tok-two",
    "APP_HOST" => "example.test",
    "APP_s3cret" => "should-never-be-read"
  }

  defp load(source) do
    Cooper.load_string("#@version = 1.0\n" <> source, env: @env, dotenv: false)
  end

  defp error_message(source) do
    assert {:error, error} = load(source)
    if is_list(error), do: hd(error).message, else: error.message
  end

  describe "a built ${...} name" do
    test "reads the environment variable the name resolves to" do
      assert {:ok, %{"host" => "example.test"}} =
               load(~s(@which = "HOST"\nhost = ${"APP_@{which}"}))
    end

    test "still honours a default when the built name is unset" do
      assert {:ok, %{"host" => "fallback"}} =
               load(~s(@which = "MISSING"\nhost = ${"APP_@{which}":"fallback"}))
    end
  end

  describe "a built @{...} name" do
    test "reads the variable the name resolves to" do
      assert {:ok, %{"value" => "indirect"}} =
               load(~s(@target = "indirect"\n@which = "target"\nvalue = @{"@{which}"}))
    end
  end

  describe "a built name inside a for loop (the motivating case)" do
    test "reads one differently-named variable per iteration" do
      source = """
      @ids = ["1", "2"]

      for @id in @{ids} as tokens {
        "@{id}" = ${"TOKEN_@{id}"}
      }
      """

      assert {:ok, %{"tokens" => tokens}} = load(source)
      assert tokens == %{"1" => "tok-one", "2" => "tok-two"}
    end

    test "a loop binding substitutes into a body key (regression)" do
      # Body keys were copied verbatim while only values were
      # substituted, so an interpolated key stayed an unresolved
      # `Cooper.Interp.Text` *used as a map key* -- which made every
      # iteration collapse onto that one struct key, silently keeping
      # only the last.
      source = """
      @ids = ["a", "b"]

      for @id in @{ids} as out {
        "@{id}" = "value-@{id}"
      }
      """

      assert {:ok, %{"out" => out}} = load(source)
      assert out == %{"a" => "value-a", "b" => "value-b"}
    end
  end

  describe "guardrails on what a built name may be" do
    test "rejects a name that is not identifier-shaped" do
      message = error_message(~s(@bad = "not an identifier"\nx = ${"APP_@{bad}"}))
      assert message =~ "not a valid name"
    end

    test "rejects a name built from a secret, which would appear unredacted" do
      message = error_message(~s(*token = "s3cret"\nx = ${"APP_%{token}"}))
      assert message =~ "may not be built from a secret value"
    end

    test "rejects a name that resolves to a non-string" do
      message = error_message("@n = 42\nx = ${\"APP_@{n}\"}")
      refute match?({:ok, _}, load("@n = 42\nx = ${\"APP_@{n}\"}"))
      assert is_binary(message)
    end
  end

  describe "a built %{...} path segment" do
    test "resolves, rather than crashing on an unresolved struct key" do
      # The parser has always produced an interpolated segment for this
      # form; nothing resolved it, so the struct reached `Enum.join/2`
      # and raised `Protocol.UndefinedError`.
      source =
        ~s(@id = "1"\ntokens {\n  "supervisor-1" = "one"\n}\n\nprobe = %{tokens."supervisor-@{id}"})

      assert {:ok, %{"probe" => "one"}} = load(source)
    end

    test "allows a key that is not identifier-shaped, unlike a name" do
      source = ~s(@k = "with-hyphen"\nm {\n  "with-hyphen" = 1\n}\n\nprobe = %{m."@{k}"})

      assert {:ok, %{"probe" => 1}} = load(source)
    end

    test "rejects a key that would split into more than one segment" do
      source = ~s(@k = "a.b"\nm {\n  "x" = 1\n}\n\nprobe = %{m."@{k}"})
      assert error_message(source) =~ "more than one path segment"
    end
  end

  describe "the bare form only" do
    test "a built name nested inside a larger string is not supported" do
      # `casc_interp.aether`'s own reference token ends at the first
      # `}`, so a nested `@{...}` inside the name would truncate it --
      # and the nested double quotes cannot be written inside a
      # double-quoted string in the first place. Documented as a scope
      # trim, asserted here so it stays a clean parse error rather than
      # silently parsing as something else.
      assert {:error, _} = load(~s(@w = "HOST"\nx = "url=${"APP_@{w}"}"))
    end
  end
end
