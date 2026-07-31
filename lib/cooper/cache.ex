defmodule Cooper.Cache do
  @moduledoc """
  Backs `Cooper.load_file/2`'s default caching behavior: caches the
  *pre-resolve* tree a file's own parse+import+loop+merge pipeline
  produces (exactly what `Cooper.Grammar.run_tree/2` returns) keyed by
  its absolute path, and reuses it across calls as long as every file
  that contributed to it -- the entry file and every transitively
  bare-imported file, `Cooper.Loader`'s own `loaded_files` tracking --
  still has the same mtime it had when the entry was populated.
  `${...}` resolution (`Cooper.Resolver`) is deliberately *not* part of
  what's cached -- it re-runs, against a freshly-computed
  `Cooper.Dotenv.env/1`, on every single call regardless of hit or
  miss, so an ordinary `${NAME}` value read is always current.

  A `scheme://` import never contributes its own path to the
  fingerprint (there's no real file behind one to `File.stat/1`) -- its
  content is only as fresh as whatever triggers the *rest* of the
  entry's fingerprint to invalidate, not independently tracked.

  **A `${?NAME}` guard is decided during the cached (parse) phase**,
  using whatever env was live at populate time -- unlike an ordinary
  value read, it does *not* refresh on every access. It refreshes when
  the cache entry itself invalidates: a fingerprinted file changes, an
  explicit `invalidate/1`/`clear/0`, or (only for calls that opted in
  with `watch_env: true`) the next poll tick after a watched `${NAME}`
  changes -- see "Telemetry" below. Without `watch_env: true`, a file
  change is the only thing that refreshes it. Documented, not a bug:
  making it genuinely per-access-fresh (with no cache involved at all)
  would mean not knowing a file's own shape (which statements exist)
  until every single read, which is a fundamentally bigger feature than
  a read-through cache. (`${...}` inside an `import "..."` path is a
  separate, unconditional load-time error, not something this cache
  ever has to keep fresh -- CASC.md §5.1 doesn't support it, so it
  never reaches this cache in the first place.)

  `Cooper.load_file/2` defaults `watch_env` to `true` automatically for
  any file that reads `${...}` at all -- an ordinary value, a guard, or
  both -- and `false` for one that doesn't reference the environment in
  any way. See its own moduledoc.

  ## Concurrency

  Reads (`fetch/2`) hit the `:public`, `read_concurrency: true` ETS
  table directly from the calling process -- no message passthrough for
  the common (warm-cache) case. Only *populating* an entry goes through
  this GenServer, so concurrent misses on the *same* key coalesce into
  one load rather than a stampede of redundant re-parses (the
  GenServer re-checks the table itself before loading, in case another
  caller populated the entry while this one was waiting its turn).

  Deliberately simple, not sharded: `populate/3` runs the actual load
  *inside* the GenServer call, which means misses on two *different*
  files are also serialized against each other, not just against
  themselves. Fine for the common case (a handful of config files, load
  itself is fast) -- revisit with per-key locking (e.g. a `Registry`)
  if that ever becomes a real bottleneck for a specific deployment.

  ## Telemetry

  Two events, both no-cost if nothing's attached (`:telemetry.execute/3`
  is a cheap no-op with zero handlers):

    * `[:cooper, :cache, :file_changed]` -- measurements: `%{system_time:
      integer()}`; metadata: `%{path: String.t(), root: String.t(),
      changed_files: [String.t()]}`. Fired when a *previously cached*
      entry's fingerprint no longer matches disk -- never on the first
      population of an entry (nothing "changed" the first time).
    * `[:cooper, :cache, :env_changed]` -- same measurements shape;
      metadata: `%{path: String.t(), root: String.t(), changed_names:
      [String.t()]}`. Controlled per call via `Cooper.load_file/2`'s
      `watch_env` (defaults to `true` for a file that references the
      environment at all, `false` otherwise; pass it explicitly to
      override) -- see `watch_env/5`. Also invalidates the entry (the
      `env_watch` registration goes with it) -- the next `load_file/2`
      call for this `{path, root}` does a full reparse against the
      now-current env, not just a value re-resolve, so a `${?NAME}`
      decision that depends on a watched name refreshes within one poll
      interval of a real change, not only on a file change.
  """

  use GenServer

  @table :cooper_cache
  @default_poll_interval 5_000

  @type entry :: %{
          fingerprint: [{String.t(), integer() | nil}],
          tree: term(),
          vars: map(),
          env_watch: nil | %{names: MapSet.t(), values: map(), opts: keyword()},
          env_guard_names: MapSet.t()
        }

  @type loader_fun :: (-> {:ok, term(), map(), MapSet.t(), MapSet.t()} | {:error, term()})

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Direct ETS read for `{path, root}` -- `{:ok, tree, vars,
  env_guard_names}` if a cached entry exists and every fingerprinted
  file's mtime still matches what's on disk, `:miss` otherwise (no
  entry, or something changed). `env_guard_names` is every `${?NAME}`
  guard name used by the file (or any transitively bare-imported file)
  -- `Cooper.load_file/2` unions it with `Cooper.Resolver`'s own
  env-name tracking to decide `:watch_env`'s implicit default and,
  when enabled, exactly which names to watch (a guard name is
  frequently never read as an ordinary `${NAME}` value anywhere else,
  so `Cooper.Resolver`'s tracking alone wouldn't see it).
  """
  @spec fetch(String.t(), String.t()) :: {:ok, term(), map(), MapSet.t()} | :miss
  def fetch(path, root) do
    case raw_lookup(path, root) do
      {:ok, entry} ->
        if fingerprint_valid?(entry.fingerprint) do
          {:ok, entry.tree, entry.vars, entry.env_guard_names}
        else
          :miss
        end

      :not_found ->
        :miss
    end
  end

  @doc """
  Populates (or refreshes) the `{path, root}` entry by calling
  `loader_fun` -- a zero-arity function returning `{:ok, tree, vars,
  loaded_files, env_guard_names}` (`loaded_files` is the fingerprint
  source: every real file the load touched) or `{:error, reason}`.
  Routed through this GenServer for the stampede protection described
  in the moduledoc. A `{:error, _}` result is returned as-is and never
  cached -- a load failure isn't something to keep serving instead of
  retrying.

  Fires `[:cooper, :cache, :file_changed]` when this call *refreshes*
  an entry that already existed (any existing `watch_env/5`
  registration for the entry survives the refresh); never on a genuinely
  fresh population.
  """
  @spec populate(String.t(), String.t(), loader_fun()) ::
          {:ok, term(), map(), MapSet.t()} | {:error, term()}
  def populate(path, root, loader_fun) when is_function(loader_fun, 0) do
    GenServer.call(__MODULE__, {:populate, path, root, loader_fun}, :infinity)
  end

  @doc """
  Registers `names` (a `MapSet` of env var names, as `Cooper.Resolver`
  tracks internally while resolving) to be polled for changes, starting
  from `values` (`%{name => value}`) as the known-good baseline -- pass
  exactly what those names resolved to *just now*, not a value
  recomputed later, or a real change landing in the gap between this
  call and the (necessarily async, see below) cast being processed
  would go undetected: the "before" snapshot would already reflect the
  "after" value. Later polls re-derive the current values from
  `Cooper.Dotenv.env/1`, computed from `opts` (only the dotenv-relevant
  keys are kept: `:env`/`:dotenv`/`:dotenv_env`/`:dotenv_files`).

  A no-op if `names` is empty (nothing to watch) or the `{path, root}`
  entry doesn't currently exist (e.g. a concurrent `invalidate/1` raced
  this call -- the next load re-registers).

  A detected change invalidates the entry (this registration goes with
  it) in addition to firing `[:cooper, :cache, :env_changed]` -- see
  the moduledoc's "Telemetry" section.

  Async (`GenServer.cast/2`) -- this runs *after* a load has already
  returned its result to the caller, so there's nothing to block on.
  Starts this module's polling loop (see the moduledoc's "Telemetry"
  section) if it isn't already running; the loop stops itself again
  once nothing is being watched.
  """
  @spec watch_env(String.t(), String.t(), MapSet.t(), map(), keyword()) :: :ok
  def watch_env(path, root, names, values, opts) do
    if MapSet.size(names) > 0 do
      dotenv_opts = Keyword.take(opts, [:env, :dotenv, :dotenv_env, :dotenv_files])
      GenServer.cast(__MODULE__, {:watch_env, path, root, names, values, dotenv_opts})
    end

    :ok
  end

  @doc "Removes every cached entry for `path` (any `root`), if present."
  @spec invalidate(String.t()) :: :ok
  def invalidate(path) do
    absolute = Path.expand(path)
    GenServer.call(__MODULE__, {:invalidate, absolute})
  end

  @doc "Removes every cached entry."
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{polling?: false}}
  end

  @impl true
  def handle_call({:populate, path, root, loader_fun}, _from, state) do
    # Re-check first -- another caller may have already populated (or
    # refreshed) this exact entry while this call was waiting its turn.
    case fetch(path, root) do
      {:ok, tree, vars, env_guard_names} ->
        {:reply, {:ok, tree, vars, env_guard_names}, state}

      :miss ->
        previous = raw_lookup(path, root)

        case loader_fun.() do
          {:ok, tree, vars, loaded_files, env_guard_names} ->
            insert_and_notify(path, root, tree, vars, loaded_files, env_guard_names, previous)
            {:reply, {:ok, tree, vars, env_guard_names}, state}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  @impl true
  def handle_call({:invalidate, path}, _from, state) do
    :ets.match_delete(@table, {{path, :_}, :_})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:watch_env, path, root, names, values, dotenv_opts}, state) do
    case raw_lookup(path, root) do
      {:ok, entry} ->
        watch = %{names: names, values: values, opts: dotenv_opts}
        :ets.insert(@table, {{path, root}, %{entry | env_watch: watch}})
        {:noreply, ensure_polling(state)}

      :not_found ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:poll_env, state) do
    watched = watched_entries()
    Enum.each(watched, &check_env_entry/1)

    if watched == [] do
      {:noreply, %{state | polling?: false}}
    else
      schedule_tick()
      {:noreply, state}
    end
  end

  defp insert_and_notify(path, root, tree, vars, loaded_files, env_guard_names, previous) do
    fingerprint = build_fingerprint(loaded_files)

    env_watch =
      case previous do
        {:ok, %{env_watch: watch}} -> watch
        :not_found -> nil
      end

    entry = %{
      fingerprint: fingerprint,
      tree: tree,
      vars: vars,
      env_watch: env_watch,
      env_guard_names: env_guard_names
    }

    :ets.insert(@table, {{path, root}, entry})

    case previous do
      {:ok, %{fingerprint: old_fingerprint}} ->
        emit_file_changed(path, root, changed_files(old_fingerprint, fingerprint))

      :not_found ->
        :ok
    end
  end

  defp changed_files(old_fingerprint, new_fingerprint) do
    old_map = Map.new(old_fingerprint)
    new_map = Map.new(new_fingerprint)
    all_files = MapSet.union(mapset_keys(old_map), mapset_keys(new_map))

    for file <- all_files, Map.get(old_map, file) != Map.get(new_map, file), do: file
  end

  defp mapset_keys(map), do: map |> Map.keys() |> MapSet.new()

  defp emit_file_changed(path, root, changed_files) do
    :telemetry.execute(
      [:cooper, :cache, :file_changed],
      %{system_time: System.system_time()},
      %{path: path, root: root, changed_files: changed_files}
    )
  end

  # A detected change both fires the event *and* invalidates the entry
  # -- unlike the passive fingerprint check `fetch/2` does on every
  # call, this poll is the one place Cooper itself decides something is
  # stale and acts on it, so the next `load_file/2` call (for this
  # exact `{path, root}`) does a full reparse against the now-current
  # env, `${?NAME}` decisions included. The `env_watch` registration
  # goes with it -- it's only ever set up as a side effect of a
  # `watch_env: true` load, so it comes back the moment the next such
  # load re-populates the entry.
  defp check_env_entry({{path, root} = key, %{names: names, values: old_values, opts: opts}}) do
    new_values = current_env_values(names, opts)

    if new_values != old_values do
      changed_names =
        for name <- MapSet.to_list(names),
            Map.get(old_values, name) != Map.get(new_values, name),
            do: name

      :telemetry.execute(
        [:cooper, :cache, :env_changed],
        %{system_time: System.system_time()},
        %{path: path, root: root, changed_names: changed_names}
      )

      :ets.delete(@table, key)
    end
  end

  defp current_env_values(names, dotenv_opts) do
    case Cooper.Dotenv.env(dotenv_opts) do
      {:ok, env} -> Map.take(env, MapSet.to_list(names))
      {:error, _} -> %{}
    end
  end

  defp watched_entries do
    @table
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {key, %{env_watch: %{} = watch}} -> [{key, watch}]
      {_key, %{env_watch: nil}} -> []
    end)
  end

  defp ensure_polling(%{polling?: true} = state), do: state

  defp ensure_polling(state) do
    schedule_tick()
    %{state | polling?: true}
  end

  defp schedule_tick do
    interval = Application.get_env(:cooper, :env_poll_interval, @default_poll_interval)
    Process.send_after(self(), :poll_env, interval)
  end

  defp raw_lookup(path, root) do
    case :ets.lookup(@table, {path, root}) do
      [{_key, entry}] -> {:ok, entry}
      [] -> :not_found
    end
  end

  defp fingerprint_valid?(fingerprint) do
    Enum.all?(fingerprint, fn {file, mtime} -> current_mtime(file) == mtime end)
  end

  defp build_fingerprint(loaded_files) do
    for file <- MapSet.to_list(loaded_files), do: {file, current_mtime(file)}
  end

  defp current_mtime(file) do
    case File.stat(file, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _} -> nil
    end
  end
end
