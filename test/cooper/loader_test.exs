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
end
