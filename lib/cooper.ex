defmodule Cooper do
  @moduledoc """
  Parses and loads CASC config files (see `CASC.md`) into native Elixir
  terms: maps (string keys), atoms, real tuples (never lists --
  CASC.md §6.11 is explicit that this is a correctness requirement, not
  an implementation detail), and `Cooper.Secret`-wrapped values for any
  `*key`-prefixed secret.

  `load_file/2`/`load_string/2` run the whole pipeline end to end:
  lex+parse (`Cooper.Grammar`, `Cooper.Actions`) → loop expansion
  (`Cooper.Loop`) → import resolution (`Cooper.Loader`) → merge and
  secret-wrapping (`Cooper.Merge`) → reference resolution
  (`Cooper.Resolver`, which re-wraps a `Cooper.Secret`'s own inner
  value as it resolves, so the wrapping travels through a `%{...}`
  reference or a `for ... from` template copy rather than staying
  pinned to the value's original declared path). `load_file/2` caches
  everything before that final reference-resolution step, on by
  default, keyed by file mtime -- see `Cooper.Cache`. `load_string/2`
  has no file to key a cache on, so it never caches.

  ## Options

  Both functions take the same `opts`:

    * `:env` -- `%{String.t() => String.t()}`, an override layer for
      `${...}` (CASC.md §7.2) resolution -- **not** a replacement for
      the real environment. `System.get_env/0` is always the floor
      (layered under `.env`/`.env.local`, in turn under `:env`, see
      `Cooper.Dotenv`); a name given here always wins, but a name
      *not* given here still falls through to a real OS/`.env` value if
      one is set. There is currently no option that fully isolates
      resolution from the real environment -- give every name a test
      needs a deterministic value under `:env` explicitly, rather than
      relying on it being otherwise unset.
    * `:dotenv` / `:dotenv_env` / `:dotenv_files` -- layer `.env`
      file(s) from the project root between `System.get_env/0` and
      `:env`, via the optional `:dotenvy` dependency, on by default.
      See `Cooper.Dotenv` for the full layering rules, environment
      detection, and how to disable or reconfigure it.
    * `:root` -- filesystem root a bare (non-`scheme://`) `import`
      resolves relative to (§5.1). `load_file/2` derives this from
      `path`'s own directory automatically; `load_string/2` defaults to
      `File.cwd!/0`.
    * `:resolvers` -- `%{String.t() => (payload :: String.t() -> {:ok,
      term()} | {:error, term()})}`, one function per `!{resolver:...}`
      name your application registers (§7.4/§9.2). Unregistered use of
      any resolver not in this map is a load-time error naming it.
    * `:tags` -- same shape, for `!Name(arg)` beyond the five built-ins
      (`int`/`float`/`bool`/`duration`/`bytes`, §7.5/§9.1). Unregistered
      use is a load-time error naming it, same as `:resolvers`.
    * `:import_schemes` -- `%{String.t() => (rest :: String.t() ->
      {:ok, String.t()} | {:error, term()})}`, one loader per
      `import "scheme://..."` scheme your application registers
      (§5.1/§9.3), returning the imported CASC source text. Unregistered
      use of any scheme not in this map is a load-time error naming it.
    * `:cache` -- `load_file/2` only (`load_string/2` never caches --
      there's no file to key one on). `boolean()`, defaults to `true`.
      `false` bypasses the cache entirely for that one call.
    * `:watch_env` -- `load_file/2` only. `boolean()`, defaults to
      whether this call references the environment at all (an ordinary
      `${NAME}` value, a `${?NAME}` guard, or both) -- `true` for a
      file that does, `false` for one that doesn't. Either way, polls
      every referenced name for changes, firing `[:cooper, :cache,
      :env_changed]` (see `Cooper.Cache`) if any of them do; pass it
      explicitly to override the default in either direction.

  ## Errors

  Every stage returns `{:error, Ichor.Error.t() | [Ichor.Error.t()]}` on
  failure, reusing `Ichor.Error` directly rather than inventing a
  parallel error type -- lexer/parser/analysis errors come from Ichor's
  own stages unchanged; `Cooper`'s own stages (`:dotenv`, `:loop`,
  `:import`, `:merge`, `:resolve`) extend the same `%Ichor.Error{stage:
  ...}` shape with new atoms rather than a new struct, so every error
  looks the same regardless of which stage raised it.

  ## A note on atoms

  CASC atoms (`level = info`, CASC.md §6.4) become Elixir atoms via
  `String.to_atom/1`, for the ergonomics of pattern-matching against a
  config value the ordinary Elixir way. Elixir's atom table is bounded
  and never garbage-collected -- fine for config sourced from a fixed,
  trusted set of files (typical CASC usage), but worth flagging
  explicitly if `Cooper` is ever pointed at config sources that aren't
  trusted/fixed at deploy time (e.g. user-uploaded config): an attacker
  who can supply arbitrary atom-shaped text can exhaust the atom table.
  Not a concern for the common case; a real one to know about outside it.
  """

  alias Ichor.Error

  @type opts :: [
          env: %{optional(String.t()) => String.t()},
          dotenv: boolean(),
          dotenv_env: atom() | nil,
          dotenv_files: [String.t()],
          cache: boolean(),
          watch_env: boolean(),
          root: String.t(),
          resolvers: %{optional(String.t()) => (String.t() -> {:ok, term()} | {:error, term()})},
          tags: %{optional(String.t()) => (term() -> {:ok, term()} | {:error, term()})},
          import_schemes: %{
            optional(String.t()) => (String.t() -> {:ok, String.t()} | {:error, term()})
          }
        ]

  @doc """
  Reads and loads the CASC file at `path`. `:root` (see the moduledoc)
  defaults to `path`'s own directory, and import-cycle detection is
  seeded with `path` itself (`Cooper.Grammar.run_file/2`'s own `:file`
  option), so a cycle that loops back to the entry file is caught on the
  first repeat.

  Caches the *pre-resolve* tree `Cooper.Grammar` produces, on by
  default, and reuses it across calls as long as every file that
  contributed to it -- this one, plus every transitively bare-imported
  file -- still has the mtime it had when the cache entry was populated
  (see `Cooper.Cache`). `${...}` resolution is never part of what's
  cached: it re-runs against a freshly-computed `Cooper.Dotenv.env/1` on
  *every* call, hit or miss, so an ordinary `${NAME}` value read is
  always current regardless of caching.

  Pass `cache: false` to bypass the cache entirely for one call -- for
  forcing a guaranteed-fresh read, or in tests.

  One real limitation, not a bug: a `${?NAME}` guard's decision is
  baked in at the moment the cache entry is populated, and only
  refreshes when that entry itself invalidates -- not on every access
  the way an ordinary value read is. Without `watch_env: true` (below),
  the only thing that invalidates it is a fingerprinted file changing,
  or an explicit `Cooper.Cache.invalidate/1`/`clear/0`. See
  `Cooper.Cache`'s moduledoc for why that's a deliberate scope
  boundary. `cache: false` sidesteps it entirely, at the cost of a full
  reparse on every call. (`${...}` inside an `import "..."` path is a
  different matter entirely -- CASC.md §5.1 doesn't support it, so it's
  always an unconditional load-time error, never something to keep
  fresh.)

  `watch_env` polls every `${NAME}` this call reads for changes -- an
  ordinary value, a guard, or both -- and defaults to `true` for a file
  that references the environment at all, `false` for one that doesn't
  (pass it explicitly either way to override). Checked on a timer
  rather than pushed live: a real `System.put_env/2` elsewhere in this
  app and a `.env` file edit both count, since neither has an OS-level
  notification to hook into. A detected change fires `[:cooper, :cache,
  :env_changed]` *and* invalidates the entry, so the guard limitation
  above narrows to "up to one poll interval stale" for a watched name,
  instead of "stale until the file changes." `Cooper.Cache` also fires
  `[:cooper, :cache, :file_changed]` whenever a cached entry's own
  fingerprint changes, unconditionally -- no option needed for that
  one. See `Cooper.Cache`.
  """
  @spec load_file(String.t(), opts()) :: {:ok, term()} | {:error, Error.t() | [Error.t()]}
  def load_file(path, opts \\ []) do
    absolute = Path.expand(path)

    with {:ok, source} <- read_file(path, absolute) do
      if Keyword.get(opts, :cache, true) do
        load_cached(absolute, source, opts)
      else
        load_string(source, Keyword.merge([root: Path.dirname(absolute), file: absolute], opts))
      end
    end
  end

  defp load_cached(absolute, source, opts) do
    root = Keyword.get(opts, :root, Path.dirname(absolute))

    with {:ok, env} <- Cooper.Dotenv.env(opts) do
      case Cooper.Cache.fetch(absolute, root) do
        {:ok, tree, vars, env_guard_names} ->
          resolve_cached(tree, vars, env, absolute, root, opts, env_guard_names)

        :miss ->
          loader_fun = fn -> load_tree(source, absolute, root, env, opts) end

          case Cooper.Cache.populate(absolute, root, loader_fun) do
            {:ok, tree, vars, env_guard_names} ->
              resolve_cached(tree, vars, env, absolute, root, opts, env_guard_names)

            {:error, _} = err ->
              err
          end
      end
    end
  end

  defp load_tree(source, absolute, root, env, opts) do
    grammar_opts =
      [root: root, file: absolute, env: env] ++ Keyword.take(opts, [:import_schemes])

    Cooper.Grammar.run_tree_with_files(source, grammar_opts)
  end

  defp resolve_cached(tree, vars, env, absolute, root, opts, env_guard_names) do
    resolver_opts = [vars: vars, env: env] ++ Keyword.take(opts, [:resolvers, :tags])

    with {:ok, resolved, env_names} <- Cooper.Resolver.resolve_with_env_names(tree, resolver_opts) do
      # Every name this load depends on any way at all: an ordinary
      # `${NAME}` value read (`env_names`, from `Cooper.Resolver`) or a
      # `${?NAME}` guard (`env_guard_names`, from parsing -- frequently
      # never read as an ordinary value anywhere else, so
      # `Cooper.Resolver`'s own tracking alone wouldn't see it).
      all_names = MapSet.union(env_names, env_guard_names)

      if watch_env?(opts, all_names) do
        # `values` is captured *here*, synchronously, from the exact
        # `env` this resolve just used -- not recomputed later inside
        # `Cooper.Cache`'s (necessarily async, see `watch_env/5`'s own
        # comment) cast handler. Recomputing it there would race: if
        # something changes the env between this call returning and the
        # GenServer actually processing the cast, the "before" snapshot
        # would already reflect the *new* value, and the real change
        # would never be detected as one.
        values = Map.take(env, MapSet.to_list(all_names))
        Cooper.Cache.watch_env(absolute, root, all_names, values, opts)
      end

      {:ok, resolved}
    end
  end

  # An explicit `:watch_env` always wins. Left unset, it defaults to
  # whether this exact load referenced the environment *at all* -- an
  # ordinary value, a guard, or both. A file that never touches `${...}`
  # has nothing for a poll to usefully report.
  defp watch_env?(opts, all_names) do
    case Keyword.fetch(opts, :watch_env) do
      {:ok, value} -> value
      :error -> MapSet.size(all_names) > 0
    end
  end

  defp read_file(path, absolute) do
    case File.read(absolute) do
      {:ok, source} ->
        {:ok, source}

      {:error, reason} ->
        {:error,
         Error.new(
           message: "could not read #{inspect(path)}: #{:file.format_error(reason)}",
           stage: :import
         )}
    end
  end

  @doc """
  Parses, expands loops, resolves imports, merges, and fully resolves
  `source` (a complete CASC file's own text, own version header
  included) -- the same pipeline `load_file/2` runs, for a source that
  isn't (yet, or ever) sitting in a real file. Imports using a bare
  (non-`scheme://`) path still need a real `:root` unless registered
  via `:import_schemes`.
  """
  @spec load_string(String.t(), opts()) :: {:ok, term()} | {:error, Error.t() | [Error.t()]}
  def load_string(source, opts \\ []) do
    with {:ok, env} <- Cooper.Dotenv.env(opts) do
      opts = Keyword.put(opts, :env, env)
      grammar_opts = Keyword.take(opts, [:root, :file, :import_schemes, :env])

      with {:ok, tree, vars} <- Cooper.Grammar.run_tree(source, grammar_opts),
           resolver_opts = [vars: vars] ++ Keyword.take(opts, [:env, :resolvers, :tags]) do
        Cooper.Resolver.resolve(tree, resolver_opts)
      end
    end
  end
end
