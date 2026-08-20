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
  `path` is the import statement's already-evaluated string, or an
  interpolated string whose references are all `${NAME}`/`${NAME:default}`
  -- those resolve from `ctx.env`, which is available while parsing. A
  reference needing the finished tree (`%{...}`) cannot be, since an
  import is resolved as the file is parsed, and is a load-time error. Returns the imported file(s)' spliced-together
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

  def load_import(%Cooper.Interp.Text{segments: segments}, ctx) do
    case interpolate_path(segments, ctx, []) do
      {:ok, path} -> load_import(path, ctx)
      {:error, error} -> {:error, error}
    end
  end

  def load_import(_non_string, _ctx) do
    {:error,
     Error.new(
       message:
         "import path must be a string, or a string interpolating only #{inspect("${NAME}")} references",
       stage: :import
     )}
  end

  # Builds an import path from an interpolated string, at parse time.
  #
  # Only `${NAME}` and `${NAME:default}` are permitted. Imports are resolved
  # while parsing -- an imported file's entries are spliced into the importer --
  # so anything needing the finished tree (`%{...}`) or the importer's own
  # variables cannot be available yet. `${...}` can: `ctx.env` is already
  # present at this point, which is what a `${?NAME}` guard reads too.
  @spec interpolate_path(list(), map(), [String.t()]) :: {:ok, String.t()} | {:error, Error.t()}
  defp interpolate_path([], _ctx, acc), do: {:ok, acc |> Enum.reverse() |> Enum.join()}

  defp interpolate_path([segment | rest], ctx, acc) when is_binary(segment) do
    interpolate_path(rest, ctx, [segment | acc])
  end

  defp interpolate_path(
         [%Cooper.Ref.Env{index: nil, list?: false, filters: []} = ref | rest],
         ctx,
         acc
       ) do
    case import_env_value(ref, ctx) do
      {:ok, value} -> interpolate_path(rest, ctx, [value | acc])
      {:error, error} -> {:error, error}
    end
  end

  defp interpolate_path([unsupported | _rest], _ctx, _acc) do
    {:error,
     Error.new(
       message:
         "an import path may interpolate only #{inspect("${NAME}")} or #{inspect("${NAME:default}")}, got: #{inspect(unsupported)}",
       stage: :import
     )}
  end

  # Reads one environment reference for an import path.
  #
  # Unset and empty are treated alike, matching `${NAME:default}` everywhere
  # else (CASC.md 7.2). Without a default, an absent variable is an error: a
  # path that silently became `".casc"` would import the wrong file or none.
  @spec import_env_value(Cooper.Ref.Env.t(), map()) :: {:ok, String.t()} | {:error, Error.t()}
  defp import_env_value(%Cooper.Ref.Env{name: name, suffix: suffix}, ctx) do
    case Map.get(ctx.env, name) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _unset_or_empty ->
        case suffix do
          {:default, default} ->
            {:ok, to_string(default)}

          _none ->
            {:error,
             Error.new(
               message:
                 "import path references #{inspect(name)}, which is unset and has no default",
               stage: :import
             )}
        end
    end
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

  # A freshly-loaded file starts with an *empty* local `vars`: nothing
  # is inherited at *parse* time. That is not the same as the
  # importer's variables being invisible to it -- a public `@name` is
  # visible in both directions (CASC.md §5.2), but that visibility is
  # applied at *resolve* time, against the one shared environment every
  # file's public declarations merge into, not by seeding this map.
  # Parse-time consumers (`Cooper.Loop`'s iteration count, `${?NAME}`
  # guards) are the only things that read `vars` here, and neither may
  # depend on a variable declared in another file. `private_vars` is
  # likewise empty: privates are collected per file on the way back up
  # (`merge_private_vars/3`) and never seed anything. The
  # *cycle-detection set*, `loaded_files`,
  # `import_schemes`, and `env` do carry forward (an imported file's own
  # `${?NAME}` guard -- CASC.md §7.2 -- reads `ctx.env` at parse time,
  # same as the entry file's; dropping it here previously crashed with
  # `KeyError` the first time an import used one), and `root` switches
  # to the newly loaded file's own directory (its own imports resolve
  # relative to itself, not the original entry file -- CASC.md §5.1).
  defp load_source(file, source, ctx) do
    sub_ctx = %{
      vars: %{},
      private_vars: %{},
      scope: Cooper.Scope.id(file),
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
          |> merge_private_vars(sub_ctx.scope, result_ctx)
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

  # The imported file's own private (`@*name`) declarations, filed
  # under *its* scope, plus any its own nested imports contributed
  # under theirs. This is deliberately not the mirror of
  # `merge_public_vars/2`: nothing here ever becomes visible to another
  # file, it only travels up so the single `Cooper.Resolver` pass at
  # the end can still resolve each file's own references against the
  # file that wrote them (CASC.md 5.2). Without it an imported file
  # could declare `@*name` and then fail to resolve its own `@{name}`.
  defp merge_private_vars(ctx, scope, result_ctx) do
    {_public, private} = Cooper.Scope.split(result_ctx.vars)

    nested = Map.merge(ctx.private_vars, result_ctx.private_vars)

    private_vars =
      if private == %{}, do: nested, else: Map.put(nested, scope, private)

    %{ctx | private_vars: private_vars}
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
