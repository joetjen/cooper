defmodule Cooper.DotenvTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  # `Cooper.Dotenv` deliberately resolves `.env`/`.env.<env>`/`.env.local`
  # relative to the current working directory, not a per-call option
  # (see its moduledoc) -- so exercising the real file-discovery behavior
  # means actually changing the OS process's cwd for the duration of a
  # test. `:file.get_cwd/0`/`:file.set_cwd/1` are VM-wide, not scoped to
  # the calling Elixir process, so this whole module runs `async: false`
  # and every test restores the original cwd in `on_exit` even on
  # failure.
  #
  # `System.get_env/0` is part of every result and now outranks the files
  # (see the moduledoc's "Layering" section) -- the real machine's
  # environment is part of every result, so tests here can't assert full-map
  # equality against a clean expected map. Assertions instead check specific,
  # `CDT_`/fixture-namespaced keys via `Map.take/2` or `env[key]`,
  # deliberately ignoring whatever else happens to be set on the
  # machine running the suite.
  @fixtures Path.expand(Path.join([__DIR__, "..", "fixtures", "dotenv"]))

  defp in_fixture(name, fun) do
    original = File.cwd!()
    File.cd!(Path.join(@fixtures, name))
    on_exit(fn -> File.cd!(original) end)
    fun.()
  end

  # Runs `fun` in a throwaway directory holding only the given `.env` pairs, so a
  # precedence assertion cannot collide with the shared fixtures other tests read.
  defp in_own_dotenv(pairs, fun) do
    dir = Path.join(System.tmp_dir!(), "cooper_dotenv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".env"), Enum.map_join(pairs, "\n", fn {k, v} -> "#{k}=#{v}" end))

    original = File.cwd!()
    File.cd!(dir)

    on_exit(fn ->
      File.cd!(original)
      File.rm_rf!(dir)
    end)

    fun.()
  end

  defp with_system_env(pairs, fun) do
    for {name, value} <- pairs, do: System.put_env(name, value)
    on_exit(fn -> for {name, _} <- pairs, do: System.delete_env(name) end)
    fun.()
  end

  describe "System.get_env/0 outranks the files" do
    test "a real OS env var comes through when nothing else defines it" do
      with_system_env([{"CDT_FLOOR", "from-system"}], fn ->
        in_fixture("empty", fn ->
          assert {:ok, env} = Cooper.Dotenv.env(env: %{})
          assert env["CDT_FLOOR"] == "from-system"
        end)
      end)
    end

    test "a real OS env var beats the same name in a .env file" do
      # The deployment controls the environment; a file in the working
      # directory must not silently shadow what it set.
      in_own_dotenv(%{"CDT_PRECEDENCE" => "from-file"}, fn ->
        with_system_env([{"CDT_PRECEDENCE", "from-system"}], fn ->
          assert {:ok, env} = Cooper.Dotenv.env(env: %{})
          assert env["CDT_PRECEDENCE"] == "from-system"
        end)
      end)
    end

    test "dotenv_override: true puts the files back on top" do
      in_own_dotenv(%{"CDT_PRECEDENCE" => "from-file"}, fn ->
        with_system_env([{"CDT_PRECEDENCE", "from-system"}], fn ->
          assert {:ok, env} = Cooper.Dotenv.env(env: %{}, dotenv_override: true)
          assert env["CDT_PRECEDENCE"] == "from-file"
        end)
      end)
    end

    test "an explicit :env still outranks the real environment" do
      in_own_dotenv(%{"CDT_PRECEDENCE" => "from-file"}, fn ->
        with_system_env([{"CDT_PRECEDENCE", "from-system"}], fn ->
          assert {:ok, env} = Cooper.Dotenv.env(env: %{"CDT_PRECEDENCE" => "from-override"})
          assert env["CDT_PRECEDENCE"] == "from-override"
        end)
      end)
    end
  end

  describe "current-environment auto-detection (no explicit :dotenv_env)" do
    test "falls through to live Mix.env/0 -- .env.test wins during this very suite" do
      in_fixture("auto_env", fn ->
        assert {:ok, env} = Cooper.Dotenv.env(env: %{})
        assert env["ONLY_ENV_TEST"] == "from-live-mix-env"
      end)
    end

    # The next fallback after live `Mix.env/0` --
    # `Application.compile_env(:cooper, :dotenv_env)` (`compiled_env/0`
    # in `Cooper.Dotenv`) -- is a deliberate, called-out gap, same
    # spirit as the missing-`:dotenvy`-dependency gap below.
    # `Application.compile_env/3` is a macro that bakes its value into
    # a module attribute *at Cooper's own compile time*; there is no
    # way to make it return a different value per test case the way an
    # ordinary function call could, short of recompiling this whole
    # test suite under a fake `config :cooper, dotenv_env: ...` --
    # not something worth doing for one fallback branch. Verified by
    # hand instead: a scratch host app with `config :cooper, dotenv_env:
    # config_env()` in its own `config/config.exs`, compiled once per
    # `MIX_ENV`, correctly bakes in that host's own `:dev`/`:test`/
    # `:prod` -- immune to Mix's separate (and separately confirmed)
    # "every dependency compiles under :prod" rule, which is exactly
    # why `compiled_env/0` uses `Application.compile_env/3` and not a
    # bare `Mix.env/0` read from inside Cooper's own source.
  end

  describe "the full layer chain under dotenv_override: true" do
    test "the files outrank the real environment again" do
      # The pre-inversion ordering, still reachable for a developer who wants a
      # file to shadow something exported in their shell.
      with_system_env([{"ONLY_BASE", "from-system"}], fn ->
        in_fixture("layering", fn ->
          assert {:ok, env} =
                   Cooper.Dotenv.env(env: %{}, dotenv_env: :dev, dotenv_override: true)

          assert env["ONLY_BASE"] == "from-base"
        end)
      end)
    end
  end

  describe "the full layer chain, later winning" do
    test ".env, .env.<dotenv_env>, and .env.local each override the layer below them" do
      # `ONLY_BASE` is also injected as a real OS env var here, to prove the
      # real environment now outranks every file layer -- the files still
      # order among themselves exactly as before.
      with_system_env([{"ONLY_BASE", "from-system"}], fn ->
        in_fixture("layering", fn ->
          assert {:ok, env} = Cooper.Dotenv.env(env: %{}, dotenv_env: :dev)

          assert Map.take(env, ~w(ONLY_BASE SHARED DEV_AND_LOCAL ONLY_LOCAL ONLY_DEV)) == %{
                   "ONLY_BASE" => "from-system",
                   "SHARED" => "from-dev",
                   "DEV_AND_LOCAL" => "from-local",
                   "ONLY_LOCAL" => "from-local",
                   "ONLY_DEV" => "from-dev"
                 }
        end)
      end)
    end

    test "an explicit :env entry always wins, over .env.local included" do
      in_fixture("layering", fn ->
        assert {:ok, env} =
                 Cooper.Dotenv.env(env: %{"SHARED" => "from-explicit-override"}, dotenv_env: :dev)

        assert env["SHARED"] == "from-explicit-override"
        # A name *not* given in :env still falls through to the file layers.
        assert env["ONLY_DEV"] == "from-dev"
      end)
    end

    test "no per-env file is read when dotenv_env is nil, even with .env/.env.local present" do
      in_fixture("layering", fn ->
        assert {:ok, env} = Cooper.Dotenv.env(env: %{}, dotenv_env: nil)

        assert Map.take(env, ~w(SHARED DEV_AND_LOCAL ONLY_LOCAL ONLY_DEV)) == %{
                 "SHARED" => "from-base",
                 "DEV_AND_LOCAL" => "from-local",
                 "ONLY_LOCAL" => "from-local"
               }

        refute Map.has_key?(env, "ONLY_DEV")
      end)
    end

    test "an unmatched environment's own file is simply absent, not an error" do
      in_fixture("layering", fn ->
        assert {:ok, env} = Cooper.Dotenv.env(env: %{}, dotenv_env: :prod)
        refute Map.has_key?(env, "ONLY_DEV")
        assert env["SHARED"] == "from-base"
      end)
    end
  end

  describe "missing files are never a load-time error" do
    test "a directory with none of the four files still resolves the override + real env" do
      in_fixture("empty", fn ->
        assert {:ok, env} = Cooper.Dotenv.env(env: %{"KEPT" => "1"}, dotenv_env: :dev)
        assert env["KEPT"] == "1"
      end)
    end
  end

  describe "dotenv: false disables just the .env file layers" do
    test "System.get_env/0 and an explicit :env still apply" do
      with_system_env([{"CDT_FLOOR", "from-system"}], fn ->
        in_fixture("layering", fn ->
          assert {:ok, env} = Cooper.Dotenv.env(dotenv: false, env: %{"OVERRIDE" => "value"})

          assert env["CDT_FLOOR"] == "from-system"
          assert env["OVERRIDE"] == "value"
          # .env would have set this if dotenv weren't disabled.
          refute Map.has_key?(env, "ONLY_BASE")
        end)
      end)
    end
  end

  describe ":dotenv_files fully replaces the default file list" do
    test "only the listed files are consulted, in the given order" do
      in_fixture("layering", fn ->
        assert {:ok, env} = Cooper.Dotenv.env(env: %{}, dotenv_files: [".env.local"])

        assert Map.take(env, ~w(DEV_AND_LOCAL ONLY_LOCAL ONLY_BASE)) == %{
                 "DEV_AND_LOCAL" => "from-local",
                 "ONLY_LOCAL" => "from-local"
               }
      end)
    end
  end

  describe "a malformed .env file" do
    test "is a load-time error naming the failure, tagged :dotenv" do
      in_fixture("malformed", fn ->
        assert {:error, %Ichor.Error{stage: :dotenv, message: message}} =
                 Cooper.Dotenv.env(env: %{})

        assert message =~ "dotenv loading failed"
      end)
    end
  end

  describe "wired into Cooper.load_string/2" do
    test "a ${...} reference in the source resolves against a real .env file, dotenv defaulted on" do
      in_fixture("layering", fn ->
        source = """
        #@version = 1.0
        shared = ${SHARED}
        """

        assert Cooper.load_string(source, dotenv_env: :dev) == {:ok, %{"shared" => "from-dev"}}
      end)
    end

    test "an explicit :env entry wins over a .env file value for the same name" do
      in_fixture("layering", fn ->
        source = """
        #@version = 1.0
        shared = ${SHARED}
        """

        assert Cooper.load_string(source, env: %{"SHARED" => "explicit"}, dotenv_env: :dev) ==
                 {:ok, %{"shared" => "explicit"}}
      end)
    end
  end

  # The "optional :dotenvy dependency isn't installed" branches
  # (`Cooper.Dotenv`'s `missing_dependency/2`) are a deliberate, called-
  # out gap: Cooper's own test suite necessarily has `:dotenvy` present
  # (it's how the tests above exercise real file loading at all), and
  # there's no safe way to make it look absent mid-suite without
  # unloading the module out from under any test that runs concurrently
  # with this one. The logic itself is two literal branches with no
  # merge/precedence behavior to protect, which is why it's flagged here
  # rather than contorted into a fake test.

  property "precedence always holds: .env < .env.<dotenv_env> < .env.local < System.get_env/0 < :env, for arbitrary key/value layers" do
    check all(
            dotenv <- layer_map(),
            env_file <- layer_map(),
            local <- layer_map(),
            system <- layer_map(),
            override <- layer_map(),
            max_runs: 25
          ) do
      dir =
        Path.join(System.tmp_dir!(), "cooper_dotenv_prop_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      original = File.cwd!()

      try do
        File.cd!(dir)
        write_layer(".env", dotenv)
        write_layer(".env.proptest", env_file)
        write_layer(".env.local", local)

        expected =
          dotenv
          |> Map.merge(env_file)
          |> Map.merge(local)
          |> Map.merge(system)
          |> Map.merge(override)

        for {name, value} <- system, do: System.put_env(name, value)

        assert {:ok, actual} = Cooper.Dotenv.env(env: override, dotenv_env: :proptest)
        assert Map.take(actual, ~w(CDT_A CDT_B CDT_C CDT_D CDT_E CDT_F)) == expected
      after
        for {name, _value} <- system, do: System.delete_env(name)
        File.cd!(original)
        File.rm_rf!(dir)
      end
    end
  end

  # A handful of fixed, `CDT_`-prefixed keys (unlikely to collide with a
  # real variable on the machine running the suite) so the layers
  # frequently overlap on the same key -- the property is only
  # interesting when they do.
  defp layer_map do
    key = StreamData.member_of(~w(CDT_A CDT_B CDT_C CDT_D CDT_E CDT_F))
    value = StreamData.string(?a..?z, min_length: 1, max_length: 6)

    StreamData.map_of(key, value, max_length: 3)
  end

  defp write_layer(_name, map) when map_size(map) == 0, do: :ok

  defp write_layer(name, map) do
    contents = Enum.map_join(map, "\n", fn {k, v} -> "#{k}=#{v}" end)
    File.write!(name, contents <> "\n")
  end
end
