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
    @enforce_keys [:tree, :vars, :private_vars, :env, :resolvers, :tags]
    defstruct [
      :tree,
      :vars,
      # `%{scope => %{name => value}}` -- the private (`@*name`)
      # declarations of each file in the load, consulted only for a
      # reference stamped with that same scope. See `Cooper.Scope`.
      :private_vars,
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
      env_names: MapSet.new(),
      # Resolving an interpolated *key* (`resolve_key/2`) rather than a
      # value: only `@{...}`/`${...}` can be answered then, since keys are
      # resolved before the tree they belong to exists.
      keys_only: false
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
    "upcase" => &__MODULE__.tag_upcase/1,
    "module" => &__MODULE__.tag_module/1
  }

  # A module name this implementation accepts: dot-separated segments, each an
  # identifier. `!module` is deliberately the same tag in every Cooper
  # implementation while the shape it accepts is that implementation's own --
  # a port targeting another language defines its own pattern here and leaves
  # documents that name modules readable in both.
  @module_pattern ~r/^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/
  # What a built reference name is allowed to resolve to: the same
  # shape `casc.aether`'s own IDENT token accepts, so a built name and
  # a written-out one are interchangeable and nothing becomes reachable
  # by building it that could not have been written directly.
  @ref_name_pattern ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @max_module_bytes 512

  @doc """
  `opts`:
    * `:vars` -- the load's variable environment, either
      `{public, private_by_scope}` as `Cooper.Grammar.run_tree/2`
      returns it, or a plain `%{name => value}` map (treated as
      entirely public) for a hand-built tree. `public` is shared by
      every file in the load; `private_by_scope` is
      `%{scope => %{name => value}}` and is consulted only for a
      reference stamped with that same scope -- which is what keeps
      `@*name` file-local. See `Cooper.Scope`.
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
    {vars, private_vars} = split_var_env(Keyword.get(opts, :vars, %{}))

    state = %State{
      tree: tree,
      vars: vars,
      private_vars: private_vars,
      env: Keyword.get(opts, :env, System.get_env()),
      resolvers: Keyword.get(opts, :resolvers, %{}),
      tags: Map.merge(@built_in_tags, Keyword.get(opts, :tags, %{}))
    }

    case resolve_value(tree, state) do
      {:ok, resolved, state} -> {:ok, resolved, state.env_names}
      {:error, _} = err -> err
    end
  end

  @doc false
  # Resolves one interpolated key segment (`"region-@{name}" = ...`,
  # CASC.md §4.2) to the string it names, for `Cooper.Grammar` to apply
  # before merging -- keys decide the tree's shape, so they cannot wait
  # for the tree. That is also why only `@{...}` and `${...}` may appear
  # in one: a `%{...}` needs the finished tree, and a resolver or tag
  # would run before anything else in the load does. Follows the rules a
  # built `%{...}` key does (a string, non-empty, no `.`, never from a
  # secret). Returns every `${NAME}` it read, since that name now shapes
  # the tree and `Cooper.Cache` has to watch it like a guard.
  @spec resolve_key(Cooper.Interp.Text.t(), keyword()) ::
          {:ok, String.t(), MapSet.t()} | {:error, Error.t()}
  def resolve_key(%Cooper.Interp.Text{} = segment, opts) do
    {vars, private_vars} = split_var_env(Keyword.get(opts, :vars, %{}))

    state = %State{
      tree: %{},
      vars: vars,
      private_vars: private_vars,
      env: Keyword.get(opts, :env, System.get_env()),
      resolvers: %{},
      tags: %{},
      keys_only: true
    }

    case resolve_key_segment(segment, state, "interpolated key") do
      {:ok, key, state} -> {:ok, key, state.env_names}
      {:error, _} = err -> err
    end
  end

  # ---- generic value walker ------------------------------------------------

  defp resolve_value(%module{}, %State{keys_only: true})
       when module in [
              Cooper.Ref.Config,
              Cooper.Ref.Resolver,
              Cooper.Ref.Tagged,
              Cooper.Merge.Layered,
              Cooper.Merge.ListEdit
            ] do
    {:error,
     Error.new(
       message:
         "an interpolated key may only reference @{...} and ${...} -- it is resolved before the tree, resolvers, and tags it would need",
       stage: :resolve
     )}
  end

  defp resolve_value(%Cooper.Ref.Var{} = ref, state), do: resolve_var(ref, state)
  defp resolve_value(%Cooper.Ref.Env{} = ref, state), do: resolve_env(ref, state)
  defp resolve_value(%Cooper.Ref.Config{} = ref, state), do: resolve_config(ref, state)
  defp resolve_value(%Cooper.Ref.Resolver{} = ref, state), do: resolve_resolver(ref, state)
  defp resolve_value(%Cooper.Ref.Tagged{} = ref, state), do: resolve_tagged(ref, state)

  defp resolve_value(%Cooper.Interp.Text{segments: segments}, state),
    do: resolve_text(segments, state)

  defp resolve_value(%Cooper.Merge.Layered{} = layered, state),
    do: resolve_layered(layered, state)

  defp resolve_value(%Cooper.Merge.ListEdit{} = edit, state), do: resolve_list_edit(edit, state)

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
  defp resolve_var(%Cooper.Ref.Var{name: name} = ref, state) when not is_binary(name) do
    case resolve_ref_name(name, "@{...}", state) do
      {:ok, resolved, state} -> resolve_var(%{ref | name: resolved}, state)
      {:error, _} = err -> err
    end
  end

  # A loop binding's value attached to the reference (see `Cooper.Loop`):
  # resolved, then indexed, defaulted, and filtered like any other value.
  defp resolve_var(%Cooper.Ref.Var{bound: {:ok, value}} = ref, state) do
    with {:ok, resolved, state} <- resolve_value(value, state) do
      finish_ref(
        apply_index(resolved, ref.index),
        ref.suffix,
        ref.filters,
        "@{#{ref.name}}",
        state
      )
    end
  end

  defp resolve_var(
         %Cooper.Ref.Var{
           name: name,
           index: index,
           suffix: suffix,
           filters: filters,
           scope: scope
         },
         state
       ) do
    binding = {scope_of(state, name, scope), name}

    if binding in state.var_in_progress do
      {:error, var_cycle_error(state.var_in_progress, name)}
    else
      case fetch_var(state, name, scope) do
        {:ok, raw} ->
          state = %{state | var_in_progress: [binding | state.var_in_progress]}

          case resolve_value(raw, state) do
            {:ok, resolved, state} ->
              state = %{state | var_in_progress: List.delete(state.var_in_progress, binding)}
              finish_ref(apply_index(resolved, index), suffix, filters, "@{#{name}}", state)

            {:error, _} = err ->
              err
          end

        :error ->
          finish_ref(:error, suffix, filters, "@{#{name}}", state)
      end
    end
  end

  # A reference sees its own file's private (`@*name`) declarations
  # first, then the shared public environment -- so a private
  # declaration shadows a public one of the same name *inside its own
  # file only*, and is invisible everywhere else (CASC.md 5.2). A
  # reference with no scope at all (a `vars` map handed straight to
  # `resolve/2` rather than built by `Cooper.Grammar`) simply has no
  # private environment to consult.
  defp fetch_var(state, name, scope) do
    case private_fetch(state, name, scope) do
      {:ok, _} = found -> found
      :error -> Map.fetch(state.vars, name)
    end
  end

  defp private_fetch(_state, _name, nil), do: :error

  defp private_fetch(state, name, scope) do
    case Map.fetch(state.private_vars, scope) do
      {:ok, privates} -> Map.fetch(privates, name)
      :error -> :error
    end
  end

  # Which binding a name actually resolved to, so cycle detection
  # tracks *that* binding rather than the bare name -- two files may
  # each declare an unrelated `@*name`, and neither is a cycle in the
  # other.
  defp scope_of(state, name, scope) do
    case private_fetch(state, name, scope) do
      {:ok, _} -> scope
      :error -> :public
    end
  end

  # `Cooper.Grammar` hands over `{public, private_by_scope}`; a caller
  # resolving a hand-built tree may still pass a plain `%{name =>
  # value}` map, which is treated as entirely public.
  defp split_var_env({vars, private_vars}) when is_map(vars) and is_map(private_vars),
    do: {vars, private_vars}

  defp split_var_env(vars) when is_map(vars), do: {vars, %{}}

  defp var_cycle_error(var_in_progress, name) do
    chain = Enum.reverse(Enum.map(var_in_progress, &elem(&1, 1))) ++ [name]
    Error.new(message: "circular @{...} reference: #{Enum.join(chain, " -> ")}", stage: :resolve)
  end

  # ---- ${...} (eager, always a string on success) ---------------------------

  defp resolve_env(%Cooper.Ref.Env{name: name} = ref, state) when not is_binary(name) do
    case resolve_ref_name(name, "${...}", state) do
      {:ok, resolved, state} -> resolve_env(%{ref | name: resolved}, state)
      {:error, _} = err -> err
    end
  end

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

  # A reference's name may be built by interpolation (CASC.md 7.2) --
  # `${"TOKEN_@{id}"}`. The name is resolved to a string first, then
  # looked up exactly as a written-out name would be.
  #
  # Two things a *value* may be and a *name* may not. A name that
  # resolved to something not identifier-shaped is a mistake worth
  # naming rather than a lookup that quietly misses -- an interpolated
  # `@{id}` holding "1 2" would otherwise just come back unset. And a
  # secret must never *become* a name: names appear in error messages
  # and in `env_names` (which `Cooper.Cache` persists to decide what to
  # re-poll), neither of which redacts.
  defp resolve_ref_name(name, label, state) do
    case resolve_value(name, state) do
      {:ok, %Cooper.Secret{}, _state} ->
        {:error,
         Error.new(message: "#{label} name may not be built from a secret value", stage: :resolve)}

      {:ok, resolved, state} when is_binary(resolved) ->
        if Regex.match?(@ref_name_pattern, resolved) do
          {:ok, resolved, state}
        else
          {:error,
           Error.new(
             message: "#{label} resolved to #{inspect(resolved)}, which is not a valid name",
             stage: :resolve
           )}
        end

      {:ok, resolved, _state} ->
        {:error,
         Error.new(
           message: "#{label} name must resolve to a string, got: #{inspect(resolved)}",
           stage: :resolve
         )}

      {:error, _} = err ->
        err
    end
  end

  defp split_env_list(raw), do: raw |> String.split(~r/[,;]/) |> Enum.map(&String.trim/1)

  # ---- %{...} (lazy, memoized, cycle-checked against the final tree) --------

  # A path segment may itself be built by interpolation
  # (`%{tokens."supervisor-@{id}"}`) -- the parser has always produced
  # one for that form, but nothing resolved it, so the unresolved
  # struct reached `Enum.join/2` and crashed with a raw
  # `Protocol.UndefinedError` instead of either working or failing
  # cleanly. Resolve every segment to a string first, under the same
  # rules a built `${...}`/`@{...}` name follows.
  defp resolve_config(%Cooper.Ref.Config{path: path} = ref, state) do
    case resolve_path_segments(path, state) do
      {:ok, resolved, state} -> resolve_config_path(%{ref | path: resolved}, state)
      {:error, _} = err -> err
    end
  end

  # A key is not an identifier: `%{tokens."supervisor-1"}` is a
  # perfectly ordinary quoted key, so the identifier shape a built
  # `${...}`/`@{...}` *name* must have would reject legitimate paths
  # here. What a built key may not be is empty (it would silently
  # address the wrong depth), dotted (it would silently become two
  # segments rather than one), or a secret (same reason a name may not
  # be -- it lands in error messages unredacted).
  defp resolve_key_segment(segment, state, label \\ "%{...} key") do
    case resolve_value(segment, state) do
      {:ok, %Cooper.Secret{}, _state} ->
        {:error,
         Error.new(message: "#{label} may not be built from a secret value", stage: :resolve)}

      {:ok, "", _state} ->
        {:error, Error.new(message: "#{label} resolved to an empty string", stage: :resolve)}

      {:ok, resolved, state} when is_binary(resolved) ->
        if String.contains?(resolved, ".") do
          {:error,
           Error.new(
             message:
               "#{label} resolved to #{inspect(resolved)}, which would split into more than one path segment",
             stage: :resolve
           )}
        else
          {:ok, resolved, state}
        end

      {:ok, resolved, _state} ->
        {:error,
         Error.new(
           message: "#{label} must resolve to a string, got: #{inspect(resolved)}",
           stage: :resolve
         )}

      {:error, _} = err ->
        err
    end
  end

  defp resolve_path_segments(path, state) do
    Enum.reduce_while(path, {:ok, [], state}, fn
      segment, {:ok, acc, state} when is_binary(segment) ->
        {:cont, {:ok, [segment | acc], state}}

      segment, {:ok, acc, state} ->
        case resolve_key_segment(segment, state) do
          {:ok, resolved, state} -> {:cont, {:ok, [resolved | acc], state}}
          {:error, _} = err -> {:halt, err}
        end
    end)
    |> case do
      {:ok, acc, state} -> {:ok, Enum.reverse(acc), state}
      {:error, _} = err -> err
    end
  end

  defp resolve_config_path(
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

  # The overrides on top of a template's copy. A key marked
  # `Cooper.Merge.Absent` (`-key` in the loop body) is removed from the
  # copy; one with no base to apply to keeps its overrides, with any
  # `Absent` inside them dropped.
  defp deep_merge(base, %{} = overrides) when not is_struct(overrides) do
    from = if is_map(base) and not is_struct(base), do: base, else: %{}

    Enum.reduce(overrides, from, fn
      {key, %Cooper.Merge.Absent{}}, acc ->
        Map.delete(acc, key)

      {key, value}, acc ->
        merged =
          if Map.has_key?(from, key), do: deep_merge(from[key], value), else: strip_absent(value)

        Map.put(acc, key, merged)
    end)
  end

  defp deep_merge(_base, override), do: override

  defp strip_absent(%{} = value) when not is_struct(value), do: deep_merge(%{}, value)
  defp strip_absent(value), do: value

  # ---- Cooper.Merge.ListEdit (a `+key`/`-key` applied once it resolves) ------

  defp resolve_list_edit(%Cooper.Merge.ListEdit{} = edit, state) do
    mark = if edit.op == :append, do: "+", else: "-"
    label = "\"#{mark}#{Enum.join(edit.path, ".")}\""

    with {:ok, base, state} <- resolve_value(edit.base, state) do
      case base do
        # A template without this key: `+key` is a plain assignment,
        # `-key` leaves it absent.
        %Cooper.Merge.Absent{} when edit.op == :append ->
          resolve_value(edit.operand, state)

        %Cooper.Merge.Absent{} ->
          {:ok, base, state}

        _ ->
          {secret?, base} = unwrap_secret(base)
          apply_resolved_edit(edit, base, secret?, label, state)
      end
    end
  end

  defp apply_resolved_edit(_edit, base, _secret?, label, _state) when is_tuple(base) do
    {:error,
     Error.new(
       message:
         "#{label} targets a tuple -- tuples are never merged, only replaced wholesale (CASC.md §8.3)",
       stage: :resolve
     )}
  end

  defp apply_resolved_edit(_edit, base, _secret?, label, _state) when not is_list(base) do
    {:error,
     Error.new(
       message: "#{label} needs a list at that path, found #{inspect(base)}",
       stage: :resolve
     )}
  end

  defp apply_resolved_edit(edit, base, secret?, _label, state) do
    with {:ok, operand, state} <- resolve_value(edit.operand, state) do
      {operand_secret?, operand} = unwrap_secret(operand)
      items = Cooper.Merge.items(operand)

      result =
        case edit.op do
          :append -> base ++ items
          :remove -> Enum.reject(base, &(&1 in items))
        end

      if secret? or operand_secret?,
        do: {:ok, %Cooper.Secret{value: result}, state},
        else: {:ok, result, state}
    end
  end

  defp unwrap_secret(%Cooper.Secret{value: value}), do: {true, value}
  defp unwrap_secret(value), do: {false, value}

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
  def tag_module(arg) when is_binary(arg) do
    name = String.trim(arg)

    cond do
      byte_size(name) > @max_module_bytes ->
        {:error,
         "cannot convert #{inspect(arg)} to a module: longer than #{@max_module_bytes} bytes"}

      not Regex.match?(@module_pattern, name) ->
        {:error, "cannot convert #{inspect(arg)} to a module: not a dot-separated module name"}

      true ->
        {:ok, module_atom(name)}
    end
  end

  def tag_module(arg), do: {:error, "cannot convert #{inspect(arg)} to a module: not a string"}

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
  #
  # A secret is filtered through: the real string is filtered and the
  # result is a secret again (CASC.md §4.3 -- the stored value is
  # unaffected by being secret), the same way `!trim(%{pw})` already
  # behaved. Refusing it as "not a string", as this once did, made a
  # secret unfilterable.
  defp finish_ref(fetch, suffix, filters, label, state) do
    with {:ok, value, state} <- finish_ref(fetch, suffix, label, state) do
      {secret?, inner} =
        case value do
          %Cooper.Secret{value: inner} when filters != [] -> {true, inner}
          other -> {false, other}
        end

      case Cooper.RefCommon.apply_filters(inner, filters) do
        {:ok, filtered} when secret? -> {:ok, %Cooper.Secret{value: filtered}, state}
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
      {:required, message} -> required(message, state)
      nil -> {:error, Error.new(message: "undefined reference #{label}", stage: :resolve)}
    end
  end

  # The message of `:?"..."` is a double-quoted string like any other, so
  # it interpolates: `@{n:?"need @{m}"}` reports `need M`. Handing the
  # unresolved string to the error, as this once did, put a struct where
  # the message belongs. A secret in it shows redacted.
  defp required(message, state) do
    with {:ok, text, _state} <- resolve_value(message, state) do
      {:error, Error.new(message: Kernel.to_string(text), stage: :resolve)}
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

  # Builds the atom a module name denotes on this runtime.
  #
  # A name beginning with an upper-case letter is an Elixir module, which lives
  # under the `Elixir.` prefix; anything else is an Erlang module, whose atom is
  # the name itself. Both are ordinary atoms once built.
  #
  # This creates an atom, exactly as a bare atom literal does (CASC.md 6.4), and
  # carries the same caveat: fine for a fixed, trusted set of configuration
  # files, not for untrusted input.
  @spec module_atom(String.t()) :: module()
  defp module_atom(<<first::utf8, _rest::binary>> = name) when first in ?A..?Z,
    do: Module.concat([name])

  defp module_atom(name), do: String.to_atom(name)

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
              case Display.display(v) do
                {:ok, text} ->
                  {:cont, {:ok, [{text, r || "[~~REDACTED~~]"} | acc], true, state}}

                {:error, _} ->
                  # Named without the value itself: it is a secret.
                  {:halt,
                   {:error,
                    Error.new(
                      message: "cannot interpolate a secret list, map or tuple into a string",
                      stage: :resolve
                    )}}
              end

            {:ok, resolved, state} ->
              case Display.display(resolved) do
                {:ok, text} ->
                  {:cont, {:ok, [{text, text} | acc], secret_seen?, state}}

                {:error, message} ->
                  {:halt, {:error, Error.new(message: message, stage: :resolve)}}
              end

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
