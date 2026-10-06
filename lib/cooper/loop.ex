defmodule Cooper.Loop do
  @moduledoc """
  Expands a parsed `for` statement (CASC.md §5.5) into the ops it
  generates.

  This sits at a genuine architectural seam: loop expansion runs
  *before* merge (`Cooper.Merge`) and general reference resolution
  (`Cooper.Resolver`), yet it structurally needs to know each element
  binding's *actual list* to know how many iterations to generate. The
  resolution here: a binding's iterable is resolved eagerly, but only
  against the current file's own local variable environment built so
  far (ordinary `@name = [...]` declarations threaded through
  `Cooper.Actions`' `ctx` as they're parsed) -- never against something
  that can only exist after merge. A `%{...}` config reference as an
  iterable is refused outright for exactly that reason (not a
  currently-missing feature, a structural impossibility at this stage).

  Once bindings are resolved, iteration proceeds like an ordinary
  bottom-up eval: for each iteration, a local overlay (`@idx`/`@domain`/
  `@port`/...) is substituted into the loop body's ops and the
  destination path -- and *only* those loop-bound names; any other
  reference (`@{outer_var}`, `%{...}`, `!{...}`, `!Name(...)`) is left
  untouched for `Cooper.Resolver`'s later resolution pass, matching
  CASC.md's own "loop-bound variables ... scoped to the body" framing.

  `from <template>` (CASC.md §5.5) stays a lazy `Cooper.Ref.Config`
  base at each generated destination, exactly like `Cooper.Merge`
  handles any other lazy config-ref base -- loop expansion never
  reads the template's value itself.
  """

  alias Ichor.Error

  @type binding :: {:index, String.t()} | {:element, String.t(), term()}

  @doc """
  `bindings` are as parsed by `Cooper.Actions`' own `handle_rule/3`
  clause for `:binding`; `from_template` is `nil` or a key-path segment
  list;
  `dest_segments` is `key_path`'s already-evaluated segment list
  (a segment may be a plain string or an unresolved
  `Cooper.Interp.Text`, per an interpolated destination like
  `"domain-@{idx}"`); `body` is the loop's `%Cooper.Block{}`;
  `outer_vars` is the enclosing file's variable environment so far
  (`name => {value, public?}`, matching `Cooper.Actions`' own `ctx.vars`
  shape -- `public?` is unused here, only `Cooper.Loader` cares about it).
  """
  @spec expand([binding()], [String.t()] | nil, [term()], boolean(), Cooper.Block.t(), map()) ::
          {:ok, list()} | {:error, Error.t()}
  def expand(
        bindings,
        from_template,
        dest_segments,
        dest_secret?,
        %Cooper.Block{ops: body_ops},
        outer_vars
      ) do
    with {:ok, element_bindings} <- validate_bindings(bindings),
         {:ok, resolved} <- resolve_iterables(element_bindings, outer_vars),
         {:ok, length} <- validate_lengths(resolved) do
      entries =
        for i <- 0..(length - 1)//1 do
          overlay = build_overlay(bindings, resolved, i)
          expand_iteration(overlay, from_template, dest_segments, dest_secret?, body_ops)
        end

      {:ok, List.flatten(entries)}
    end
  end

  defp validate_bindings(bindings) do
    element_bindings = for {:element, _name, _iter} = b <- bindings, do: b
    index_bindings = for {:index, _name} = b <- bindings, do: b

    cond do
      element_bindings == [] ->
        {:error,
         Error.new(
           message:
             "a `for` loop needs at least one element binding (`@name in ...`) -- index-only is not allowed",
           stage: :loop
         )}

      length(index_bindings) > 1 ->
        {:error,
         Error.new(
           message: "a `for` loop allows at most one index binding (`@name`)",
           stage: :loop
         )}

      true ->
        {:ok, element_bindings}
    end
  end

  defp resolve_iterables(element_bindings, outer_vars) do
    result =
      Enum.reduce_while(element_bindings, {:ok, []}, fn {:element, name, expr}, {:ok, acc} ->
        case resolve_iterable(expr, outer_vars) do
          {:ok, list} -> {:cont, {:ok, [{name, list} | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp resolve_iterable(list, _outer_vars) when is_list(list), do: {:ok, list}

  defp resolve_iterable(%Cooper.Ref.Var{name: name}, outer_vars) do
    case Map.fetch(outer_vars, name) do
      {:ok, {list, _public?}} when is_list(list) ->
        {:ok, list}

      {:ok, {_other, _public?}} ->
        {:error, Error.new(message: "loop iterable \"@{#{name}}\" is not a list", stage: :loop)}

      :error ->
        {:error,
         Error.new(
           message: "loop iterable references undefined variable \"@{#{name}}\"",
           stage: :loop
         )}
    end
  end

  defp resolve_iterable(%Cooper.Ref.Config{}, _outer_vars) do
    {:error,
     Error.new(
       message:
         "a `%{...}` config reference can't be used as a loop iterable -- it only resolves after the full tree is merged, which happens after loop expansion",
       stage: :loop
     )}
  end

  defp resolve_iterable(_other, _outer_vars) do
    {:error,
     Error.new(
       message: "loop iterable must be a list literal or a variable reference to one",
       stage: :loop
     )}
  end

  defp validate_lengths(resolved) do
    lengths = Enum.map(resolved, fn {name, list} -> {name, length(list)} end)
    distinct = lengths |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    case distinct do
      [len] ->
        {:ok, len}

      _ ->
        detail = Enum.map_join(lengths, ", ", fn {name, len} -> "@{#{name}} (#{len})" end)

        {:error,
         Error.new(
           message: "for loop's bound lists have mismatched lengths: #{detail}",
           stage: :loop
         )}
    end
  end

  defp build_overlay(bindings, resolved, i) do
    element_map = Map.new(resolved, fn {name, list} -> {name, Enum.at(list, i)} end)

    Enum.reduce(bindings, element_map, fn
      {:index, name}, acc -> Map.put(acc, name, i)
      {:element, _name, _iter}, acc -> acc
    end)
  end

  defp expand_iteration(overlay, from_template, dest_segments, dest_secret?, body_ops) do
    resolved_dest = substitute_path(dest_segments, overlay)

    base_entry =
      case from_template do
        nil ->
          []

        template_path ->
          op = %Cooper.Op{
            path: resolved_dest,
            sigil: :merge,
            value: %Cooper.Ref.Config{path: substitute_path(template_path, overlay)},
            secret?: dest_secret?
          }

          [{:op, op}]
      end

    body_entries =
      Enum.map(body_ops, fn
        {:op, op} ->
          {:op,
           %{
             op
             | path: resolved_dest ++ substitute_path(op.path, overlay),
               value: substitute(op.value, overlay),
               secret?: dest_secret? or op.secret?
           }}

        # A `~key { ... }` inside the body clears under *this
        # iteration's* destination, like every other entry it generated
        # -- passing it through untouched (as this once did) cleared the
        # top-level `key` instead, once per iteration.
        {:clear, path} ->
          {:clear, resolved_dest ++ substitute_path(path, overlay)}

        other ->
          other
      end)

    base_entry ++ body_entries
  end

  # A key segment that still interpolates something other than a loop
  # binding (`"@{stage}-@{id}"`, with `@stage` an ordinary variable) stays
  # a `Cooper.Interp.Text` -- `Cooper.Merge` resolves it against the
  # load's variables and environment like any other interpolated key,
  # rather than this being the error it once was.
  defp substitute_path(path, overlay), do: Enum.map(path, &substitute(&1, overlay))

  defp substitute(%Cooper.Ref.Var{name: name} = ref, overlay) when is_binary(name) do
    case Map.fetch(overlay, name) do
      {:ok, value} -> value
      :error -> substitute_parts(ref, overlay)
    end
  end

  # Everything inside a reference that a binding can reach: a built name
  # (`${"TOKEN_@{id}"}`, CASC.md 7.2 -- the binding substitutes into the
  # name, not for the reference as a whole, which is the entire point of
  # the form inside a loop), a `%{...}` path segment
  # (`%{tokens."supervisor-@{id}"}`), a `:default`/`:+alt`/`:?"msg"`
  # value, and a filter argument. Only built names were once reached, so
  # a binding anywhere else survived the loop unsubstituted and failed as
  # an undefined variable once the loop was gone.
  defp substitute(%Cooper.Ref.Var{} = ref, overlay), do: substitute_parts(ref, overlay)

  defp substitute(%Cooper.Ref.Env{} = ref, overlay) do
    %{
      ref
      | name: substitute(ref.name, overlay),
        suffix: substitute(ref.suffix, overlay),
        filters: substitute(ref.filters, overlay)
    }
  end

  defp substitute(%Cooper.Ref.Config{} = ref, overlay) do
    %{
      ref
      | path: substitute_path(ref.path, overlay),
        suffix: substitute(ref.suffix, overlay),
        filters: substitute(ref.filters, overlay)
    }
  end

  # A plain value joins the surrounding text now; anything else -- a
  # secret (whose redaction `Cooper.Resolver` applies to its own portion),
  # a still-unresolved reference, a list that cannot be text at all --
  # stays a segment of its own for `Cooper.Resolver` to resolve, redact,
  # or refuse with a proper error.
  defp substitute(%Cooper.Interp.Text{segments: segments}, overlay) do
    new_segments =
      Enum.map(segments, fn seg ->
        substituted = substitute(seg, overlay)
        if plain?(substituted), do: Cooper.Display.to_string(substituted), else: substituted
      end)

    if Enum.all?(new_segments, &is_binary/1) do
      Enum.join(new_segments)
    else
      %Cooper.Interp.Text{segments: new_segments}
    end
  end

  defp substitute(%Cooper.Ref.Tagged{arg: arg} = ref, overlay),
    do: %{ref | arg: substitute(arg, overlay)}

  defp substitute(list, overlay) when is_list(list), do: Enum.map(list, &substitute(&1, overlay))

  defp substitute(tuple, overlay) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&substitute(&1, overlay)) |> List.to_tuple()
  end

  defp substitute(other, _overlay), do: other

  defp substitute_parts(%Cooper.Ref.Var{} = ref, overlay) do
    %{
      ref
      | name: substitute(ref.name, overlay),
        suffix: substitute(ref.suffix, overlay),
        filters: substitute(ref.filters, overlay)
    }
  end

  @unresolved [
    Cooper.Ref.Var,
    Cooper.Ref.Env,
    Cooper.Ref.Config,
    Cooper.Ref.Resolver,
    Cooper.Ref.Tagged,
    Cooper.Interp.Text,
    Cooper.Merge.Layered,
    Cooper.Secret
  ]

  defp plain?(%module{}) when module in @unresolved, do: false
  defp plain?(value), do: Cooper.Display.displayable?(value)
end
