defmodule Cooper.Actions do
  @moduledoc """
  `Ichor.Actions` for `casc.aether`. Turns the raw parse into:

    * a native Elixir term for every leaf value;
    * a flat list of `{:op, %Cooper.Op{}}` / `{:var, %Cooper.VarDecl{}}`
      entries for every statement, dotted paths and nested blocks already
      flattened into each op's `path`, `:file` included -- assembling
      that list into a `%{}` is a separate step (`Cooper.Merge.assemble/1`;
      see that module's moduledoc), deliberately *not* done here, so
      `Cooper.Loader` can recursively parse an imported file with this
      same module and splice its entries into the importer's own list
      instead of un-folding an already-assembled map.

  Interpolation (`@{...}`, `${...}`, `%{...}`, `!{...}`, `!Name(...)`)
  is resolved into unresolved `Cooper.Ref.*` AST nodes here, not fully
  resolved -- that's `Cooper.Resolver`'s job, once a variable
  environment and the final merged tree exist. A bare, whole-value ref
  (`region = ${REGION}`) is built directly below; a ref embedded in a
  double-quoted string's content is redispatched through
  `Cooper.InterpGrammar` (see its own moduledoc for why that's a
  separate grammar).
  """

  alias Ichor.Error

  import Cooper.RefCommon,
    only: [
      marker_present?: 2,
      eval_optional: 2,
      eval_each: 2,
      ref_suffix: 2,
      env_bracket: 2,
      build_resolver_ref: 2
    ]

  @behaviour Ichor.Actions

  # ---- structural rules ---------------------------------------------------

  # Returns the flattened `{:op, %Cooper.Op{}}` / `{:var, %Cooper.VarDecl{}}`
  # entry list -- *not* assembled into a map. Assembly is a separate,
  # explicit step (`Cooper.Grammar.run/2` calls `Cooper.Merge.assemble/1`
  # itself, after this returns) so that `Cooper.Loader` can recursively
  # parse an imported file with this exact same module and get back
  # something it can splice into the importer's own op list, rather than
  # an already-folded map it would have to un-fold.
  @impl true
  def handle_rule(:file, captures, ctx) do
    with {:ok, _version, ctx} <- Map.fetch!(captures, :version_header).eval.(ctx),
         {:ok, lists, ctx} <- eval_each(Map.get(captures, :statement, []), ctx) do
      {:ok, List.flatten(lists), ctx}
    end
  end

  def handle_rule(:version_header, captures, ctx) do
    with {:ok, kw, ctx} <- Map.fetch!(captures, :kw).eval.(ctx) do
      if kw == "version" do
        Map.fetch!(captures, :version_number).eval.(ctx)
      else
        {:error,
         Error.new(
           message: "expected \"#@version\", got \"##{kw}\"",
           stage: :action
         )}
      end
    end
  end

  # `version_head` hands back raw *text* (not the evaluated FLOAT/INTEGER
  # value) -- see the grammar's own comment on why: the lexer may have
  # already folded e.g. "1.0" of "1.0.0" into a single FLOAT token, and
  # only the raw text can be split back apart correctly.
  def handle_rule(:version_head, captures, ctx) do
    [{_name, cap}] = Map.to_list(captures)
    {:token, _name, text} = cap.node
    {:ok, text, ctx}
  end

  def handle_rule(:version_number, captures, ctx) do
    with {:ok, head_text, ctx} <- Map.fetch!(captures, :version_head).eval.(ctx),
         {:ok, tail, ctx} <- eval_each(Map.get(captures, :n, []), ctx) do
      head_parts = head_text |> String.split(".") |> Enum.map(&String.to_integer/1)
      {:ok, List.to_tuple(head_parts ++ tail), ctx}
    end
  end

  def handle_rule(:disabled_statement, captures, ctx) do
    with {:ok, _discarded, ctx} <- Map.fetch!(captures, :real_statement).eval.(ctx) do
      {:ok, [], ctx}
    end
  end

  # `${?NAME}` guards the *one* statement immediately following it
  # (CASC.md §7.2). When the env var is unset/empty, the guarded
  # statement is never even evaluated -- not evaluated-then-discarded
  # the way `disabled_statement` works -- so nothing inside it (an
  # unregistered tag, an undefined variable, whatever) can raise just
  # because it happened to be skipped.
  def handle_rule(:conditional_statement, captures, ctx) do
    with {:ok, name, ctx} <- Map.fetch!(captures, :env_guard).eval.(ctx) do
      ctx = update_in(ctx, [:env_guard_names], &MapSet.put(&1, name))

      if env_set?(ctx.env, name) do
        Map.fetch!(captures, :real_statement).eval.(ctx)
      else
        {:ok, [], ctx}
      end
    end
  end

  def handle_rule(:var_decl, captures, ctx) do
    {private?, ctx} = marker_present?(Map.get(captures, :private), ctx)

    with {:ok, name, ctx} <- Map.fetch!(captures, :name).eval.(ctx),
         {:ok, value, ctx} <- Map.fetch!(captures, :value).eval.(ctx) do
      decl = %Cooper.VarDecl{name: name, value: value, public?: not private?}
      # `Cooper.Loop` needs a resolvable variable environment to know how
      # many iterations a `for @x in @{name} ...` binding generates --
      # stashed on `ctx` (threaded by `eval_each/2` in source order) so a
      # later `for` statement, or an importing file (`Cooper.Loader`),
      # can see it. The `public?` half of the stored tuple is what lets
      # `Cooper.Loader` implement CASC.md §5.2's "public @name values
      # from an imported file are visible transitively; private
      # @*name values never leave their declaring file" when it
      # propagates an imported file's vars back into the importer's own
      # `ctx.vars`.
      ctx = put_in(ctx, [:vars, name], {value, not private?})
      {:ok, [{:var, decl}], ctx}
    end
  end

  def handle_rule(:for_statement, captures, ctx) do
    with {:ok, for_kw, ctx} <- Map.fetch!(captures, :for_kw).eval.(ctx),
         :ok <- validate_kw(for_kw, "for"),
         {:ok, bindings, ctx} <- eval_each(Map.fetch!(captures, :binding), ctx),
         {:ok, from_template, ctx} <-
           eval_from_clause(Map.get(captures, :from_kw), Map.get(captures, :template), ctx),
         {:ok, as_kw, ctx} <- Map.fetch!(captures, :as_kw).eval.(ctx),
         :ok <- validate_kw(as_kw, "as"),
         {:ok, {dest_segments, dest_secret?}, ctx} <- Map.fetch!(captures, :dest).eval.(ctx),
         {:ok, body, ctx} <- Map.fetch!(captures, :block).eval.(ctx) do
      case Cooper.Loop.expand(
             bindings,
             from_template,
             dest_segments,
             dest_secret?,
             body,
             ctx.vars
           ) do
        {:ok, entries} -> {:ok, entries, ctx}
        {:error, _} = err -> err
      end
    end
  end

  def handle_rule(:binding, captures, ctx) do
    with {:ok, name, ctx} <- Map.fetch!(captures, :name).eval.(ctx) do
      case Map.get(captures, :in_kw) do
        nil ->
          {:ok, {:index, name}, ctx}

        cap ->
          with {:ok, in_kw, ctx} <- cap.eval.(ctx),
               :ok <- validate_kw(in_kw, "in"),
               {:ok, iterable, ctx} <- Map.fetch!(captures, :iterable).eval.(ctx) do
            {:ok, {:element, name, iterable}, ctx}
          end
      end
    end
  end

  def handle_rule(:import_statement, captures, ctx) do
    with {:ok, import_kw, ctx} <- Map.fetch!(captures, :import_kw).eval.(ctx),
         :ok <- validate_kw(import_kw, "import"),
         {:ok, path, ctx} <- Map.fetch!(captures, :path).eval.(ctx) do
      Cooper.Loader.load_import(path, ctx)
    end
  end

  def handle_rule(:sigil_kv_statement, captures, ctx) do
    with {:ok, sigil_text, ctx} <- eval_optional(Map.get(captures, :sigil), ctx),
         {:ok, {segments, secret?}, ctx} <- Map.fetch!(captures, :key_path).eval.(ctx),
         {:ok, rhs, ctx} <- Map.fetch!(captures, :rhs).eval.(ctx) do
      sigil = sigil_for(sigil_text)

      case rhs do
        %Cooper.Block{ops: nested} ->
          entries =
            Enum.map(nested, fn
              {:op, op} ->
                {:op,
                 %{op | path: segments ++ op.path, secret?: secret? or op.secret?, sigil: sigil}}

              {:clear, path} ->
                {:clear, segments ++ path}

              other ->
                other
            end)

          # `~key { ... }` replaces the *whole* subtree at `key`, not
          # just the paths the new block happens to mention (CASC.md
          # §8.4's own worked example: `~server { port = 9090 }` must
          # drop `host` too). Tagging every leaf op `:replace` (done
          # above via `sigil`) isn't enough on its own to express that --
          # `Cooper.Merge` needs an explicit "clear everything under
          # `segments` first" instruction at the *statement's* own path,
          # emitted once, ahead of the leaves.
          prefix = if sigil == :replace, do: [{:clear, segments}], else: []
          {:ok, prefix ++ entries, ctx}

        scalar ->
          op = %Cooper.Op{path: segments, sigil: sigil, value: scalar, secret?: secret?}
          {:ok, [{:op, op}], ctx}
      end
    end
  end

  def handle_rule(:delete_statement, captures, ctx) do
    with {:ok, {segments, secret?}, ctx} <- Map.fetch!(captures, :key_path).eval.(ctx) do
      op = %Cooper.Op{path: segments, sigil: :delete, value: nil, secret?: secret?}
      {:ok, [{:op, op}], ctx}
    end
  end

  def handle_rule(:block, captures, ctx) do
    with {:ok, lists, ctx} <- eval_each(Map.get(captures, :statement, []), ctx) do
      {:ok, %Cooper.Block{ops: List.flatten(lists)}, ctx}
    end
  end

  def handle_rule(:key_path, captures, ctx) do
    with {:ok, segments, ctx} <- eval_each(Map.fetch!(captures, :key_segment), ctx) do
      secret? = Enum.any?(segments, fn {_text, secret?} -> secret? end)
      texts = Enum.map(segments, fn {text, _secret?} -> text end)
      {:ok, {texts, secret?}, ctx}
    end
  end

  def handle_rule(:key_segment, captures, ctx) do
    {secret?, ctx} = marker_present?(Map.get(captures, :secret), ctx)

    with {:ok, text, ctx} <- Map.fetch!(captures, :seg).eval.(ctx) do
      {:ok, {text, secret?}, ctx}
    end
  end

  # ---- lists and tuples (CASC.md §6.10-6.11) -------------------------------

  def handle_rule(:list, captures, ctx) do
    eval_each(Map.get(captures, :value, []), ctx)
  end

  def handle_rule(:tuple, captures, ctx) do
    with {:ok, values, ctx} <- eval_each(Map.get(captures, :value, []), ctx) do
      {:ok, List.to_tuple(values), ctx}
    end
  end

  # ---- interpolation and references (CASC.md §7) ---------------------------

  def handle_rule(:at_ref, captures, ctx) do
    with {:ok, name, ctx} <- Map.fetch!(captures, :name).eval.(ctx),
         {:ok, index, ctx} <- eval_optional(Map.get(captures, :idx_suffix), ctx),
         {:ok, suffix, ctx} <- eval_optional(Map.get(captures, :ref_suffix), ctx) do
      {:ok, %Cooper.Ref.Var{name: name, index: index, suffix: suffix}, ctx}
    end
  end

  def handle_rule(:env_ref, captures, ctx) do
    with {:ok, name, ctx} <- Map.fetch!(captures, :name).eval.(ctx),
         {:ok, bracket, ctx} <- eval_optional(Map.get(captures, :env_bracket), ctx),
         {:ok, suffix, ctx} <- eval_optional(Map.get(captures, :ref_suffix), ctx) do
      {index, list?} =
        case bracket do
          {:index, i} -> {i, false}
          :list -> {nil, true}
          nil -> {nil, false}
        end

      {:ok, %Cooper.Ref.Env{name: name, index: index, list?: list?, suffix: suffix}, ctx}
    end
  end

  def handle_rule(:config_ref, captures, ctx) do
    with {:ok, {segments, _secret?}, ctx} <- Map.fetch!(captures, :path).eval.(ctx),
         {:ok, index, ctx} <- eval_optional(Map.get(captures, :idx_suffix), ctx),
         {:ok, suffix, ctx} <- eval_optional(Map.get(captures, :ref_suffix), ctx) do
      {:ok, %Cooper.Ref.Config{path: segments, index: index, suffix: suffix}, ctx}
    end
  end

  def handle_rule(:resolver_ref, captures, ctx) do
    {:token, _token_name, text} = Map.fetch!(captures, :raw).node
    build_resolver_ref(text, ctx)
  end

  def handle_rule(:tagged_ref, captures, ctx) do
    with {:ok, name, ctx} <- Map.fetch!(captures, :name).eval.(ctx),
         {:ok, arg, ctx} <- Map.fetch!(captures, :arg).eval.(ctx) do
      {:ok, %Cooper.Ref.Tagged{name: name, arg: arg}, ctx}
    end
  end

  def handle_rule(:env_bracket, captures, ctx), do: env_bracket(captures, ctx)
  def handle_rule(:ref_suffix, captures, ctx), do: ref_suffix(captures, ctx)

  # ---- atoms (CASC.md §6.4) ------------------------------------------------
  #
  # Every `String.to_atom/1` below (here and in `atom_word` just after)
  # feeds Elixir's atom table, which is bounded and never garbage-
  # collected -- fine for config sourced from a fixed, trusted set of
  # files, a real concern if `Cooper` is ever pointed at config that
  # isn't fixed/trusted at deploy time (e.g. user-uploaded config); see
  # `Cooper`'s own moduledoc ("A note on atoms") for the full writeup.

  def handle_rule(:atom_value, captures, ctx) do
    case Map.to_list(captures) do
      [{:colon_atom, cap}] ->
        cap.eval.(ctx)

      [{:IDENT, cap}] ->
        with {:ok, text, ctx} <- cap.eval.(ctx), do: {:ok, String.to_atom(text), ctx}
    end
  end

  # `atom_word` reaches an atom named after a reserved word (`:true`,
  # `:nil`, ...) -- it needs the raw *text* of whichever token matched,
  # not that token's normal semantic value (NIL_KW's own handle_token
  # returns the value `nil`, not the text "nil").
  def handle_rule(:atom_word, captures, ctx) do
    [{_name, cap}] = Map.to_list(captures)
    {:token, _name, text} = cap.node
    {:ok, String.to_atom(text), ctx}
  end

  # `:statement`, `:real_statement`, `:rhs`, `:seg` -- every rule whose
  # whole body is a bare choice between other named rules/tokens -- are
  # trivial single-capture pass-throughs with no need for their own
  # clause above; written explicitly for the same reason `handle_token`'s
  # catch-all is (see its own comment): `Ichor.Actions`' own default-rule
  # fallback detects "no clause matched" via the *raised exception's*
  # originating module, which breaks under delegation from another
  # module (this one had exactly that bug once, via a test-support
  # module that has since been designed away -- kept defensive anyway).
  def handle_rule(_rule, captures, ctx) do
    [{_name, cap}] = Map.to_list(captures)
    cap.eval.(ctx)
  end

  # ---- tokens (CASC.md §6) -------------------------------------------------

  @impl true
  def handle_token(:NIL_KW, _text, _ctx), do: {:ok, nil}
  def handle_token(:TRUE_KW, _text, _ctx), do: {:ok, true}
  def handle_token(:FALSE_KW, _text, _ctx), do: {:ok, false}

  def handle_token(:INF_KW, "-inf", _ctx), do: {:ok, :neg_infinity}
  def handle_token(:INF_KW, _text, _ctx), do: {:ok, :infinity}

  def handle_token(:INTEGER, text, _ctx), do: {:ok, parse_integer(text)}
  def handle_token(:FLOAT, text, _ctx), do: {:ok, parse_float(text)}

  def handle_token(:DATE, text, _ctx), do: {:ok, Date.from_iso8601!(text)}
  def handle_token(:TIME, text, _ctx), do: {:ok, Time.from_iso8601!(text)}

  def handle_token(:DATETIME, text, _ctx) do
    if String.ends_with?(text, "Z") or Regex.match?(~r/[+-]\d{2}:\d{2}$/, text) do
      {:ok, dt, _offset} = DateTime.from_iso8601(text)
      {:ok, dt}
    else
      {:ok, NaiveDateTime.from_iso8601!(text)}
    end
  end

  def handle_token(:IPV4, text, _ctx) do
    case parse_ip(text, &Cooper.IPv4.new/2) do
      {:ok, ip} -> {:ok, ip}
      {:error, message} -> {:error, Error.new(message: message, stage: :action)}
    end
  end

  def handle_token(:IPV6, text, _ctx) do
    case parse_ip(text, &Cooper.IPv6.new/2) do
      {:ok, ip} -> {:ok, ip}
      {:error, message} -> {:error, Error.new(message: message, stage: :action)}
    end
  end

  def handle_token(:DURATION, text, _ctx) do
    case Cooper.Literals.parse_duration(text) do
      {:ok, ns} -> {:ok, {:duration, ns}}
      {:error, message} -> {:error, Error.new(message: message, stage: :action)}
    end
  end

  def handle_token(:BYTES, text, _ctx) do
    case Cooper.Literals.parse_bytes(text) do
      {:ok, bytes} -> {:ok, {:bytes, bytes}}
      {:error, message} -> {:error, Error.new(message: message, stage: :action)}
    end
  end

  # Four of CASC.md §6.5's five string forms: double/single/triple-quoted
  # below, plus the bare-atom/identifier fallthrough for anything else.
  # The fifth -- backslash-continuation ("a bare value starting with `\`
  # at end-of-line joins onto the next line") -- is a known, deliberate
  # gap, not an oversight: see `priv/grammar/casc.aether`'s own comment
  # and `test/SPEC_COVERAGE.md`'s "Known gap" for why (no worked
  # `Result` example in the spec to validate an implementation against).
  def handle_token(:DQ_STRING, text, _ctx) do
    unescaped = text |> String.slice(1..-2//1) |> unescape()

    case Cooper.InterpGrammar.run(unescaped) do
      {:ok, []} -> {:ok, ""}
      {:ok, [single]} when is_binary(single) -> {:ok, single}
      {:ok, segments} -> {:ok, %Cooper.Interp.Text{segments: segments}}
      {:error, _} = err -> err
    end
  end

  def handle_token(:SQ_STRING, text, _ctx) do
    {:ok, String.slice(text, 1..-2//1)}
  end

  def handle_token(:TRIPLE_STRING, text, _ctx) do
    {:ok, text |> String.slice(3..-4//1) |> dedent_triple()}
  end

  # Everything else (IDENT, and any anonymous/punctuation token) passes its
  # raw text straight through -- written explicitly rather than left to
  # `Ichor.Actions`' own default-fallback machinery, which detects "no
  # clause matched" by checking the *raised exception's* originating
  # module; that check breaks the moment another module delegates to
  # this one instead of being passed to `Grammar.VM.run` directly.
  def handle_token(_token, text, _ctx), do: {:ok, text}

  # ---- helpers --------------------------------------------------------------

  # `for`/`in`/`from`/`as` are grammar-level bare IDENTs (CASC.md §4.1's
  # *contextual* keywords, never globally reserved -- see the grammar's
  # own comment), so the actual keyword text is checked here instead.
  defp validate_kw(text, expected) when text == expected, do: :ok

  defp validate_kw(text, expected) do
    {:error, Error.new(message: "expected \"#{expected}\", got \"#{text}\"", stage: :action)}
  end

  # CASC.md §7.2: "${?NAME}" treats unset *and* empty identically (same
  # as "${NAME:default}"'s own "unset/empty" wording).
  defp env_set?(env, name) do
    case Map.fetch(env, name) do
      {:ok, value} -> value != ""
      :error -> false
    end
  end

  # `for_statement`'s optional "from <template>" is an inline choice, not
  # a separate optional rule (see the grammar's own comment on why) --
  # `from_kw`/`template` are either both present or both absent.
  defp eval_from_clause(nil, nil, ctx), do: {:ok, nil, ctx}

  defp eval_from_clause(from_kw_cap, template_cap, ctx) do
    with {:ok, from_kw, ctx} <- from_kw_cap.eval.(ctx),
         :ok <- validate_kw(from_kw, "from"),
         {:ok, {segments, _secret?}, ctx} <- template_cap.eval.(ctx) do
      {:ok, segments, ctx}
    end
  end

  defp sigil_for(nil), do: :merge
  defp sigil_for(""), do: :merge
  defp sigil_for("~"), do: :replace
  defp sigil_for("+"), do: :append
  defp sigil_for("-"), do: :remove

  defp parse_integer(text) do
    {sign, rest} =
      case text do
        "+" <> rest -> {1, rest}
        "-" <> rest -> {-1, rest}
        rest -> {1, rest}
      end

    rest = String.replace(rest, "_", "")

    value =
      cond do
        String.starts_with?(rest, "0x") -> String.to_integer(binary_slice(rest, 2..-1//1), 16)
        String.starts_with?(rest, "0o") -> String.to_integer(binary_slice(rest, 2..-1//1), 8)
        String.starts_with?(rest, "0b") -> String.to_integer(binary_slice(rest, 2..-1//1), 2)
        true -> String.to_integer(rest)
      end

    sign * value
  end

  defp parse_float(text) do
    text
    |> String.replace("_", "")
    |> ensure_decimal_point()
    |> String.to_float()
  end

  defp ensure_decimal_point(text) do
    if String.contains?(text, ".") do
      text
    else
      case Regex.run(~r/^([+-]?\d+)([eE].*)$/, text) do
        [_, mantissa, exponent] -> mantissa <> ".0" <> exponent
        nil -> text <> ".0"
      end
    end
  end

  # The grammar's IPV4/IPV6 tokens are deliberately permissive (an
  # octet or CIDR prefix isn't range-checked at the lexer level, same
  # tradeoff as DURATION/BYTES above) -- `:inet.parse_address/1` does
  # the real address validation (out-of-range octets, malformed IPv6),
  # and `constructor` (`Cooper.IPv4.new/2`/`Cooper.IPv6.new/2`) does the
  # CIDR prefix range check, so a bad literal fails here with a named
  # message instead of the unguarded `{:ok, ip} = ...` this replaced,
  # which crashed the whole process on a malformed address.
  defp parse_ip(text, constructor) do
    {addr_text, prefix} =
      case String.split(text, "/", parts: 2) do
        [addr, prefix_text] -> {addr, String.to_integer(prefix_text)}
        [addr] -> {addr, nil}
      end

    case :inet.parse_address(String.to_charlist(addr_text)) do
      {:ok, address} -> constructor.(address, prefix)
      {:error, :einval} -> {:error, "invalid IP address: #{inspect(addr_text)}"}
    end
  end

  @escapes %{
    "n" => "\n",
    "r" => "\r",
    "t" => "\t",
    "\"" => "\"",
    "\\" => "\\"
  }

  defp unescape(text) do
    Regex.replace(~r/\\(u[0-9a-fA-F]{4}|.)/, text, fn _whole, escaped ->
      case escaped do
        "u" <> <<hex::binary-size(4)>> ->
          hex |> String.to_integer(16) |> List.wrap() |> List.to_string()

        other ->
          Map.get(@escapes, other, other)
      end
    end)
  end

  # CASC.md §6.5: strips the smallest common leading whitespace across
  # non-empty lines, and drops the leading newline right after the
  # opening `"""` -- deliberately the same shape as Elixir's own heredoc
  # dedent, since CASC.md's own worked example matches it exactly.
  defp dedent_triple(content) do
    content =
      if String.starts_with?(content, "\n"), do: binary_slice(content, 1..-1//1), else: content

    lines = String.split(content, "\n")

    indent =
      lines
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(&leading_whitespace_count/1)
      |> case do
        [] -> 0
        counts -> Enum.min(counts)
      end

    lines
    |> Enum.map(&String.slice(&1, indent..-1//1))
    |> Enum.join("\n")
  end

  defp leading_whitespace_count(line) do
    line |> String.to_charlist() |> Enum.take_while(&(&1 in [?\s, ?\t])) |> length()
  end
end
