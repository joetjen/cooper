defmodule Cooper.InterpActions do
  @moduledoc """
  `Ichor.Actions` for `casc_interp.aether` -- parses a double-quoted
  string's already escape-processed content into an ordered list of
  literal string runs and `Cooper.Ref.*` nodes.

  Every reference form arrives as one whole raw token (see the grammar
  file's own comment on why); each `handle_token/3` clause below parses
  that captured text with plain Elixir string/regex logic rather than
  further Aether grammar structure. The `:default`/`:+alt`/`:?"msg"`
  value grammar implemented here (`parse_default_value/1`) is
  deliberately reduced from `casc.aether`'s own `value` rule -- nil/
  bool/int/float/strings/atoms/lists only, no dates/IP/duration/bytes/
  tuples/nested refs -- a scope trim for refs nested inside a larger
  string (see `casc.aether`'s own comment on why the bare, whole-value
  case doesn't have this limitation).
  """

  import Cooper.RefCommon, only: [eval_each: 2, build_resolver_ref: 2]

  @behaviour Ichor.Actions

  @impl true
  def handle_rule(:text, captures, ctx) do
    eval_each(Map.get(captures, :segment, []), ctx)
  end

  # `:segment` is a trivial single-capture pass-through; see
  # `Cooper.Actions`' identical catch-all for why this is written
  # explicitly rather than left to `Ichor.Actions`' own default.
  def handle_rule(_rule, captures, ctx) do
    [{_name, cap}] = Map.to_list(captures)
    cap.eval.(ctx)
  end

  @impl true
  def handle_token(:AT_REF_RAW, text, _ctx) do
    {body, filters} = text |> strip(2, 1) |> split_filters()
    {name, index, suffix} = parse_ref_body(body)
    {:ok, %Cooper.Ref.Var{name: name, index: index, suffix: suffix, filters: filters}}
  end

  def handle_token(:ENV_REF_RAW, text, _ctx) do
    {body, filters} = text |> strip(2, 1) |> split_filters()
    {name, bracket, suffix} = parse_env_ref_body(body)

    {index, list?} =
      case bracket do
        {:index, i} -> {i, false}
        :list -> {nil, true}
        nil -> {nil, false}
      end

    {:ok,
     %Cooper.Ref.Env{name: name, index: index, list?: list?, suffix: suffix, filters: filters}}
  end

  def handle_token(:CONFIG_REF_RAW, text, _ctx) do
    {body, filters} = text |> strip(2, 1) |> split_filters()
    {path_text, index, suffix} = parse_ref_body(body)

    {:ok,
     %Cooper.Ref.Config{
       path: String.split(path_text, "."),
       index: index,
       suffix: suffix,
       filters: filters
     }}
  end

  def handle_token(:RESOLVER_REF_RAW, text, ctx) do
    case build_resolver_ref(text, ctx) do
      {:ok, ref, _ctx} -> {:ok, ref}
      {:error, _} = err -> err
    end
  end

  def handle_token(:TAGGED_REF_RAW, text, _ctx) do
    case Regex.run(~r/^!([a-zA-Z][a-zA-Z0-9_+\-?!]*)\((.*)\)$/s, text) do
      [_, name, arg_text] ->
        {:ok, %Cooper.Ref.Tagged{name: name, arg: parse_default_value(arg_text)}}
    end
  end

  def handle_token(_token, text, _ctx), do: {:ok, text}

  # ---- helpers --------------------------------------------------------------

  # Drops `from_start` chars off the front and `from_end` off the back in
  # one slice -- e.g. `strip(text, 2, 1)` for a `"@{...}"`-shaped raw
  # token peels the 2-char opener and the 1-char closing "}".
  defp strip(text, from_start, from_end) do
    String.slice(text, from_start..(-from_end - 1)//1)
  end

  # "name[idx]:suffix" (at_ref, config_ref) -- name/index/suffix, no
  # env_ref's extra "[]" list-marker distinction.
  defp parse_ref_body(inner) do
    {name_and_bracket, suffix_text} = split_suffix(inner)

    {name, index} =
      case Regex.run(~r/^([^\[]+)\[(\d+)\]$/, name_and_bracket) do
        [_, name, idx] -> {name, String.to_integer(idx)}
        nil -> {name_and_bracket, nil}
      end

    {name, index, suffix_text && parse_suffix_value(suffix_text)}
  end

  # "NAME[i]:suffix" (index) vs "NAME[]:suffix" (list marker) vs
  # "NAME:suffix" (neither) -- CASC.md §7.2.
  defp parse_env_ref_body(inner) do
    {name_and_bracket, suffix_text} = split_suffix(inner)

    {name, bracket} =
      case Regex.run(~r/^([^\[]+)\[(\d*)\]$/, name_and_bracket) do
        [_, name, ""] -> {name, :list}
        [_, name, idx] -> {name, {:index, String.to_integer(idx)}}
        nil -> {name_and_bracket, nil}
      end

    {name, bracket, suffix_text && parse_suffix_value(suffix_text)}
  end

  # The first ":" is always the name/suffix separator -- name (and any
  # "[...]" index) never contains one, so splitting on the first
  # occurrence is correct even when the suffix's own default value does
  # (e.g. a quoted-string default containing ":").
  # Splits the filter chain (CASC.md §7.2) off the reference body.
  #
  # Must run *before* `split_suffix/1`: a filter carries its own `:` in
  # `| trim_suffix: "://"`, and splitting on the first `:` would otherwise eat
  # the whole chain as a default value -- which is exactly the bug this
  # hand-parsed path had while `casc.aether` handled it correctly.
  #
  # Quote-aware, because a legitimate default can contain a pipe:
  # `${NAME:"a|b"}` is one default, not a filter.
  defp split_filters(inner) do
    case split_top_level_pipes(inner) do
      [body] -> {body, []}
      # The body keeps whatever whitespace sat before the first `|`; the aether
      # path never sees it because `@skip` eats it, so trimming here is what
      # keeps the two parses identical.
      [body | filters] -> {String.trim_trailing(body), Enum.map(filters, &parse_filter/1)}
    end
  end

  defp split_top_level_pipes(text) do
    text
    |> String.graphemes()
    |> Enum.reduce({[], "", nil}, fn
      quote_char, {parts, current, nil} when quote_char in ~w(" ') ->
        {parts, current <> quote_char, quote_char}

      quote_char, {parts, current, quote_char} ->
        {parts, current <> quote_char, nil}

      "|", {parts, current, nil} ->
        {parts ++ [current], "", nil}

      char, {parts, current, quoted} ->
        {parts, current <> char, quoted}
    end)
    |> then(fn {parts, current, _quoted} -> parts ++ [current] end)
  end

  defp parse_filter(text) do
    case String.split(String.trim(text), ":", parts: 2) do
      [name] -> {String.trim(name), nil}
      [name, argument] -> {String.trim(name), argument |> String.trim() |> strip_filter_quotes()}
    end
  end

  # A filter argument may be single-quoted, which `strip_quotes/1` (the
  # double-quoted default-value form) does not handle. Single quotes are the
  # spelling that works inside an interpolated string.
  defp strip_filter_quotes(text) do
    case text do
      <<?\', rest::binary>> when byte_size(rest) > 0 ->
        if String.ends_with?(rest, "\'"),
          do: binary_part(rest, 0, byte_size(rest) - 1),
          else: text

      _other ->
        strip_quotes(text)
    end
  end

  defp split_suffix(inner) do
    case String.split(inner, ":", parts: 2) do
      [name_and_bracket] -> {name_and_bracket, nil}
      [name_and_bracket, suffix_text] -> {name_and_bracket, suffix_text}
    end
  end

  defp parse_suffix_value("?" <> msg_text),
    do: {:required, msg_text |> String.trim() |> strip_quotes()}

  defp parse_suffix_value("+" <> alt_text),
    do: {:substitute, alt_text |> String.trim() |> parse_default_value()}

  defp parse_suffix_value(default_text),
    do: {:default, parse_default_value(String.trim(default_text))}

  defp parse_default_value(text) do
    text = String.trim(text)

    cond do
      text == "nil" ->
        nil

      text == "true" ->
        true

      text == "false" ->
        false

      Regex.match?(~r/^[+-]?\d+$/, text) ->
        String.to_integer(text)

      Regex.match?(~r/^[+-]?\d+\.\d+$/, text) ->
        String.to_float(text)

      String.starts_with?(text, "\"") ->
        strip_quotes(text)

      String.starts_with?(text, "'") and String.ends_with?(text, "'") ->
        String.slice(text, 1..-2//1)

      String.starts_with?(text, "[") and String.ends_with?(text, "]") ->
        parse_default_list(text)

      true ->
        String.to_atom(text)
    end
  end

  defp parse_default_list(text) do
    text
    |> String.slice(1..-2//1)
    |> split_list_items()
    |> Enum.map(&parse_default_value/1)
  end

  defp split_list_items(""), do: []

  # A plain `String.split(text, ",")` would cut a quoted element's own
  # comma in half (`["a, b", c]`'s first element contains one) -- the
  # regex instead matches a whole double-quoted or single-quoted run, or
  # a whole unquoted run up to the next comma, whichever starts at each
  # position; `Regex.scan/2` then walks the text left to right picking
  # off one such run at a time.
  defp split_list_items(text) do
    ~r/"(?:[^"\\]|\\.)*"|'[^']*'|[^,]+/
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp strip_quotes(text) do
    case Regex.run(~r/^"((?:[^"\\]|\\.)*)"$/s, text) do
      [_, inner] -> unescape_simple(inner)
      nil -> text
    end
  end

  @escapes %{"n" => "\n", "r" => "\r", "t" => "\t", "\"" => "\"", "\\" => "\\"}

  defp unescape_simple(text) do
    Regex.replace(~r/\\(.)/s, text, fn _whole, escaped -> Map.get(@escapes, escaped, escaped) end)
  end
end
