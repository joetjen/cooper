defmodule Cooper.Grammar do
  @moduledoc """
  Orchestrates `casc.aether` parsing against `Cooper.NativeGrammar`
  (`Grammar.Native`, compiled ahead of time by `mix ichor.gen` -- see
  its own moduledoc). `Grammar.VM` -- the interpreted bytecode backend
  that `ichor` proper still ships -- is no longer reachable from
  anything under `lib/` at all: `ichor` is an `only: [:dev, :test],
  runtime: false` dependency now (the `ichor`/`ichor_runtime` split),
  so nothing a `mix release` build ships is allowed to call into it.
  `Cooper.Test.VMParity` (`test/support/`, compiled only under
  `MIX_ENV=test`) keeps the old `Grammar.VM` path alive purely for
  `bench/native_vs_vm.exs` and `test/cooper/backend_parity_test.exs`.
  """

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
  # context. But its generated `parse/1` *is* public, returning exactly
  # the `{:ok, pos, raw_captures}` shape `Ichor.Actions.evaluate/5`
  # needs -- `capture_shapes` (`Grammar.VM.RuleCompiler.capture_shapes/1`,
  # baked into `run/2`/`run_sequence/2` as a literal at codegen time,
  # but not exposed as its own callable) comes from
  # `Cooper.NativeGrammar.CaptureShapes.get/0` instead, a small sibling
  # module `scripts/gen_capture_shapes.exs` generates ahead of time the
  # same way -- see that module's own moduledoc for why this needs its
  # own tiny generator rather than reusing `mix ichor.gen`'s output
  # directly. Neither call touches `ichor` proper at runtime.
  #
  # `actions_module` is accepted for interface parity with
  # `Cooper.Test.VMParity.run_with_context_vm/3`, but `Cooper.NativeGrammar`
  # bakes in `Cooper.Actions` at codegen time -- every caller in this
  # codebase already only ever passes that module, so this isn't a real
  # restriction in practice.
  @doc false
  def run_with_context(source_text, actions_module, initial_context) do
    with {:ok, _pos, raw_captures} <- Cooper.NativeGrammar.parse(source_text) do
      Ichor.Actions.evaluate(
        :file,
        raw_captures,
        actions_module,
        initial_context,
        Cooper.NativeGrammar.CaptureShapes.get()
      )
    end
  end
end
