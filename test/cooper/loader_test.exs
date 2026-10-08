defmodule Cooper.LoaderTest do
  use ExUnit.Case, async: true

  # CASC.md §5.1's own worked forms, against real fixture files under
  # test/fixtures/imports/: a two-file import example produces the
  # documented merged result, including a variable crossing the import
  # boundary.

  @fixtures Path.join([__DIR__, "..", "fixtures", "imports"])

  defp fixture(name), do: Path.join(@fixtures, name)

  describe "a bare (no scheme://) import" do
    test "resolves relative to the importing file, and later statements override the import" do
      assert {:ok, result} = Cooper.Grammar.run_file(fixture("main.casc"))

      assert %{
               "server" => %{"host" => "0.0.0.0", "port" => 9090},
               "app" => %{"name" => _}
             } = result
    end

    test "a public variable from the imported file is visible in the importer" do
      ctx = Cooper.Grammar.initial_context(root: @fixtures, file: fixture("main.casc"))

      assert {:ok, _entries, result_ctx} =
               Cooper.Grammar.run_with_context(
                 File.read!(fixture("main.casc")),
                 Cooper.Actions,
                 ctx
               )

      assert {"shared", true} = result_ctx.vars["shared_name"]
    end

    test "a private (@*name) variable never crosses the import boundary" do
      ctx = Cooper.Grammar.initial_context(root: @fixtures, file: fixture("main.casc"))

      assert {:ok, _entries, result_ctx} =
               Cooper.Grammar.run_with_context(
                 File.read!(fixture("main.casc")),
                 Cooper.Actions,
                 ctx
               )

      refute Map.has_key?(result_ctx.vars, "local_only")
    end
  end

  # The two tests above assert on the *declaration* environment. That
  # is not, on its own, enough to pin the visibility rules down: `@{}`
  # references are resolved later, against the flattened whole, so a
  # name can be absent from `result_ctx.vars` and still resolve (and
  # vice versa). These resolve real values instead -- the regression
  # that motivated `Cooper.Scope` passed both tests above while getting
  # every case below wrong.
  describe "variable visibility, resolved (CASC.md §5.2)" do
    @visibility Path.join([__DIR__, "..", "fixtures", "visibility"])

    setup do
      assert {:ok, result} =
               Cooper.load_file(Path.join(@visibility, "main.casc"),
                 cache: false,
                 dotenv: false,
                 env: %{}
               )

      %{result: result}
    end

    test "a private variable is usable inside its own file", %{result: result} do
      assert result["entry"]["own_private"] == "entry-private"
    end

    test "an imported file can use its own private variable", %{result: result} do
      assert result["shared"]["own_private"] == "shared-private"
    end

    test "the importer's private variable is not visible to an imported file", %{result: result} do
      assert result["shared"]["from_importer_private"] == "MISSING"
    end

    test "an imported file's private variable is not visible to the importer", %{result: result} do
      assert result["entry"]["imported_private"] == "MISSING"
    end

    test "a public variable travels up, from the imported file to the importer", %{result: result} do
      assert result["entry"]["imported_public"] == "shared-public"
    end

    test "a public variable travels down, from the importer to the imported file", %{
      result: result
    } do
      assert result["shared"]["from_importer_public"] == "entry-public"
    end

    test "two files' identically named private variables stay independent", %{result: result} do
      assert result["shared"]["own_private"] == "shared-private"
      assert result["other"]["own_private"] == "other-private"
    end
  end

  describe "brace and glob expansion (CASC.md §5.1)" do
    test "expands {a,b} and ** against the filesystem, loading matches in lexicographic order" do
      assert {:ok, result} = Cooper.Grammar.run_file(fixture("glob_main.casc"))

      # config/dev/z.casc sorts after config/base/a.casc, so its `val`
      # (later import) wins over base's, and its own extra key survives.
      assert result == %{"val" => "dev-z", "order_marker" => "last"}
    end
  end

  describe "env passed through to an imported file (regression: sub_ctx dropped :env)" do
    @env_guard_fixtures Path.join([__DIR__, "..", "fixtures", "import_env_guard"])

    test "a ${?FLAG} guard inside the imported file sees the importer's own :env, unset" do
      assert {:ok, result} =
               Cooper.Grammar.run_file(Path.join(@env_guard_fixtures, "main.casc"), env: %{})

      assert result == %{"name" => "base"}
    end

    test "a ${?FLAG} guard inside the imported file sees the importer's own :env, set" do
      assert {:ok, result} =
               Cooper.Grammar.run_file(Path.join(@env_guard_fixtures, "main.casc"),
                 env: %{"FLAG" => "1"}
               )

      assert result == %{"name" => "base", "enabled" => true}
    end
  end

  describe "import cycle detection" do
    test "a cycle back to the entry file is caught on the first repeat, naming the chain" do
      assert {:error, %Ichor.Error{stage: :import, message: message}} =
               Cooper.Grammar.run_file(fixture("cycle_a.casc"))

      assert message =~ "cycle_a.casc"
      assert message =~ "cycle_b.casc"
      # Not "cycle_a -> cycle_b -> cycle_b" -- the entry file itself must
      # be tracked from the start, or the cycle is only caught one hop
      # too late (regression: run_file/2 seeds `:file` for exactly this).
      refute message =~ ~r/cycle_b\.casc -> cycle_b\.casc/
    end
  end

  describe "failure cases" do
    test "an unregistered scheme is a load-time error naming it" do
      source = "#@version = 1.0\nimport \"myscheme://foo\"\n"
      assert {:error, %Ichor.Error{stage: :import, message: message}} = Cooper.Grammar.run(source)
      assert message =~ "myscheme"
    end

    test "a pattern matching no files is a load-time error" do
      source = "#@version = 1.0\nimport \"does/not/exist/*.casc\"\n"
      assert {:error, %Ichor.Error{stage: :import}} = Cooper.Grammar.run(source, root: @fixtures)
    end

    test "an import path that isn't a plain string is a load-time error" do
      source = ~S(#@version = 1.0
      import "@{some_var}")

      assert {:error, %Ichor.Error{stage: :import}} = Cooper.Grammar.run(source, root: @fixtures)
    end
  end

  describe "private variables (§5.2)" do
    test "one private variable reads another" do
      assert {:ok, %{"x" => "v1"}} =
               Cooper.load_string("#@version = 1.0\n@*a = 1\n@*b = \"v@{a}\"\nx = @{b}\n")
    end

    test "a private variable shadows an imported public one of the same name, in this file only" do
      source =
        "#@version = 1.0\nimport \"shadow_child.casc\"\n@*name = \"private\"\nx = @{name}\n"

      assert {:ok, %{"child" => "public", "x" => "private"}} =
               Cooper.load_string(source, root: @fixtures, file: fixture("main.casc"))
    end
  end

  describe "a scheme import (§9.3)" do
    test "importing itself again is a cycle, like a file import" do
      source = "#@version = 1.0\nimport \"loop://self\"\n"
      schemes = %{"loop" => fn "self" -> {:ok, source} end}

      assert {:error, %Ichor.Error{stage: :import, message: message}} =
               Cooper.load_string(source, import_schemes: schemes)

      assert message =~ "cycle"
    end
  end
end
