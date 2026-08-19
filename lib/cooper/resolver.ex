defmodule Cooper.Resolver do
  @moduledoc """
  Resolves everything `Cooper.Merge.assemble/1` left unresolved --
  `Cooper.Ref.Var` (`@{}`, eager), `Cooper.Ref.Env` (`${}`, eager),
  `Cooper.Ref.Config` (`%{}`, lazy against the *final* tree),
  `Cooper.Ref.Resolver` (`!{resolver:payload}`, dispatch), `Cooper.Ref.Tagged`
  (`!Name(arg)`, dispatch), and `Cooper.Merge.Layered` (a `for` loop's
  lazy `from` base with overrides on top, see `Cooper.Loop`).

  `@{}`/`${}` could in principle resolve *before* merge, "so no
  Ref.Var nodes remain by merge time" -- but this module does it the
  other way -- after merge, walking the assembled tree -- which is
  deliberate, not an oversight: `@{}`/`${}` never depend on the merged
  tree's own shape (only on the variable/env environment, independent
  of merge outcome), so resolving them before or after merge produces
  identical results. Doing it here, uniformly with `%{}`'s
  genuinely-must-be-lazy resolution, keeps one walker instead of two,
  and matches `Cooper.Grammar.run/2`'s own choice to leave
  `Cooper.Ref.*` nodes unresolved until this stage runs.

  `${?NAME}` (CASC.md §7.2's conditional statement skip) is explicitly
  *not* handled here -- it removes an entire op rather than resolving a
  value, so it's evaluated back in `Cooper.Actions`'
  `:conditional_statement` handler instead, before this module ever
  sees the statement. Backslash-continued strings (CASC.md §6.5) remain
  a genuine open gap -- see `test/SPEC_COVERAGE.md`.
  """

  alias Cooper.Display
  alias Ichor.Error

  defmodule State do
    @moduledoc false
    @enforce_keys [:tree, :vars, :env, :resolvers, :tags]
    defstruct [
      :tree,
      :vars,
      :env,
      :resolvers,
      :tags,
      cache: %{},
      in_progress: [],
      var_in_progress: [],
      # Every `${NAME}` this resolve actually looked up, found or not --
      # `Cooper.Cache`'s own env-change watching (`:watch_env`) uses
      # this to know which specific names a given load depends on,
      # rather than diffing the whole environment on every poll tick.
      env_names: MapSet.new()
    ]
  end

  @built_in_tags %{
    "int" => &__MODULE__.tag_int/1,
    "float" => &__MODULE__.tag_float/1,
    "bool" => &__MODULE__.tag_bool/1,
    "duration" => &__MODULE__.tag_duration/1,
    "bytes" => &__MODULE__.tag_bytes/1,
    "trim" => &__MODULE__.tag_trim/1,
    "downcase" => &__MODULE__.tag_downcase/1,
    "upcase" => &__MODULE__.tag_upcase/1
  }

  @doc """
  `opts`:
    * `:vars` -- `%{name => value}`, the file's own resolved variable
      environment (`Cooper.Grammar.run_tree/2` builds this from
      `Cooper.Actions`' `ctx.vars`, already public/private-filtered by
      `Cooper.Loader` across imports).
    * `:env` -- `%{name => value}`, defaults to `System.get_env/0`.
    * `:resolvers` -- `%{name => (payload :: String.t() -> {:ok, term()}
      | {:error, term()})}`, for `!{resolver:payload}` (CASC.md §7.4/§9.2).
    * `:tags` -- same shape, for `!Name(arg)` beyond the five built-ins
      (`int`/`float`/`bool`/`duration`/`bytes`/`trim`/`downcase`/
      `upcase`, CASC.md §7.5/§9.1).
  """
  @spec resolve(term(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def resolve(tree, opts \\ []) do
    with {:ok, resolved, _env_names} <- resolve_with_env_names(tree, opts) do
      {:ok, resolved}
    end
  end

  # Like resolve/2, but also returns every `${NAME}` the resolve
  # actually looked up -- see `State.env_names`'s own comment for why.
  @doc false
  @spec resolve_with_env_names(term(), keyword()) ::
          {:ok, term(), MapSet.t()} | {:error, Error.t()}
  def resolve_with_env_names(tree, opts \\ []) do
    state = %State{
      tree: tree,
      vars: Keyword.get(opts, :vars, %{}),
      env: Keyword.get(opts, :env, System.get_env()),
      resolvers: Keyword.get(opts, :resolvers, %{}),
      tags: Map.merge(@built_in_tags, Keyword.get(opts, :tags, %{}))
    }

    case resolve_value(tree, state) do
      {:ok, resolved, state} -> {:ok, resolved, state.env_names}
      {:error, _} = err -> err
    end
  end

  # ---- generic value walker ------------------------------------------------

  defp resolve_value(%Cooper.Ref.Var{} = ref, state), do: resolve_var(ref, state)
  defp resolve_value(%Cooper.Ref.Env{} = ref, state), do: resolve_env(ref, state)
  defp resolve_value(%Cooper.Ref.Config{} = ref, state), do: resolve_config(ref, state)
  defp resolve_value(%Cooper.Ref.Resolver{} = ref, state), do: resolve_resolver(ref, state)
  defp resolve_value(%Cooper.Ref.Tagged{} = ref, state), do: resolve_tagged(ref, state)

  defp resolve_value(%Cooper.Interp.Text{segments: segments}, state),
    do: resolve_text(segments, state)

  defp resolve_value(%Cooper.Merge.Layered{} = layered, state),
    do: resolve_layered(layered, state)

  # A `Cooper.Merge`-wrapped secret's own inner value may still be
  # unresolved (`*password = ${DB_PASSWORD}`, an unresolved
  # `Cooper.Ref.Env`, is exactly as legal as a plain literal) -- resolve
  # it here and re-wrap, so the secrecy travels with wherever the value
  # ends up (a `%{...}` copy, a loop `from` base) instead of only
  # protecting its original declared path. If resolving the inner value
  # itself produces another `Cooper.Secret` (e.g. the whole field was
  # `*`-marked *and* interpolates another already-secret value), the
  # two collapse into one rather than double-wrapping -- an explicit
  # `*` on the outer field means "redact this whole thing," so the
  # blanket marker wins over any inner partial-redaction text.
  defp resolve_value(%Cooper.Secret{value: v}, state) do
    with {:ok, resolved, state} <- resolve_value(v, state) do
      case resolved do
        %Cooper.Secret{value: inner} -> {:ok, %Cooper.Secret{value: inner}, state}
        other -> {:ok, %Cooper.Secret{value: other}, state}
      end
    end
  end

  defp resolve_value(%{} = map, state) when not is_struct(map) do
    Enum.reduce_while(map, {:ok, %{}, state}, fn {k, v}, {:ok, acc, state} ->
      case resolve_value(v, state) do
        {:ok, resolved, state} -> {:cont, {:ok, Map.put(acc, k, resolved), state}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp resolve_value(list, state) when is_list(list) do
    result =
      Enum.reduce_while(list, {:ok, [], state}, fn item, {:ok, acc, state} ->
        case resolve_value(item, state) do
          {:ok, resolved, state} -> {:cont, {:ok, [resolved | acc], state}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, acc, state} -> {:ok, Enum.reverse(acc), state}
      err -> err
    end
  end

  defp resolve_value(tuple, state) when is_tuple(tuple) do
    case resolve_value(Tuple.to_list(tuple), state) do
      {:ok, list, state} -> {:ok, List.to_tuple(list), state}
      err -> err
    end
  end

  defp resolve_value(other, state), do: {:ok, other, state}

  # ---- @{...} (eager) -------------------------------------------------------

  # A variable's own declared value can itself be an unresolved ref
  # (`@region = ${REGION:"eu-west"}` is ordinary CASC.md §5.2/§7 syntax --
  # nothing restricts a variable's RHS to a literal), so it has to be
  # resolved here, not just looked up, before `@{region}` can substitute
  # a real value rather than the raw %Cooper.Ref.Env{} struct itself.
  # `var_in_progress` guards this recursion against a genuine `@a =
  # @{a}` (direct or transitive) cycle the same way `resolve_path/2`
  # guards `%{...}` -- without it, resolving one var could recurse
  # forever instead of failing with a clean, named error.
  defp resolve_var(
         %Cooper.Ref.Var{name: name, index: index, suffix: suffix, filters: filters},
         state
       ) do
    if name in state.var_in_progress do
      {:error, var_cycle_error(state.var_in_progress, name)}
    else
      case Map.fetch(state.vars, name) do
        {:ok, raw} ->
          state = %{state | var_in_progress: [name | state.var_in_progress]}

          case resolve_value(raw, state) do
            {:ok, resolved, state} ->
              state = %{state | var_in_progress: List.delete(state.var_in_progress, name)}
              finish_ref(apply_index(resolved, index), suffix, filters, "@{#{name}}", state)

            {:error, _} = err ->
              err
          end

        :error ->
          finish_ref(:error, suffix, filters, "@{#{name}}", state)
      end
    end
  end

  defp var_cycle_error(var_in_progress, name) do
    chain = Enum.reverse(var_in_progress) ++ [name]
    Error.new(message: "circular @{...} reference: #{Enum.join(chain, " -> ")}", stage: :resolve)
  end

  # ---- ${...} (eager, always a string on success) ---------------------------

  defp resolve_env(
         %Cooper.Ref.Env{
           name: name,
           index: index,
           list?: list?,
           suffix: suffix,
           filters: filters
         },
         state
       ) do
    fetch =
      case Map.fetch(state.env, name) do
        {:ok, raw} when raw != "" ->
          cond do
            list? -> {:ok, split_env_list(raw)}
            index != nil -> apply_index(split_env_list(raw), index)
            true -> {:ok, raw}
          end

        _ ->
          :error
      end

    state = %{state | env_names: MapSet.put(state.env_names, name)}
    finish_ref(fetch, suffix, filters, "${#{name}}", state)
  end

  defp split_env_list(raw), do: raw |> String.split(~r/[,;]/) |> Enum.map(&String.trim/1)

  # ---- %{...} (lazy, memoized, cycle-checked against the final tree) --------

  defp resolve_config(
         %Cooper.Ref.Config{path: path, index: index, suffix: suffix, filters: filters},
         state
       ) do
    label = "%{#{Enum.join(path, ".")}}"

    case resolve_path(path, state) do
      {:ok, value, state} -> finish_ref(apply_index(value, index), suffix, filters, label, state)
      {:error, :not_found} -> finish_ref(:error, suffix, filters, label, state)
      {:error, _} = err -> err
    end
  end

  # Memoized recursive descent: `path`'s value, resolving it first (and
  # caching the result) if this is the first time it's been reached.
  # `in_progress` is an ordered list (not a MapSet) specifically so a
  # detected cycle can be reported in actual traversal order.
  defp resolve_path(path, state) do
    case Map.fetch(state.cache, path) do
      {:ok, value} ->
        {:ok, value, state}

      :error ->
        if path in state.in_progress do
          {:error, cycle_error(state.in_progress, path)}
        else
          with {:ok, raw, state} <- fetch_tree_path(state.tree, path, state) do
            state = %{state | in_progress: [path | state.in_progress]}

            with {:ok, resolved, state} <- resolve_value(raw, state) do
              state = %{
                state
                | in_progress: List.delete(state.in_progress, path),
                  cache: Map.put(state.cache, path, resolved)
              }

              {:ok, resolved, state}
            end
          end
        end
    end
  end

  # A path may run straight through a `Cooper.Merge.Layered` value (a
  # for-loop's lazy `from` base) -- resolving that node fully (itself
  # possibly recursing through more of this same machinery) before
  # continuing to walk the rest of the path into it.
  defp fetch_tree_path(tree, [], state), do: {:ok, tree, state}

  defp fetch_tree_path(%Cooper.Merge.Layered{} = layered, path, state) do
    case resolve_layered(layered, state) do
      {:ok, resolved, state} -> fetch_tree_path(resolved, path, state)
      {:error, _} = err -> err
    end
  end

  defp fetch_tree_path(tree, [seg | rest], state) when is_map(tree) and not is_struct(tree) do
    case Map.fetch(tree, seg) do
      {:ok, v} -> fetch_tree_path(v, rest, state)
      :error -> {:error, :not_found}
    end
  end

  defp fetch_tree_path(_other, _path, _state), do: {:error, :not_found}

  defp cycle_error(in_progress, path) do
    chain = (Enum.reverse(in_progress) ++ [path]) |> Enum.map(&Enum.join(&1, "."))
    Error.new(message: "circular %{...} reference: #{Enum.join(chain, " -> ")}", stage: :resolve)
  end

  # ---- Cooper.Merge.Layered (a for-loop's lazy `from` base + overrides) -----

  defp resolve_layered(%Cooper.Merge.Layered{base: base, overrides: overrides}, state) do
    with {:ok, base_value, state} <- resolve_value(base, state),
         {:ok, overrides_value, state} <- resolve_value(overrides, state) do
      {:ok, deep_merge(base_value, overrides_value), state}
    end
  end

  defp deep_merge(%{} = base, %{} = overrides)
       when not is_struct(base) and not is_struct(overrides) do
    Map.merge(base, overrides, fn _k, base_v, override_v -> deep_merge(base_v, override_v) end)
  end

  defp deep_merge(_base, override), do: override

  # ---- !{resolver:payload} dispatch (CASC.md §7.4/§9.2) ---------------------

  defp resolve_resolver(%Cooper.Ref.Resolver{name: name, payload: payload}, state) do
    case Map.fetch(state.resolvers, name) do
      {:ok, fun} when is_function(fun, 1) ->
        case fun.(payload) do
          {:ok, value} ->
            {:ok, value, state}

          {:error, reason} ->
            {:error,
             Error.new(
               message:
                 "resolver #{inspect(name)} failed for payload #{inspect(payload)}: #{inspect(reason)}",
               stage: :resolve
             )}
        end

      :error ->
        {:error, Error.new(message: "unregistered resolver #{inspect(name)}", stage: :resolve)}
    end
  end

  # ---- !Name(arg) dispatch (CASC.md §7.5/§9.1) -------------------------------

  defp resolve_tagged(%Cooper.Ref.Tagged{name: name, arg: arg}, state) do
    with {:ok, resolved_arg, state} <- resolve_value(arg, state) do
      case Map.fetch(state.tags, name) do
        {:ok, fun} when is_function(fun, 1) -> apply_tag(fun, name, resolved_arg, state)
        :error -> {:error, Error.new(message: "unregistered tag !#{name}(...)", stage: :resolve)}
      end
    end
  end

  # A secret-sourced argument (`!int(%{database.secret_port})`) is
  # unwrapped for the tag function -- it has no way to handle a
  # `Cooper.Secret` struct itself -- and the *result* re-wrapped, so a
  # value derived from a secret is still a secret, not a plain one that
  # happens to have been computed from sensitive input.
  defp apply_tag(fun, name, %Cooper.Secret{value: inner}, state) do
    case apply_tag(fun, name, inner, state) do
      {:ok, value, state} -> {:ok, %Cooper.Secret{value: value}, state}
      err -> err
    end
  end

  defp apply_tag(fun, name, arg, state) do
    case fun.(arg) do
      {:ok, value} ->
        {:ok, value, state}

      {:error, reason} ->
        {:error, Error.new(message: "!#{name}(...) failed: #{reason}", stage: :resolve)}
    end
  end

  # The three string-normalizing tags below take no parameter, which is what
  # lets them fit `!Name(argument)`'s single-argument shape. A transform that
  # needs one -- stripping a specific suffix, say -- is a filter instead
  # (CASC.md §7.2), because the parameter has nowhere to go here.
  @doc false
  def tag_trim(arg) when is_binary(arg), do: {:ok, String.trim(arg)}
  def tag_trim(arg), do: {:error, "cannot trim #{inspect(arg)}: not a string"}

  @doc false
  def tag_downcase(arg) when is_binary(arg), do: {:ok, String.downcase(arg)}
  def tag_downcase(arg), do: {:error, "cannot downcase #{inspect(arg)}: not a string"}

  @doc false
  def tag_upcase(arg) when is_binary(arg), do: {:ok, String.upcase(arg)}
  def tag_upcase(arg), do: {:error, "cannot upcase #{inspect(arg)}: not a string"}

  @doc false
  def tag_int(arg) when is_integer(arg), do: {:ok, arg}

  def tag_int(arg) when is_binary(arg) do
    case Integer.parse(String.trim(arg)) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "not an integer: #{inspect(arg)}"}
    end
  end

  def tag_int(arg), do: {:error, "cannot convert #{inspect(arg)} to an integer"}

  @doc false
  def tag_float(arg) when is_float(arg), do: {:ok, arg}
  def tag_float(arg) when is_integer(arg), do: {:ok, arg * 1.0}

  def tag_float(arg) when is_binary(arg) do
    trimmed = String.trim(arg)

    case Float.parse(trimmed) do
      {f, ""} ->
        {:ok, f}

      _ ->
        case Integer.parse(trimmed) do
          {i, ""} -> {:ok, i * 1.0}
          _ -> {:error, "not a float: #{inspect(arg)}"}
        end
    end
  end

  def tag_float(arg), do: {:error, "cannot convert #{inspect(arg)} to a float"}

  @doc false
  def tag_bool(arg) when is_boolean(arg), do: {:ok, arg}
  def tag_bool("true"), do: {:ok, true}
  def tag_bool("false"), do: {:ok, false}
  def tag_bool(arg), do: {:error, "not a boolean: #{inspect(arg)}"}

  @doc false
  def tag_duration(arg) when is_binary(arg) do
    case Cooper.Literals.parse_duration(arg) do
      {:ok, ns} -> {:ok, {:duration, ns}}
      {:error, message} -> {:error, message}
    end
  end

  def tag_duration(arg), do: {:error, "cannot convert #{inspect(arg)} to a duration"}

  @doc false
  def tag_bytes(arg) when is_binary(arg) do
    case Cooper.Literals.parse_bytes(arg) do
      {:ok, bytes} -> {:ok, {:bytes, bytes}}
      {:error, message} -> {:error, message}
    end
  end

  def tag_bytes(arg), do: {:error, "cannot convert #{inspect(arg)} to a byte size"}

  # ---- shared default/substitute/required suffix handling -------------------
  # (CASC.md §7.2's own note: the same three-way suffix grammar applies
  # identically across @{}/${}/%{}.)

  # Filters run *after* the suffix has settled what the value is, so a
  # `${NAME:default | trim}` filters whichever of the two it ended up with.
  # Filtering before that would mean transforming a value you might not have.
  defp finish_ref(fetch, suffix, filters, label, state) do
    with {:ok, value, state} <- finish_ref(fetch, suffix, label, state) do
      case Cooper.RefCommon.apply_filters(value, filters) do
        {:ok, filtered} -> {:ok, filtered, state}
        {:error, message} -> {:error, Error.new(message: "#{label}: #{message}", stage: :resolve)}
      end
    end
  end

  defp finish_ref({:ok, value}, suffix, _label, state) do
    case suffix do
      {:substitute, alt} -> resolve_value(alt, state)
      _ -> {:ok, value, state}
    end
  end

  defp finish_ref(:error, suffix, label, state) do
    case suffix do
      {:default, default} -> resolve_value(default, state)
      {:substitute, _alt} -> {:ok, "", state}
      {:required, message} -> {:error, Error.new(message: message, stage: :resolve)}
      nil -> {:error, Error.new(message: "undefined reference #{label}", stage: :resolve)}
    end
  end

  defp apply_index(value, nil), do: {:ok, value}

  defp apply_index(value, i) when is_list(value) do
    case Enum.fetch(value, i) do
      {:ok, item} -> {:ok, item}
      :error -> :error
    end
  end

  # A secret-wrapped list (`*items = [...]`, indexed via `%{items[i]}`/
  # `@{items[i]}`) is unwrapped to index into, and the *element* re-wrapped
  # -- same reasoning as `apply_tag/4` above: a value reached through a
  # secret stays a secret.
  defp apply_index(%Cooper.Secret{value: inner}, i) do
    case apply_index(inner, i) do
      {:ok, item} -> {:ok, %Cooper.Secret{value: item}}
      :error -> :error
    end
  end

  defp apply_index(_value, _i), do: :error

  # ---- Cooper.Interp.Text (string interpolation, CASC.md §7) ----------------

  # Each segment contributes two parallel strings: what it really is,
  # and what it should *display* as. For an ordinary segment those are
  # identical; for a segment that resolved to a `Cooper.Secret`, the
  # real text is `Display.to_string/1` of the secret's own unwrapped
  # value, and the display text is its `:redacted` text (or the blanket
  # marker, for a plain whole-value secret) -- so only the sensitive
  # *portion* of the final string is ever redacted, not the whole
  # thing, and a string with several secrets interpolated into it
  # redacts each independently at its own position rather than
  # collapsing the entire result into one opaque marker.
  defp resolve_text(segments, state) do
    result =
      Enum.reduce_while(segments, {:ok, [], false, state}, fn
        seg, {:ok, acc, secret_seen?, state} ->
          case resolve_value(seg, state) do
            {:ok, %Cooper.Secret{value: v, redacted: r}, state} ->
              pair = {Display.to_string(v), r || "[~~REDACTED~~]"}
              {:cont, {:ok, [pair | acc], true, state}}

            {:ok, resolved, state} ->
              text = Display.to_string(resolved)
              {:cont, {:ok, [{text, text} | acc], secret_seen?, state}}

            {:error, _} = err ->
              {:halt, err}
          end
      end)

    case result do
      {:ok, acc, secret_seen?, state} ->
        pairs = Enum.reverse(acc)
        real = pairs |> Enum.map(&elem(&1, 0)) |> Enum.join()

        value =
          if secret_seen? do
            redacted = pairs |> Enum.map(&elem(&1, 1)) |> Enum.join()
            %Cooper.Secret{value: real, redacted: redacted}
          else
            real
          end

        {:ok, value, state}

      err ->
        err
    end
  end
end
