defmodule Cooper.RefCommon do
  @moduledoc """
  Shared across `Cooper.Actions` and `Cooper.InterpActions`: the
  `:ref_suffix` (`:default`/`:+alt`/`:?"msg"`, CASC.md §7.2's "one rule,
  not three near-identical ones", reused across `@{}`/`${}`/`%{}` in
  both grammars) and `:env_bracket` (`${NAME[i]}` vs `${NAME[]}`)
  handling, plus the small eval helpers every custom `handle_rule` in
  either module needs.
  """

  # For a bare marker literal (`"*"?` with no inner structure to name
  # instead -- unlike `idx_suffix?`/`ref_suffix?`/`env_bracket?`, there's
  # nothing to bubble up when left unnamed), the *only* reliable way to
  # tell "matched" from "didn't match" is to evaluate it and check the
  # resulting text: an unmatched `name:"*"?` still shows up as a present,
  # non-nil capture (a generic empty-text span -- see `ref_suffix/2`'s
  # own comment on the same underlying quirk), so checking raw presence
  # alone (as an earlier version of this function did) was silently
  # always true.
  @doc false
  def marker_present?(nil, ctx), do: {false, ctx}
  def marker_present?([], ctx), do: {false, ctx}

  def marker_present?(%Ichor.Capture{} = cap, ctx) do
    case cap.eval.(ctx) do
      {:ok, "", ctx} -> {false, ctx}
      {:ok, _text, ctx} -> {true, ctx}
    end
  end

  @doc false
  def eval_optional(nil, ctx), do: {:ok, nil, ctx}
  def eval_optional([], ctx), do: {:ok, nil, ctx}
  def eval_optional(%Ichor.Capture{} = cap, ctx), do: cap.eval.(ctx)

  @doc false
  def eval_each(caps, ctx) do
    result =
      Enum.reduce_while(caps, {:ok, [], ctx}, fn cap, {:ok, acc, ctx} ->
        case cap.eval.(ctx) do
          {:ok, value, ctx} -> {:cont, {:ok, [value | acc], ctx}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, acc, ctx} -> {:ok, Enum.reverse(acc), ctx}
      {:error, _} = err -> err
    end
  end

  @doc false
  def ref_suffix(captures, ctx) do
    case Map.to_list(captures) do
      [{:msg, cap}] ->
        with {:ok, msg, ctx} <- cap.eval.(ctx), do: {:ok, {:required, msg}, ctx}

      [{:alt, cap}] ->
        with {:ok, alt, ctx} <- cap.eval.(ctx), do: {:ok, {:substitute, alt}, ctx}

      [{:default, cap}] ->
        with {:ok, default, ctx} <- cap.eval.(ctx), do: {:ok, {:default, default}, ctx}
    end
  end

  # `raw` is the whole `!{...}` span, "!{" prefix and closing "}" included
  # (CASC.md §7.4: "the first ':' splits name from payload; everything to
  # the matching closing '}' is the payload verbatim").
  @doc false
  def build_resolver_ref(raw_text, ctx) do
    inner = String.slice(raw_text, 2..-2//1)

    case String.split(inner, ":", parts: 2) do
      [name, payload] ->
        {:ok, %Cooper.Ref.Resolver{name: name, payload: payload}, ctx}

      [_no_colon] ->
        {:error,
         Ichor.Error.new(
           message: "resolver reference missing ':' separator: #{inspect(raw_text)}",
           stage: :action
         )}
    end
  end

  # `env_bracket := "[" INTEGER? "]"` -- `INTEGER` referenced bare
  # (unnamed) so it auto-captures under its own name when present and is
  # simply absent from `captures` for the "${NAME[]:...}" list-marker
  # form (brackets present, nothing inside).
  @doc false
  def env_bracket(captures, ctx) do
    case Map.get(captures, :INTEGER) do
      nil -> {:ok, :list, ctx}
      [] -> {:ok, :list, ctx}
      cap -> with {:ok, idx, ctx} <- cap.eval.(ctx), do: {:ok, {:index, idx}, ctx}
    end
  end
end
