defmodule Cooper.ImportInterpolationTest do
  use ExUnit.Case, async: true

  # An import path may interpolate `${NAME}` (CASC.md §5.1), which is what lets
  # one document select a per-environment overlay instead of the selection
  # living in the consuming application's code.
  #
  # Only `${...}` works, and deliberately so: imports are resolved while the
  # document is parsed, so anything needing the finished tree cannot exist yet.
  # `ctx.env` can, which is the same thing a `${?NAME}` guard reads.

  setup context do
    dir = Path.join(System.tmp_dir!(), "cooper_import_#{:erlang.phash2(context.test)}")
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "env"))
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join([dir, "env", "dev.casc"]), "#@version = 1.0\ndemo { from = dev }\n")
    File.write!(Path.join([dir, "env", "test.casc"]), "#@version = 1.0\ndemo { from = test }\n")

    {:ok, dir: dir}
  end

  defp load(dir, source, env) do
    path = Path.join(dir, "entry.casc")
    File.write!(path, source)
    Cooper.load_file(path, cache: false, dotenv: false, env: env)
  end

  describe "selecting an import by environment" do
    test "the variable selects the file", %{dir: dir} do
      source = ~s(#@version = 1.0\nimport "env/${MIX_ENV:dev}.casc"\n)

      assert {:ok, %{"demo" => %{"from" => :test}}} = load(dir, source, %{"MIX_ENV" => "test"})
    end

    test "an unset variable falls back to the default", %{dir: dir} do
      source = ~s(#@version = 1.0\nimport "env/${MIX_ENV:dev}.casc"\n)

      assert {:ok, %{"demo" => %{"from" => :dev}}} = load(dir, source, %{})
    end

    test "an empty variable counts as unset, as everywhere else", %{dir: dir} do
      source = ~s(#@version = 1.0\nimport "env/${MIX_ENV:dev}.casc"\n)

      assert {:ok, %{"demo" => %{"from" => :dev}}} = load(dir, source, %{"MIX_ENV" => ""})
    end

    test "a plain literal path still works", %{dir: dir} do
      source = ~s(#@version = 1.0\nimport "env/test.casc"\n)

      assert {:ok, %{"demo" => %{"from" => :test}}} = load(dir, source, %{})
    end
  end

  describe "refusing what cannot be resolved while parsing" do
    test "an unset variable with no default is an error rather than a wrong path", %{dir: dir} do
      # Without this, the path would silently become "env/.casc".
      source = ~s(#@version = 1.0\nimport "env/${MIX_ENV}.casc"\n)

      assert {:error, error} = load(dir, source, %{})
      assert error_message(error) =~ "unset and has no default"
    end

    test "a config reference cannot be used, since the tree does not exist yet", %{dir: dir} do
      source = ~s(#@version = 1.0\nwhich = "test"\nimport "env/%{which}.casc"\n)

      assert {:error, error} = load(dir, source, %{})
      assert error_message(error) =~ "may interpolate only"
    end

    test "a missing selected file still reports a normal import failure", %{dir: dir} do
      source = ~s(#@version = 1.0\nimport "env/${MIX_ENV:dev}.casc"\n)

      assert {:error, error} = load(dir, source, %{"MIX_ENV" => "staging"})
      refute error_message(error) =~ "may interpolate only"
    end
  end

  defp error_message(error) when is_list(error), do: hd(error).message
  defp error_message(error), do: error.message
end
