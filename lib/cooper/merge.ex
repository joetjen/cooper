defmodule Cooper.Merge do
  @moduledoc """
  Folds the flattened op/var-decl/clear-scope entries `Cooper.Actions`
  (and `Cooper.Loader`, for imports) produce into (almost) the final
  tree -- CASC.md §8/§5.7. "Almost": leaf values may still be unresolved
  `Cooper.Ref.*` nodes or `Cooper.Merge.Layered` values (a lazy
  `for`-loop base with overrides on top) -- `Cooper.Resolver` walks
  this next.

  Each op's own `:sigil` field (see `Cooper.Op`) decides how it combines
  with whatever's already at its `path`:

    * `:merge` -- CASC.md §8.1's default for a plain assignment. Deep-merge
      "emerges" for free from folding multiple ops at different sub-paths
      under the same parent; a single op just sets its own leaf.
    * `:replace` (`~key { ... }`) -- CASC.md §8.4: every leaf op a `~`
      block flattens to arrives pre-tagged `:replace`, but *only* deleting
      each leaf's own path wouldn't drop sibling keys the new block never
      mentions (`~server { port = 9090 }` needs `host` gone, not just
      `port` set). `Cooper.Actions` emits one `{:clear, path}` entry at
      the *statement's own* path before a `~` block's leaves, and this
      module deletes that whole subtree there, once, before folding the
      leaves in as ordinary overrides.
    * `:append` / `:remove` (`+key`/`-key`) -- CASC.md §8.4: list-only:
      concatenate, or `Enum.reject/2` by value equality. A tuple at that
      path (CASC.md §8.3: "fixed arity ... never merged, only replaced
      wholesale") is a hard error, not a silent no-op or coercion; same
      for `~`'s clear step landing on an existing tuple (a `~key { ... }`
      block replace only makes sense where a map/block belongs).
    * `:delete` (bare `-key.path`) -- removes the path outright, any type.
  """

  alias Ichor.Error

  @doc """
  `entries` is exactly what `Cooper.Actions`' `:file`/`:block` handlers
  (and `Cooper.Loader`) produce: `{:op, %Cooper.Op{}}`, `{:var, ...}`
  (ignored here -- `Cooper.Resolver`/`Cooper.Loader` territory), and
  `{:clear, path}`.

  Every path whose *final* value is secret (CASC.md §4.3's "a later
  op's secret? wins over an earlier one at the same path", inferred,
  not stated explicitly) is wrapped in `Cooper.Secret` here, before
  `Cooper.Resolver` ever sees the tree -- deliberately *not* deferred
  to a final path-based pass over the *resolved* result the way an
  earlier version of this pipeline did it. That earlier approach only
  protected a secret at the exact path it was declared at: a `%{...}`
  reference or a `for ... from` template copying that same value to a
  *different* path (neither tracked in any static "secret paths" set,
  since both only exist once `Cooper.Resolver` runs) copied the raw,
  unwrapped value right along with it -- a real leak. Wrapping here
  instead means the secrecy travels *with the value itself* through
  every later copy, since `Cooper.Resolver` re-wraps whatever a
  `%Cooper.Secret{}`'s own inner value resolves to rather than
  stripping the wrapper.
  """
  @spec assemble(list()) :: {:ok, map()} | {:error, Error.t()}
  def assemble(entries) do
    case Enum.reduce_while(entries, {:ok, %{}, MapSet.new()}, fn entry, {:ok, tree, secrets} ->
           case apply_entry(entry, tree, secrets) do
             {:ok, tree, secrets} -> {:cont, {:ok, tree, secrets}}
             {:error, _} = err -> {:halt, err}
           end
         end) do
      {:ok, tree, secrets} -> {:ok, wrap_secrets(tree, secrets, [])}
      {:error, _} = err -> err
    end
  end

  # Only descends into plain maps -- a secret path is always a map-key
  # chain (`Cooper.Op.path`, never a list or tuple index), and once a
  # path *is* secret its entire value -- list, tuple, nested map,
  # whatever it turns out to be -- gets wrapped as one unit rather than
  # descending further to redact only part of it.
  defp wrap_secrets(value, secrets, path) do
    if MapSet.member?(secrets, path) do
      %Cooper.Secret{value: value}
    else
      case value do
        %{} = map when not is_struct(map) ->
          Map.new(map, fn {k, v} -> {k, wrap_secrets(v, secrets, path ++ [k])} end)

        other ->
          other
      end
    end
  end

  defp apply_entry({:var, _decl}, tree, secrets), do: {:ok, tree, secrets}

  defp apply_entry({:clear, path}, tree, secrets) do
    case get_at(tree, path) do
      {:ok, existing} when is_tuple(existing) ->
        {:error, tuple_guard_error(path, "~")}

      _ ->
        {:ok, delete_path(tree, path), secrets}
    end
  end

  defp apply_entry({:op, %Cooper.Op{sigil: :merge} = op}, tree, secrets) do
    {:ok, put_at(tree, op.path, op.value), track_secret(secrets, op)}
  end

  defp apply_entry({:op, %Cooper.Op{sigil: :replace} = op}, tree, secrets) do
    {:ok, put_at(tree, op.path, op.value), track_secret(secrets, op)}
  end

  defp apply_entry({:op, %Cooper.Op{sigil: :append} = op}, tree, secrets) do
    case get_at(tree, op.path) do
      {:ok, existing} when is_tuple(existing) ->
        {:error, tuple_guard_error(op.path, "+")}

      {:ok, existing} when is_list(existing) ->
        {:ok, put_at(tree, op.path, existing ++ List.wrap(op.value)), track_secret(secrets, op)}

      :error ->
        {:ok, put_at(tree, op.path, op.value), track_secret(secrets, op)}

      {:ok, _other} ->
        {:error, not_a_list_error(op.path, "+")}
    end
  end

  defp apply_entry({:op, %Cooper.Op{sigil: :remove} = op}, tree, secrets) do
    case get_at(tree, op.path) do
      {:ok, existing} when is_tuple(existing) ->
        {:error, tuple_guard_error(op.path, "-")}

      {:ok, existing} when is_list(existing) ->
        removed = List.wrap(op.value)

        {:ok, put_at(tree, op.path, Enum.reject(existing, &(&1 in removed))),
         track_secret(secrets, op)}

      :error ->
        {:ok, tree, secrets}

      {:ok, _other} ->
        {:error, not_a_list_error(op.path, "-")}
    end
  end

  defp apply_entry({:op, %Cooper.Op{sigil: :delete} = op}, tree, secrets) do
    remaining = secrets |> Enum.reject(&prefixed_by?(&1, op.path)) |> MapSet.new()
    {:ok, delete_path(tree, op.path), remaining}
  end

  defp track_secret(secrets, %Cooper.Op{secret?: true, path: path}), do: MapSet.put(secrets, path)

  defp track_secret(secrets, %Cooper.Op{secret?: false, path: path}),
    do: MapSet.delete(secrets, path)

  # Deleting a path removes secret-tracking for it *and* anything nested
  # underneath it -- deleting a whole secret subtree shouldn't leave
  # stale entries behind.
  defp prefixed_by?(path, prefix), do: prefix == Enum.take(path, length(prefix))

  # ---- path-indexed get/put/delete over the (possibly `Layered`-valued) tree

  defp get_at(tree, []), do: {:ok, tree}

  defp get_at(tree, [seg | rest]) when is_map(tree) and not is_struct(tree) do
    case Map.fetch(tree, seg) do
      {:ok, v} -> get_at(v, rest)
      :error -> :error
    end
  end

  defp get_at(_other, _path), do: :error

  defp put_at(tree, [last], value), do: Map.put(tree, last, value)

  defp put_at(tree, [seg | rest], value) do
    Map.put(tree, seg, descend(Map.get(tree, seg), rest, value))
  end

  # `existing` at this segment, on the way to writing something deeper:
  # an ordinary map keeps building normally; a lazy `Cooper.Ref.Config`
  # base (or a `Layered` value that already has one) gets *wrapped*
  # rather than clobbered, since `Cooper.Resolver` still needs that base
  # to resolve this path correctly; anything else (nil, a scalar, a list,
  # a tuple) has no sub-structure worth preserving and is simply
  # replaced by the map/Layered being built.
  defp descend(%Cooper.Ref.Config{} = base, rest, value) do
    %Cooper.Merge.Layered{base: base, overrides: put_at(%{}, rest, value)}
  end

  defp descend(%Cooper.Merge.Layered{base: base, overrides: overrides}, rest, value) do
    %Cooper.Merge.Layered{base: base, overrides: put_at(overrides, rest, value)}
  end

  defp descend(existing, rest, value) when is_map(existing) and not is_struct(existing) do
    put_at(existing, rest, value)
  end

  defp descend(_other, rest, value), do: put_at(%{}, rest, value)

  defp delete_path(_tree, []), do: %{}

  defp delete_path(tree, [last]) when is_map(tree) and not is_struct(tree),
    do: Map.delete(tree, last)

  defp delete_path(tree, [seg | rest]) when is_map(tree) and not is_struct(tree) do
    case Map.fetch(tree, seg) do
      {:ok, v} -> Map.put(tree, seg, delete_path(v, rest))
      :error -> tree
    end
  end

  defp delete_path(other, _path), do: other

  defp tuple_guard_error(path, sigil) do
    Error.new(
      message:
        "\"#{sigil}#{Enum.join(path, ".")}\" targets a tuple -- tuples are never merged, only replaced wholesale (CASC.md §8.3)",
      stage: :merge
    )
  end

  defp not_a_list_error(path, sigil) do
    Error.new(
      message:
        "\"#{sigil}#{Enum.join(path, ".")}\" needs a list at that path, found something else",
      stage: :merge
    )
  end
end
