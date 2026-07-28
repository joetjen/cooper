defmodule Cooper.Grammar do
  @moduledoc """
  Loads `casc.aether`. Early development deliberately started on
  `Grammar.VM` rather than `Grammar.Native`: the grammar changed every
  commit while the language was still being built out, and `Grammar.VM`
  loads the `.aether` source at runtime, giving a fast edit/test loop
  where `Grammar.Native` would need a recompile per grammar edit. Now
  that the grammar has stopped changing, the *default*
  (`run_with_context/3`, and everything built on it) is `Grammar.Native`
  (`Cooper.NativeGrammar`) -- `run_with_context_vm/3` stays available
  (used by `bench/native_vs_vm.exs` and the parity test asserting both
  backends produce identical results for every fixture) rather than
  deleting the VM path outright.
  """

  # Cached rather than re-parsed on every call: `Aether.Parser.parse/2`
  # + `Grammar.Analysis.run/1` aren't free, and unlike `Grammar.VM`'s own
  # bytecode compilation (which genuinely has to happen fresh each time
  # under that backend), nothing about *this* struct changes at runtime
  # once the grammar file is stable -- worth it now that the grammar
  # has stopped changing weekly. `:persistent_term` (not a module
  # attribute) specifically so editing
  # `casc.aether` and restarting the app picks up the change without a
  # recompile of this module -- Grammar.Native's own generated
  # parse/run functions still need a real recompile either way, this
  # cache just avoids *also* re-parsing on every single call in the
  # meantime. A live `iex` session editing the grammar file directly
  # won't see changes until the session restarts; a `mix test` run
  # always starts fresh, so this never causes stale-grammar test flake.
  @doc false
  @spec source() :: String.t()
  def source do
    :code.priv_dir(:cooper) |> Path.join("grammar/casc.aether") |> File.read!()
  end

  @doc false
  @spec grammar() :: Aether.Grammar.t()
  def grammar do
    case :persistent_term.get({__MODULE__, :grammar}, nil) do
      nil ->
        {:ok, grammar} = Aether.Parser.parse(source(), "casc.aether")
        {:ok, grammar} = Grammar.Analysis.run(grammar)
        :persistent_term.put({__MODULE__, :grammar}, grammar)
        grammar

      grammar ->
        grammar
    end
  end

  @doc """
  Parses and evaluates `source_text` against `casc.aether` via
  `Cooper.Actions`, returning whatever `Cooper.Merge.assemble/1` (Phase
  1-3's placeholder) or, later, the real merge engine produces.

  `opts`:
    * `:env` -- `%{String.t() => String.t()}`, defaults to
      `System.get_env/0`. Threaded into `ctx` here (not just at
      `Cooper.Resolver`'s later, separate resolve step) because CASC.md
      §7.2's `${?NAME}` -- "skip the whole statement if unset/empty" --
      has to decide *at parse time*, in `Cooper.Actions`, whether the
      statement it guards gets evaluated at all.
    * `:root` -- filesystem root a bare (non-`scheme://`) `import` in
      `source_text` resolves relative to (CASC.md §5.1). Defaults to
      `File.cwd!/0`; pass it explicitly for anything import-related,
      since the default is only reasonable for a real invocation of the
      library, not a test fixture.
    * `:import_schemes` -- `%{scheme => (rest :: String.t() -> {:ok,
      String.t()} | {:error, term()})}`, one function per registered
      `scheme://` import loader (CASC.md §9.3). The same map as
      `Cooper`'s own `:import_schemes` option.
    * `:file` -- the entry source's own absolute path, if it has one.
      Seeds `Cooper.Loader`'s import-cycle-detection set with it, so a
      cycle that loops all the way back to the entry file itself is
      caught on the *first* repeat, not one hop later (an import that
      never reaches the entry file again doesn't need this at all).
      `run_file/2` sets this for you.
  """
  @spec run(String.t(), keyword()) ::
          {:ok, term()} | {:error, Ichor.Error.t() | [Ichor.Error.t()]}
  def run(source_text, opts \\ []) do
    with {:ok, entries} <- run_ops(source_text, opts) do
      Cooper.Merge.assemble(entries)
    end
  end

  @doc """
  Like `run/2`, but reads `path` itself and seeds `:root`/`:file`
  (CASC.md §5.1's "resolves relative to the current file" and correct
  import-cycle detection) from it automatically -- the ordinary way to
  load a real CASC file with imports, rather than assembling those opts
  by hand.
  """
  @spec run_file(String.t(), keyword()) ::
          {:ok, term()} | {:error, Ichor.Error.t() | [Ichor.Error.t()]}
  def run_file(path, opts \\ []) do
    absolute = Path.expand(path)

    with {:ok, source} <- File.read(absolute) do
      run(source, Keyword.merge([root: Path.dirname(absolute), file: absolute], opts))
    else
      {:error, reason} ->
        {:error,
         Ichor.Error.new(
           message: "could not read #{inspect(path)}: #{:file.format_error(reason)}",
           stage: :import
         )}
    end
  end

  @doc """
  Parses, merges, but deliberately does *not* resolve `source_text` --
  returns the assembled tree (`Cooper.Merge.assemble/1`'s output, secret
  leaves already wrapped in `Cooper.Secret` but otherwise still possibly
  containing unresolved `Cooper.Ref.*`/`Cooper.Merge.Layered` values)
  and the file's own resolved variable environment (`name => value`,
  already public/private-filtered across any imports by
  `Cooper.Loader`) -- exactly what `Cooper.Resolver.resolve/2` needs.
  Kept separate from `run/2` (which only merges) rather than folding
  resolution into it, since resolution needs `:env`/`:resolvers`/`:tags`
  options `run/2` doesn't take -- `Cooper.load_string/2` is what finally
  wires the two together end to end.
  """
  @spec run_tree(String.t(), keyword()) ::
          {:ok, map(), map()} | {:error, Ichor.Error.t() | [Ichor.Error.t()]}
  def run_tree(source_text, opts \\ []) do
    with {:ok, entries, ctx} <-
           run_with_context(source_text, Cooper.Actions, initial_context(opts)),
         {:ok, tree} <- Cooper.Merge.assemble(entries) do
      vars = for {name, {value, _public?}} <- ctx.vars, into: %{}, do: {name, value}
      {:ok, tree, vars}
    end
  end

  # Like run/2, but returns the raw flattened `{:op, %Cooper.Op{}}` /
  # `{:var, %Cooper.VarDecl{}}` list instead of folding it through
  # `Cooper.Merge.assemble/1` -- for testing the grammar/flattening
  # independently of merge semantics, and for `Cooper.Loader` splicing
  # an imported file's entries into the importer's own list.
  @doc false
  @spec run_ops(String.t(), keyword()) ::
          {:ok, list()} | {:error, Ichor.Error.t() | [Ichor.Error.t()]}
  def run_ops(source_text, opts \\ []) do
    case run_with_context(source_text, Cooper.Actions, initial_context(opts)) do
      {:ok, ops, _ctx} -> {:ok, ops}
      {:error, _} = err -> err
    end
  end

  @doc false
  def initial_context(opts) do
    importing =
      case Keyword.get(opts, :file) do
        nil -> MapSet.new()
        file -> MapSet.new([Path.expand(file)])
      end

    %{
      vars: %{},
      root: Keyword.get(opts, :root, File.cwd!()),
      import_schemes: Keyword.get(opts, :import_schemes, %{}),
      importing: importing,
      env: Keyword.get(opts, :env, System.get_env())
    }
  end

  # `Grammar.Native`'s own generated `run/2` (`Cooper.NativeGrammar.run/2`)
  # deliberately only returns `{:ok, value}`, discarding the final
  # context -- same as `Grammar.VM.run/4` always did. But its generated
  # `parse/1` *is* public, returning exactly the `{:ok, pos,
  # raw_captures}` shape `Ichor.Actions.evaluate/5` needs (`capture_shapes`
  # isn't separately exposed the way `Grammar.VM.RuleCompiler.capture_shapes/1`
  # is, but it only depends on the *grammar structure*, not which backend
  # matched against it, so computing it directly off `grammar/0` -- cheap
  # once cached, see this module's own moduledoc -- gives the identical
  # map `Cooper.NativeGrammar.run/2` would have used internally).
  #
  # `actions_module` is accepted for interface parity with
  # `run_with_context_vm/3` below, but `Cooper.NativeGrammar` bakes in
  # `Cooper.Actions` at compile time (`use Ichor`'s whole point) -- every
  # caller in this codebase already only ever passes that module, so this
  # isn't a real restriction in practice.
  @doc false
  def run_with_context(source_text, actions_module, initial_context) do
    with {:ok, _pos, raw_captures} <- Cooper.NativeGrammar.parse(source_text) do
      Ichor.Actions.evaluate(
        :file,
        raw_captures,
        actions_module,
        initial_context,
        capture_shapes()
      )
    end
  end

  # `Grammar.VM.RuleCompiler.capture_shapes/1` isn't free -- it's a real
  # traversal of the grammar IR, not a lookup -- so this gets the exact
  # same `:persistent_term` treatment as `grammar/0` itself. Skipping
  # this cache was most of the gap between this backend's initial,
  # disappointing ~1.1x showing and the ~1.6x `bench/native_vs_vm.exs`
  # shows now on its string-light fixture: recomputing it on every single
  # `run_with_context/3` call was pure overhead `Cooper.NativeGrammar.run/2`'s
  # own *compiled* capture_shapes constant would never have paid. See
  # that benchmark's own comments for why a string-heavy fixture shows a
  # smaller ratio still (~1.08x) -- a real property of where the time
  # goes, not something left to fix.
  @doc false
  def capture_shapes do
    case :persistent_term.get({__MODULE__, :capture_shapes}, nil) do
      nil ->
        shapes = Grammar.VM.RuleCompiler.capture_shapes(grammar())
        :persistent_term.put({__MODULE__, :capture_shapes}, shapes)
        shapes

      shapes ->
        shapes
    end
  end

  # The original `Grammar.VM`-backed implementation, kept for
  # `bench/native_vs_vm.exs` and the parity test confirming both
  # backends produce identical results -- not used by any other code in
  # this library anymore.
  #
  # Hand-rolled rather than a call to `Grammar.VM.run/4`: that function
  # matches and evaluates in one step but only ever returns `{:ok,
  # value}`, discarding the final context -- exactly the same reason
  # `run_with_context/3` above bypasses `Cooper.NativeGrammar.run/2`'s
  # own generated `run/2`. Mirrors `Grammar.VM`'s *private* `do_match/3`
  # pipeline instead (tokenize, `@keywords`/`@refine` reclassify, parse,
  # then `Ichor.Actions.evaluate/5` directly) so the context comes back.
  # CASC declares no `@keywords`/`@refine`, so `Grammar.Lexer.reclassify/2`
  # is a same-list passthrough here (`grammar.refiners` is `%{}`) -- kept
  # in the pipeline anyway so this stays a genuine parity backend rather
  # than a shortcut that happens to agree today.
  @doc false
  def run_with_context_vm(source_text, actions_module, initial_context) do
    g = grammar()
    order = Grammar.VM.lexable_token_order(g)
    {char_program, custom_lexemes} = Grammar.VM.CharCompiler.compile(g.tokens)
    rule_program = Grammar.VM.RuleCompiler.compile(g)

    with {:ok, raw_tokens} <-
           Grammar.VM.Tokenizer.tokenize(
             char_program,
             custom_lexemes,
             order,
             rule_program,
             initial_context,
             source_text
           ),
         {:ok, tokens} <- Grammar.Lexer.reclassify(raw_tokens, g.refiners) do
      stream = List.to_tuple(tokens)
      entry = Map.fetch!(rule_program.entry_points, g.root)

      case Grammar.VM.TokenInterpreter.run(
             rule_program.instructions,
             entry,
             stream,
             initial_context
           ) do
        {:ok, pos, raw_captures} when pos == tuple_size(stream) ->
          Ichor.Actions.evaluate(
            g.root,
            raw_captures,
            actions_module,
            initial_context,
            Grammar.VM.RuleCompiler.capture_shapes(g)
          )

        {:ok, _pos, _raw_captures} ->
          {:error,
           Ichor.Error.new(
             message: "unexpected trailing input -- did not expect more input here",
             stage: :parser,
             source: source_text
           )}

        :fail ->
          {:error,
           Ichor.Error.new(
             message: "input does not match #{inspect(g.root)}",
             stage: :parser,
             source: source_text
           )}
      end
    end
  end
end
