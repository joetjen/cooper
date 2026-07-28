defmodule Cooper do
  @moduledoc """
  Parses and loads CASC config files (see `CASC.md`) into native Elixir
  terms: maps (string keys), atoms, real tuples (never lists --
  CASC.md §6.11 is explicit that this is a correctness requirement, not
  an implementation detail), and `Cooper.Secret`-wrapped values for any
  `*key`-prefixed secret.

  `load_file/2`/`load_string/2` run the whole pipeline end to end:
  lex+parse (`Cooper.Grammar`, `Cooper.Actions`) → loop expansion
  (`Cooper.Loop`) → import resolution (`Cooper.Loader`) → merge and
  secret-wrapping (`Cooper.Merge`) → reference resolution
  (`Cooper.Resolver`, which re-wraps a `Cooper.Secret`'s own inner
  value as it resolves, so the wrapping travels through a `%{...}`
  reference or a `for ... from` template copy rather than staying
  pinned to the value's original declared path).

  ## Options

  Both functions take the same `opts`:

    * `:env` -- `%{String.t() => String.t()}`, the source `${...}`
      (CASC.md §7.2) reads from. Defaults to `System.get_env/0`; pass an
      explicit map in tests rather than relying on the real environment.
    * `:root` -- filesystem root a bare (non-`scheme://`) `import`
      resolves relative to (§5.1). `load_file/2` derives this from
      `path`'s own directory automatically; `load_string/2` defaults to
      `File.cwd!/0`.
    * `:resolvers` -- `%{String.t() => (payload :: String.t() -> {:ok,
      term()} | {:error, term()})}`, one function per `!{resolver:...}`
      name your application registers (§7.4/§9.2). Unregistered use of
      any resolver not in this map is a load-time error naming it.
    * `:tags` -- same shape, for `!Name(arg)` beyond the five built-ins
      (`int`/`float`/`bool`/`duration`/`bytes`, §7.5/§9.1). Unregistered
      use is a load-time error naming it, same as `:resolvers`.
    * `:import_schemes` -- `%{String.t() => (rest :: String.t() ->
      {:ok, String.t()} | {:error, term()})}`, one loader per
      `import "scheme://..."` scheme your application registers
      (§5.1/§9.3), returning the imported CASC source text. Unregistered
      use of any scheme not in this map is a load-time error naming it.

  ## Errors

  Every stage returns `{:error, Ichor.Error.t() | [Ichor.Error.t()]}` on
  failure, reusing `Ichor.Error` directly rather than inventing a
  parallel error type -- lexer/parser/analysis errors come from Ichor's
  own stages unchanged; `Cooper`'s own stages (`:loop`, `:import`,
  `:merge`, `:resolve`) extend the same `%Ichor.Error{stage: ...}` shape
  with new atoms rather than a new struct, so every error looks the same
  regardless of which stage raised it.

  ## A note on atoms

  CASC atoms (`level = info`, CASC.md §6.4) become Elixir atoms via
  `String.to_atom/1`, for the ergonomics of pattern-matching against a
  config value the ordinary Elixir way. Elixir's atom table is bounded
  and never garbage-collected -- fine for config sourced from a fixed,
  trusted set of files (typical CASC usage), but worth flagging
  explicitly if `Cooper` is ever pointed at config sources that aren't
  trusted/fixed at deploy time (e.g. user-uploaded config): an attacker
  who can supply arbitrary atom-shaped text can exhaust the atom table.
  Not a concern for the common case; a real one to know about outside it.
  """

  alias Ichor.Error

  @type opts :: [
          env: %{optional(String.t()) => String.t()},
          root: String.t(),
          resolvers: %{optional(String.t()) => (String.t() -> {:ok, term()} | {:error, term()})},
          tags: %{optional(String.t()) => (term() -> {:ok, term()} | {:error, term()})},
          import_schemes: %{
            optional(String.t()) => (String.t() -> {:ok, String.t()} | {:error, term()})
          }
        ]

  @doc """
  Reads and loads the CASC file at `path`. `:root` (see the moduledoc)
  defaults to `path`'s own directory, and import-cycle detection is
  seeded with `path` itself (`Cooper.Grammar.run_file/2`'s own `:file`
  option), so a cycle that loops back to the entry file is caught on the
  first repeat.
  """
  @spec load_file(String.t(), opts()) :: {:ok, term()} | {:error, Error.t() | [Error.t()]}
  def load_file(path, opts \\ []) do
    absolute = Path.expand(path)

    case File.read(absolute) do
      {:ok, source} ->
        opts = Keyword.merge([root: Path.dirname(absolute), file: absolute], opts)
        load_string(source, opts)

      {:error, reason} ->
        {:error,
         Error.new(
           message: "could not read #{inspect(path)}: #{:file.format_error(reason)}",
           stage: :import
         )}
    end
  end

  @doc """
  Parses, expands loops, resolves imports, merges, and fully resolves
  `source` (a complete CASC file's own text, own version header
  included) -- the same pipeline `load_file/2` runs, for a source that
  isn't (yet, or ever) sitting in a real file. Imports using a bare
  (non-`scheme://`) path still need a real `:root` unless registered
  via `:import_schemes`.
  """
  @spec load_string(String.t(), opts()) :: {:ok, term()} | {:error, Error.t() | [Error.t()]}
  def load_string(source, opts \\ []) do
    grammar_opts = Keyword.take(opts, [:root, :file, :import_schemes, :env])

    with {:ok, tree, vars} <- Cooper.Grammar.run_tree(source, grammar_opts),
         resolver_opts = [vars: vars] ++ Keyword.take(opts, [:env, :resolvers, :tags]) do
      Cooper.Resolver.resolve(tree, resolver_opts)
    end
  end
end
