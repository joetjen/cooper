defmodule Cooper.RefCommon do
  @moduledoc """
  Shared across `Cooper.Actions` and `Cooper.InterpActions`: the
  `:ref_suffix` (`:default`/`:+alt`/`:?"msg"`, CASC.md §7.2's "one rule,
  not three near-identical ones", reused across `@{}`/`${}`/`%{}` in
  both grammars), `:env_bracket` (`${NAME[i]}` vs `${NAME[]}`) and
  `:filters` (`| trim`, `| trim_suffix: "://"`, CASC.md §7.2) handling,
  plus the small eval helpers every custom `handle_rule` in either
  module needs.

  Filters live here rather than in either action module specifically so
  the two cannot drift: `Cooper.Actions` reaches them through the
  `casc.aether` grammar and `Cooper.InterpActions` by hand-parsing a raw
  token, but both end up in `apply_filters/2`.
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

  # The filter vocabulary is deliberately closed. An open one would oblige
  # every conformant reader, in every language, to implement an unbounded
  # set -- and would turn a config format into an expression language,
  # which is the same reason CASC.md §7.2 refuses to guess types.
  #
  # Parameterless entries duplicate the `!trim`/`!downcase`/`!upcase` tags
  # on purpose: a tag wraps a whole value, a filter composes onto a
  # reference that may also carry a default, and forcing one spelling for
  # both would make one of the two read badly.
  @filters %{
    "trim" => :no_argument,
    "downcase" => :no_argument,
    "upcase" => :no_argument,
    "trim_prefix" => :argument,
    "trim_suffix" => :argument
  }

  @doc false
  def filter_names, do: Map.keys(@filters)

  @doc false
  def eval_filters(captures, ctx) do
    case eval_optional(Map.get(captures, :filters), ctx) do
      {:ok, nil, ctx} -> {:ok, [], ctx}
      {:ok, filters, ctx} -> {:ok, filters, ctx}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def eval_filter_list(captures, ctx), do: eval_each(Map.get(captures, :filter, []), ctx)

  @doc false
  def filter(captures, ctx) do
    with {:ok, name, ctx} <- Map.fetch!(captures, :name).eval.(ctx),
         {:ok, argument, ctx} <- eval_optional(Map.get(captures, :arg), ctx) do
      {:ok, {name, argument}, ctx}
    end
  end

  @doc false
  # Applies the filter chain left to right to an already-resolved value.
  #
  # A non-string value is an error rather than a coercion: every filter here is
  # a string operation, and quietly stringifying whatever arrived would hide the
  # mistake of filtering something that was never text.
  def apply_filters(value, []), do: {:ok, value}

  def apply_filters(value, [{name, argument} | rest]) do
    with {:ok, filtered} <- apply_filter(value, name, argument) do
      apply_filters(filtered, rest)
    end
  end

  defp apply_filter(value, name, argument) do
    case {Map.get(@filters, name), value, argument} do
      {nil, _value, _argument} ->
        {:error,
         "unknown filter #{inspect(name)}; known filters: #{Enum.join(Enum.sort(Map.keys(@filters)), ", ")}"}

      {:no_argument, _value, argument} when not is_nil(argument) ->
        {:error, "filter #{inspect(name)} takes no argument"}

      {:argument, _value, nil} ->
        {:error, "filter #{inspect(name)} requires an argument, as in |#{name}: \"...\""}

      {_arity, value, _argument} when not is_binary(value) ->
        {:error, "cannot apply filter #{inspect(name)} to #{inspect(value)}: not a string"}

      {_arity, value, argument} ->
        {:ok, run_filter(name, value, argument)}
    end
  end

  defp run_filter("trim", value, _argument), do: String.trim(value)
  defp run_filter("downcase", value, _argument), do: String.downcase(value)
  defp run_filter("upcase", value, _argument), do: String.upcase(value)
  defp run_filter("trim_prefix", value, argument), do: String.replace_prefix(value, argument, "")
  defp run_filter("trim_suffix", value, argument), do: String.replace_suffix(value, argument, "")

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
