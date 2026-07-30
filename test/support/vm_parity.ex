defmodule Cooper.Test.VMParity do
  @moduledoc """
  The original `Grammar.VM`-backed implementation of both grammars,
  moved here (out of `lib/`) by the `ichor`/`ichor_runtime` split:
  `Grammar.VM.*` -- the interpreted bytecode backend, `Grammar.Analysis`,
  `Aether.Parser` -- lives in `ichor` proper, which `mix.exs` now marks
  `only: [:dev, :test], runtime: false` so a `mix release` build of an
  app depending on `cooper` never pulls it in. This module exists
  purely so `test/cooper/backend_parity_test.exs` (both backends must
  produce byte-for-byte identical results) and `bench/native_vs_vm.exs`
  (how much faster is `Grammar.Native`, really) keep working -- nothing
  under `lib/` calls into this module or `Grammar.VM` at all anymore.

  Only compiled under `MIX_ENV=test` (see `elixirc_paths/1` in
  `mix.exs`) -- run the benchmark with `MIX_ENV=test mix run
  bench/native_vs_vm.exs`, not a plain `mix run`, or this module won't
  be on the compiled path for it to call into.
  """

  # Cached rather than re-parsed on every call, same reasoning
  # `Cooper.Grammar.grammar/0` used before the split: `Aether.Parser.parse/2`
  # + `Grammar.Analysis.run/1` aren't free, and nothing about the parsed
  # struct changes at runtime once the grammar file is stable.
  @doc false
  @spec grammar() :: Aether.Grammar.t()
  def grammar do
    case :persistent_term.get({__MODULE__, :grammar}, nil) do
      nil ->
        source = :code.priv_dir(:cooper) |> Path.join("grammar/casc.aether") |> File.read!()
        {:ok, grammar} = Aether.Parser.parse(source, "casc.aether")
        {:ok, grammar} = Grammar.Analysis.run(grammar)
        :persistent_term.put({__MODULE__, :grammar}, grammar)
        grammar

      grammar ->
        grammar
    end
  end

  @doc false
  @spec interp_grammar() :: Aether.Grammar.t()
  def interp_grammar do
    source = :code.priv_dir(:cooper) |> Path.join("grammar/casc_interp.aether") |> File.read!()
    {:ok, grammar} = Aether.Parser.parse(source, "casc_interp.aether")
    {:ok, grammar} = Grammar.Analysis.run(grammar)
    grammar
  end

  # Hand-rolled rather than a call to `Grammar.VM.run/4`: that function
  # matches and evaluates in one step but only ever returns `{:ok,
  # value}`, discarding the final context -- `Cooper.Grammar.run_with_context/3`
  # needs it back (`Cooper.Loader` needs `ctx.vars` for cross-file
  # variable propagation), so this mirrors `Grammar.VM`'s *private*
  # `do_match/3` pipeline instead (tokenize, `@keywords`/`@refine`
  # reclassify, parse, then `Ichor.Actions.evaluate/5` directly) so the
  # context comes back, the same way the real `run_with_context/3` does
  # against `Grammar.Native`. CASC declares no `@keywords`/`@refine`, so
  # `Grammar.Lexer.reclassify/2` is a same-list passthrough here
  # (`grammar.refiners` is `%{}`) -- kept in the pipeline anyway so this
  # stays a genuine parity backend rather than a shortcut that happens
  # to agree today.
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

  @doc "Like `run_with_context_vm/3`, but for `casc_interp.aether` -- `Cooper.InterpActions` never needs context back, so `Grammar.VM.run/4` (match + evaluate in one step) is enough as-is."
  @spec run_interp_vm(String.t()) :: {:ok, list()} | {:error, Ichor.Error.t() | [Ichor.Error.t()]}
  def run_interp_vm(text) do
    Grammar.VM.run(interp_grammar(), text, Cooper.InterpActions, nil)
  end
end
