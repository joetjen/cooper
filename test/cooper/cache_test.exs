defmodule Cooper.CacheTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  # `Cooper.Cache` is a single, application-wide GenServer/ETS table
  # (`Cooper.Application` starts it as part of `mix test`'s own app
  # boot) -- shared state across the whole test run, so this module runs
  # `async: false` and every test uses its own uniquely-named scratch
  # file rather than relying on ordering or `clear/0` for isolation.
  @scratch_dir Path.join(System.tmp_dir!(), "cooper_cache_test")

  setup_all do
    File.mkdir_p!(@scratch_dir)
    on_exit(fn -> File.rm_rf!(@scratch_dir) end)

    # `watch_env` now defaults to `true` for *any* file that references
    # `${...}` at all -- which most fixtures in this very module do --
    # so practically every test here can end up starting `Cooper.Cache`'s
    # shared poller, not just the ones in the "env_changed" describe
    # block below. `ensure_polling/1` is a no-op once a poll loop is
    # already running, so whichever test happens to start it first wins
    # the interval for everyone until it goes idle again -- set it short
    # module-wide, once, rather than per-describe-block, so a test
    # elsewhere in this file starting the loop first (at the default
    # 5s) can't starve a later test's `assert_receive` timeout.
    previous = Application.get_env(:cooper, :env_poll_interval)
    Application.put_env(:cooper, :env_poll_interval, 100)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:cooper, :env_poll_interval)
        value -> Application.put_env(:cooper, :env_poll_interval, value)
      end
    end)

    :ok
  end

  defp scratch_path(name), do: Path.join(@scratch_dir, "#{name}_#{unique()}.casc")
  defp unique, do: System.unique_integer([:positive])

  # `File.touch!/2` takes an integer POSIX mtime directly -- explicit,
  # deterministic mtimes throughout, never real-clock `File.touch!/1`,
  # so two writes in the same test can never collide on the same
  # second (a real risk with real-time touches on a fast test run,
  # since mtime resolution is whole seconds).
  defp write(path, mtime, content) do
    File.write!(path, content)
    File.touch!(path, mtime)
  end

  defp fingerprint(path) do
    absolute = Path.expand(path)
    {absolute, Path.dirname(absolute)}
  end

  # A module-function capture, not a closure -- `:telemetry` logs a
  # (harmless but noisy) warning for a handler that's a local/anonymous
  # function, since it can't dispatch one as efficiently. `test_pid`
  # rides along in `config` instead of being captured.
  defp attach_telemetry(events) do
    handler_id = "cache_test_#{unique()}"
    :telemetry.attach_many(handler_id, events, &__MODULE__.handle_telemetry/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  @doc false
  def handle_telemetry(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry, event, measurements, metadata})
  end

  describe "a cache hit reuses the parsed tree" do
    test "a content edit with the mtime pinned back to the same value is not observed" do
      path = scratch_path("hit")
      write(path, 1000, "#@version = 1.0\nname = \"first\"\n")

      assert {:ok, %{"name" => "first"}} = Cooper.load_file(path)

      # Same mtime as before -- the cache trusts the fingerprint over
      # re-reading, so this edit is deliberately invisible until
      # something bumps the mtime for real.
      write(path, 1000, "#@version = 1.0\nname = \"second\"\n")

      assert {:ok, %{"name" => "first"}} = Cooper.load_file(path)
    end
  end

  describe "${...} resolution is always fresh, hit or miss" do
    test "a real env var change is reflected on a cache hit" do
      path = scratch_path("env")
      write(path, 2000, "#@version = 1.0\nvalue = ${COOPER_CACHE_TEST_VAR:\"default\"}\n")
      System.delete_env("COOPER_CACHE_TEST_VAR")
      on_exit(fn -> System.delete_env("COOPER_CACHE_TEST_VAR") end)

      # `watch_env: false` -- this test is about value freshness, not
      # the watch/telemetry feature; the fixture referencing ${...}
      # would otherwise default it on and register with the shared
      # poller, whose eventual detection could fire (and reach a
      # telemetry handler) during a *later*, unrelated test.
      assert {:ok, %{"value" => "default"}} = Cooper.load_file(path, watch_env: false)

      System.put_env("COOPER_CACHE_TEST_VAR", "live")
      assert {:ok, %{"value" => "live"}} = Cooper.load_file(path, watch_env: false)
    end
  end

  describe "a file's own mtime change invalidates its cache entry" do
    test "the next load reflects the new content" do
      path = scratch_path("miss")
      write(path, 3000, "#@version = 1.0\nname = \"before\"\n")

      assert {:ok, %{"name" => "before"}} = Cooper.load_file(path)

      write(path, 3001, "#@version = 1.0\nname = \"after\"\n")

      assert {:ok, %{"name" => "after"}} = Cooper.load_file(path)
    end
  end

  describe "a transitively-imported file also fingerprints into the importer's cache entry" do
    test "changing only the imported file busts the importer's cache" do
      dir = Path.join(@scratch_dir, "import_#{unique()}")
      File.mkdir_p!(dir)
      base = Path.join(dir, "base.casc")
      importer = Path.join(dir, "importer.casc")

      write(base, 4000, "#@version = 1.0\nshared = \"base-v1\"\n")
      write(importer, 4000, "#@version = 1.0\nimport \"base.casc\"\n")

      assert {:ok, %{"shared" => "base-v1"}} = Cooper.load_file(importer)

      write(base, 4001, "#@version = 1.0\nshared = \"base-v2\"\n")

      assert {:ok, %{"shared" => "base-v2"}} = Cooper.load_file(importer)
    end

    test "deleting the imported file surfaces the ordinary read error, not a stale hit" do
      dir = Path.join(@scratch_dir, "import_del_#{unique()}")
      File.mkdir_p!(dir)
      base = Path.join(dir, "base.casc")
      importer = Path.join(dir, "importer.casc")

      write(base, 4100, "#@version = 1.0\nshared = \"base-v1\"\n")
      write(importer, 4100, "#@version = 1.0\nimport \"base.casc\"\n")

      assert {:ok, %{"shared" => "base-v1"}} = Cooper.load_file(importer)

      File.rm!(base)

      assert {:error, %Ichor.Error{stage: :import}} = Cooper.load_file(importer)
    end
  end

  describe "cache: false" do
    test "bypasses the cache entirely -- never reads or populates an entry" do
      path = scratch_path("bypass")
      write(path, 5000, "#@version = 1.0\nname = \"only\"\n")
      {absolute, root} = fingerprint(path)

      assert Cooper.Cache.fetch(absolute, root) == :miss
      assert {:ok, %{"name" => "only"}} = Cooper.load_file(path, cache: false)
      assert Cooper.Cache.fetch(absolute, root) == :miss
    end
  end

  describe "Cooper.Cache.invalidate/1" do
    test "removes only the given path's entry, leaving others untouched" do
      path_a = scratch_path("inv_a")
      path_b = scratch_path("inv_b")
      write(path_a, 6000, "#@version = 1.0\nname = \"a\"\n")
      write(path_b, 6000, "#@version = 1.0\nname = \"b\"\n")

      {:ok, _} = Cooper.load_file(path_a)
      {:ok, _} = Cooper.load_file(path_b)

      {absolute_a, root_a} = fingerprint(path_a)
      {absolute_b, root_b} = fingerprint(path_b)

      assert match?({:ok, _, _, _}, Cooper.Cache.fetch(absolute_a, root_a))
      assert Cooper.Cache.invalidate(path_a) == :ok
      assert Cooper.Cache.fetch(absolute_a, root_a) == :miss
      assert match?({:ok, _, _, _}, Cooper.Cache.fetch(absolute_b, root_b))
    end
  end

  describe "Cooper.Cache.clear/0" do
    test "removes every cached entry" do
      path = scratch_path("clear")
      write(path, 7000, "#@version = 1.0\nname = \"x\"\n")
      {:ok, _} = Cooper.load_file(path)

      {absolute, root} = fingerprint(path)
      assert match?({:ok, _, _, _}, Cooper.Cache.fetch(absolute, root))

      assert Cooper.Cache.clear() == :ok
      assert Cooper.Cache.fetch(absolute, root) == :miss
    end
  end

  describe "concurrent misses on the same key" do
    test "coalesce into exactly one populate call" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      loader_fun = fn ->
        Agent.update(counter, &(&1 + 1))
        Process.sleep(50)
        {:ok, %{"stub" => true}, %{}, MapSet.new(), false}
      end

      key = "concurrent_#{unique()}"

      results =
        1..10
        |> Enum.map(fn _ ->
          Task.async(fn -> Cooper.Cache.populate(key, "/root", loader_fun) end)
        end)
        |> Task.await_many(5000)

      assert Enum.all?(results, &(&1 == {:ok, %{"stub" => true}, %{}, false}))
      assert Agent.get(counter, & &1) == 1
    end
  end

  describe "telemetry: [:cooper, :cache, :file_changed]" do
    test "fires on a real reload, never on first population" do
      path = scratch_path("telem_file")
      attach_telemetry([[:cooper, :cache, :file_changed]])

      write(path, 9000, "#@version = 1.0\nname = \"first\"\n")
      {:ok, _} = Cooper.load_file(path)
      refute_receive {:telemetry, [:cooper, :cache, :file_changed], _, _}, 100

      write(path, 9001, "#@version = 1.0\nname = \"second\"\n")
      {:ok, _} = Cooper.load_file(path)

      {absolute, root} = fingerprint(path)
      assert_receive {:telemetry, [:cooper, :cache, :file_changed], _measurements, metadata}, 1000
      assert metadata.path == absolute
      assert metadata.root == root
      assert metadata.changed_files == [absolute]
    end

    test "names a transitively-imported file when only it changes" do
      dir = Path.join(@scratch_dir, "telem_import_#{unique()}")
      File.mkdir_p!(dir)
      base = Path.join(dir, "base.casc")
      importer = Path.join(dir, "importer.casc")

      write(base, 9100, "#@version = 1.0\nshared = \"v1\"\n")
      write(importer, 9100, "#@version = 1.0\nimport \"base.casc\"\n")

      attach_telemetry([[:cooper, :cache, :file_changed]])

      {:ok, _} = Cooper.load_file(importer)
      write(base, 9101, "#@version = 1.0\nshared = \"v2\"\n")
      {:ok, _} = Cooper.load_file(importer)

      absolute_base = Path.expand(base)
      assert_receive {:telemetry, [:cooper, :cache, :file_changed], _, metadata}, 1000
      assert metadata.changed_files == [absolute_base]
    end
  end

  describe "telemetry: [:cooper, :cache, :env_changed] via watch_env: true" do
    # `env_poll_interval` is set module-wide, once, in `setup_all` above
    # -- just the cache itself needs resetting between these tests, so
    # an earlier test's leftover watched entry can't fire into a later
    # test's telemetry handler.
    setup do
      on_exit(fn -> Cooper.Cache.clear() end)
      :ok
    end

    test "fires when a real System.put_env/2 change is detected for a referenced name" do
      path = scratch_path("telem_env")
      write(path, 9200, "#@version = 1.0\nvalue = ${COOPER_TELEM_ENV_VAR:\"default\"}\n")
      System.delete_env("COOPER_TELEM_ENV_VAR")
      on_exit(fn -> System.delete_env("COOPER_TELEM_ENV_VAR") end)

      attach_telemetry([[:cooper, :cache, :env_changed]])

      {:ok, _} = Cooper.load_file(path, watch_env: true)
      System.put_env("COOPER_TELEM_ENV_VAR", "live")

      assert_receive {:telemetry, [:cooper, :cache, :env_changed], _, metadata}, 2000
      assert metadata.changed_names == ["COOPER_TELEM_ENV_VAR"]
    end

    test "fires on a .env file edit -- same mechanism as a real env var, no separate file-watch needed" do
      dir = Path.join(@scratch_dir, "telem_dotenv_#{unique()}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "app.casc")
      write(path, 9300, "#@version = 1.0\nvalue = ${COOPER_TELEM_DOTENV_VAR:\"default\"}\n")

      attach_telemetry([[:cooper, :cache, :env_changed]])

      original = File.cwd!()
      File.cd!(dir)
      on_exit(fn -> File.cd!(original) end)

      assert {:ok, %{"value" => "default"}} = Cooper.load_file(path, watch_env: true)

      File.write!(".env", "COOPER_TELEM_DOTENV_VAR=from-dotenv\n")

      assert_receive {:telemetry, [:cooper, :cache, :env_changed], _, metadata}, 2000
      assert metadata.changed_names == ["COOPER_TELEM_DOTENV_VAR"]
    end

    test "defaults to on, with no explicit :watch_env at all, for a file that references the environment" do
      path = scratch_path("telem_env_default_on")
      write(path, 9400, "#@version = 1.0\nvalue = ${COOPER_TELEM_DEFAULT_VAR:\"default\"}\n")
      System.delete_env("COOPER_TELEM_DEFAULT_VAR")
      on_exit(fn -> System.delete_env("COOPER_TELEM_DEFAULT_VAR") end)

      attach_telemetry([[:cooper, :cache, :env_changed]])

      {:ok, _} = Cooper.load_file(path)
      System.put_env("COOPER_TELEM_DEFAULT_VAR", "live")

      assert_receive {:telemetry, [:cooper, :cache, :env_changed], _, metadata}, 2000
      assert metadata.changed_names == ["COOPER_TELEM_DEFAULT_VAR"]
    end

    test "watch_env: false disables it explicitly, even for a file that references the environment" do
      path = scratch_path("telem_env_off")
      write(path, 9401, "#@version = 1.0\nvalue = ${COOPER_TELEM_OFF_VAR:\"default\"}\n")
      System.delete_env("COOPER_TELEM_OFF_VAR")
      on_exit(fn -> System.delete_env("COOPER_TELEM_OFF_VAR") end)

      attach_telemetry([[:cooper, :cache, :env_changed]])

      {:ok, _} = Cooper.load_file(path, watch_env: false)
      System.put_env("COOPER_TELEM_OFF_VAR", "live")

      refute_receive {:telemetry, [:cooper, :cache, :env_changed], _, _}, 500
    end

    test "never fires for an unrelated name -- only names the config actually reads" do
      path = scratch_path("telem_env_selective")
      write(path, 9500, "#@version = 1.0\nvalue = ${COOPER_TELEM_TRACKED:\"default\"}\n")
      System.delete_env("COOPER_TELEM_TRACKED")
      System.delete_env("COOPER_TELEM_UNRELATED")

      on_exit(fn ->
        System.delete_env("COOPER_TELEM_TRACKED")
        System.delete_env("COOPER_TELEM_UNRELATED")
      end)

      attach_telemetry([[:cooper, :cache, :env_changed]])

      {:ok, _} = Cooper.load_file(path, watch_env: true)
      System.put_env("COOPER_TELEM_UNRELATED", "irrelevant")

      refute_receive {:telemetry, [:cooper, :cache, :env_changed], _, _}, 500
    end

    test "watches a guard-only name -- never read as an ordinary ${...} value anywhere in the file" do
      path = scratch_path("telem_env_guard_only")
      # `COOPER_TELEM_GUARD_ONLY_VAR` appears *only* in the guard, never
      # as an ordinary ${...} read -- proving `Cooper.Resolver`'s own
      # env-name tracking doesn't have to see a name for it to end up
      # watched; the guard-name tracking from parsing covers it too.
      write(path, 9600, """
      #@version = 1.0
      ${?COOPER_TELEM_GUARD_ONLY_VAR} guarded = true
      """)

      System.delete_env("COOPER_TELEM_GUARD_ONLY_VAR")
      on_exit(fn -> System.delete_env("COOPER_TELEM_GUARD_ONLY_VAR") end)

      attach_telemetry([[:cooper, :cache, :env_changed]])

      assert {:ok, result} = Cooper.load_file(path, watch_env: true)
      refute Map.has_key?(result, "guarded")

      {absolute, root} = fingerprint(path)
      assert match?({:ok, _, _, _}, Cooper.Cache.fetch(absolute, root))

      System.put_env("COOPER_TELEM_GUARD_ONLY_VAR", "1")
      assert_receive {:telemetry, [:cooper, :cache, :env_changed], _, metadata}, 2000
      assert metadata.changed_names == ["COOPER_TELEM_GUARD_ONLY_VAR"]

      # The entry is gone, not just notified about -- proving the next
      # load does a full reparse rather than reusing the stale tree.
      assert Cooper.Cache.fetch(absolute, root) == :miss

      assert {:ok, %{"guarded" => true}} = Cooper.load_file(path)
    end
  end

  property "an arbitrary sequence of distinct-mtime writes is always observed on the very next load" do
    check all(
            names <-
              list_of(string(?a..?z, min_length: 1, max_length: 8), min_length: 1, max_length: 10),
            max_runs: 25
          ) do
      path = scratch_path("prop")
      base_mtime = unique()

      names
      |> Enum.with_index()
      |> Enum.each(fn {name, i} ->
        write(path, base_mtime + i, "#@version = 1.0\nname = \"#{name}\"\n")
        assert {:ok, %{"name" => ^name}} = Cooper.load_file(path)
      end)
    end
  end
end
