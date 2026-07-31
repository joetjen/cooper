defmodule Cooper.Loader do
  @moduledoc """
  Resolves and loads a CASC.md §5.1 `import "..."` statement, called
  directly from `Cooper.Actions`' own `handle_rule/3` clause for
  `:import_statement` (not a separate, later pass) -- an import has to
  be resolved inline, at the point it's parsed, so that variables it
  brings in are visible
  to whatever *follows* it in the importing file, `for` loops included,
  exactly the way an ordinary `@name = ...` declaration already is.

  Two import forms:

    * A bare path -- resolves relative to `ctx.root` (the *current*
      file's own directory, not the original entry file's -- each
      file's own imports are always relative to itself). `**` (glob)
      and `{a,b}` (brace) patterns expand against the filesystem;
      matches load in lexicographic order.
    * A `scheme://` path -- dispatched to `ctx.import_schemes[scheme]`,
      the same map as `Cooper`'s own `:import_schemes` option. An
      unregistered scheme is a load-time error naming it.

  Each resolved file is a complete CASC file (own version header),
  recursively run through the *entire* pipeline (this module calls back
  into `Cooper.Grammar`'s own `run_with_context/3`) before its ops ever
  reach the importer. Import cycles (`ctx.importing`, a `MapSet` of
  already-in-progress absolute paths) are a load-time error naming the
  chain.
  """

  alias Ichor.Error

  @scheme_re ~r/^([a-zA-Z][a-zA-Z0-9+.\-]*):\/\/(.+)$/s

  @doc """
  `path` is the import statement's already-evaluated string (a load-time
  error if it isn't a plain string -- an import path can't contain an
  unresolved reference). Returns the imported file(s)' spliced-together
  op/var-decl entries and `ctx` with their *public* variables folded
  into `ctx.vars`, ready to hand straight back as `handle_rule/3`'s own
  `{:ok, entries, ctx}`.
  """
  @spec load_import(term(), map()) :: {:ok, list(), map()} | {:error, Error.t()}
  def load_import(path, ctx) when is_binary(path) do
    case Regex.run(@scheme_re, path) do
      [_, scheme, rest] -> load_scheme(scheme, rest, ctx)
      nil -> load_filesystem(path, ctx)
    end
  end

  def load_import(_non_string, _ctx) do
    {:error,
     Error.new(
       message: "import path must be a literal string with no unresolved references",
       stage: :import
     )}
  end

  defp load_scheme(scheme, rest, ctx) do
    case Map.fetch(ctx.import_schemes, scheme) do
      {:ok, loader} when is_function(loader, 1) ->
        case loader.(rest) do
          {:ok, source} ->
            load_source("#{scheme}://#{rest}", source, ctx)

          {:error, reason} ->
            {:error,
             Error.new(
               message: "#{scheme}:// loader failed for #{inspect(rest)}: #{inspect(reason)}",
               stage: :import
             )}
        end

      :error ->
        {:error,
         Error.new(message: "unregistered import scheme #{inspect(scheme)}", stage: :import)}
    end
  end

  defp load_filesystem(pattern, ctx) do
    with {:ok, files} <- resolve_filesystem_paths(pattern, ctx.root) do
      Enum.reduce_while(files, {:ok, [], ctx}, fn file, {:ok, acc, ctx} ->
        case load_file(file, ctx) do
          {:ok, entries, ctx} -> {:cont, {:ok, acc ++ entries, ctx}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp resolve_filesystem_paths(pattern, root) do
    files =
      pattern
      |> expand_braces()
      |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()
      |> Enum.sort()

    case files do
      [] ->
        {:error,
         Error.new(
           message: "import #{inspect(pattern)} matched no files (searched under #{root})",
           stage: :import
         )}

      files ->
        {:ok, files}
    end
  end

  defp load_file(file, ctx) do
    if MapSet.member?(ctx.importing, file) do
      chain = ctx.importing |> MapSet.to_list() |> Enum.sort() |> Enum.join(" -> ")
      {:error, Error.new(message: "import cycle detected: #{chain} -> #{file}", stage: :import)}
    else
      case File.read(file) do
        {:ok, source} ->
          load_source(file, source, %{ctx | loaded_files: MapSet.put(ctx.loaded_files, file)})

        {:error, reason} ->
          {:error,
           Error.new(
             message: "could not read import #{inspect(file)}: #{:file.format_error(reason)}",
             stage: :import
           )}
      end
    end
  end

  # A freshly-loaded file starts with an *empty* local `vars` (it
  # doesn't inherit the importer's own variables -- CASC.md §5.2 only
  # describes visibility flowing the other way, imported-file-to-
  # importer), but the *cycle-detection set*, `loaded_files`,
  # `import_schemes`, and `env` do carry forward (an imported file's own
  # `${?NAME}` guard -- CASC.md §7.2 -- reads `ctx.env` at parse time,
  # same as the entry file's; dropping it here previously crashed with
  # `KeyError` the first time an import used one), and `root` switches
  # to the newly loaded file's own directory (its own imports resolve
  # relative to itself, not the original entry file -- CASC.md §5.1).
  defp load_source(file, source, ctx) do
    sub_ctx = %{
      vars: %{},
      root: Path.dirname(file),
      import_schemes: ctx.import_schemes,
      importing: MapSet.put(ctx.importing, file),
      loaded_files: ctx.loaded_files,
      env: ctx.env,
      env_guard_names: MapSet.new()
    }

    case Cooper.Grammar.run_with_context(source, Cooper.Actions, sub_ctx) do
      {:ok, entries, result_ctx} ->
        ctx =
          ctx
          |> merge_public_vars(result_ctx.vars)
          |> merge_loaded_files(result_ctx.loaded_files)
          |> merge_env_guard_names(result_ctx.env_guard_names)

        {:ok, entries, ctx}

      {:error, _} = err ->
        err
    end
  end

  defp merge_public_vars(ctx, imported_vars) do
    public = for {name, {_value, true} = entry} <- imported_vars, into: %{}, do: {name, entry}
    update_in(ctx, [:vars], &Map.merge(&1, public))
  end

  # Unlike `importing`, deliberately *not* discarded when `load_source/3`
  # returns -- `result_ctx.loaded_files` (which a nested import may have
  # grown further) has to make it all the way back up to the top-level
  # caller, so `Cooper.Cache` can fingerprint every file that
  # contributed to the load, not just the entry file. A `scheme://`
  # source (`load_scheme/3`, above) never adds itself here -- there's no
  # real file to fingerprint for one, so its content simply isn't
  # independently freshness-tracked; a cached entry only refreshes it
  # when something file-backed in the same load also changes.
  defp merge_loaded_files(ctx, imported_files) do
    update_in(ctx, [:loaded_files], &MapSet.union(&1, imported_files))
  end

  # Same "only ever grows, propagates upward" treatment as
  # `merge_loaded_files/2` -- an imported file's own `${?NAME}` guard
  # names make the *whole* load's shape env-dependent, not just that
  # one file's.
  defp merge_env_guard_names(ctx, imported_guard_names) do
    update_in(ctx, [:env_guard_names], &MapSet.union(&1, imported_guard_names))
  end

  # Handles one brace group per pass, recursing on the substituted
  # result so multiple groups in the same pattern (`{a,b}/{x,y}`) all
  # expand -- `Path.wildcard/2` has no native brace support (only `*`/
  # `**`), so brace groups are expanded by hand before wildcarding.
  defp expand_braces(pattern) do
    case Regex.run(~r/^(.*?)\{([^{}]+)\}(.*)$/s, pattern) do
      [_, prefix, alternatives, suffix] ->
        alternatives
        |> String.split(",")
        |> Enum.flat_map(fn alt -> expand_braces(prefix <> alt <> suffix) end)

      nil ->
        [pattern]
    end
  end
end
