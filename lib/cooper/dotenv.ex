defmodule Cooper.Dotenv do
  @moduledoc """
  Builds the map `Cooper`'s `${...}` resolution (CASC.md §7.2) reads
  from. Called from `Cooper.load_file/2`/`load_string/2` on every
  single call, hit or miss, cached or not -- and again by
  `Cooper.Cache`'s own `watch_env` poll tick, so a `.env` file edit is
  detected the same way a real `System.put_env/2` is. Not a separate
  pipeline stage callers normally reach for directly, but its own
  module (rather than inlined) because the layering rules below are
  non-trivial enough to want one place to read, and one place to test,
  them.

  ## Layering

  Five layers, later winning, `Dotenvy.source/2`'s own convention:

    1. `.env`
    2. `.env.<env>` -- `<env>`, in order: the explicit `:dotenv_env`
       option; else live `Mix.env/0` when Mix is loaded (true for
       `mix run`/`mix test`/`iex -S mix`, false for a compiled OTP
       release); else `Application.compile_env(:cooper, :dotenv_env)`
       -- baked in at *the host application's own* compile time, the
       only way left to auto-detect an environment in a release. That
       last one only fires if the host app opts in with `config
       :cooper, dotenv_env: config_env()` in its own
       `config/config.exs` -- deliberately not something Cooper can
       default on its own (see `compiled_env/0`'s own comment for why
       naively reading `Mix.env/0` from inside Cooper's own source
       could never work here). No match at all leaves `<env>` (and
       this whole layer) absent.
    3. `.env.local`
    4. `System.get_env/0` -- the real environment outranks every file.
    5. the `:env` option, if the caller passed one -- always the final,
       highest-precedence override, on top of every layer above it.

  **The real environment wins over `.env` files.** A deployment sets
  variables in the environment it controls; a file sitting in the working
  directory must not silently beat them. This also matches what dotenv
  implementations in other ecosystems do by default -- Ruby's and Node's
  both decline to overwrite an already-set variable -- and what
  twelve-factor configuration expects.

  Pass `dotenv_override: true` for the opposite order, where the files
  outrank the real environment. That is occasionally what a developer
  wants locally, to shadow something exported in their shell, but it is
  a deliberate choice rather than the default.

  All of 2-4 are optional -- a missing file is silently skipped, never
  a load-time error. `.env.<env>` in particular is *expected* to be
  absent for every environment but the current one.

  All paths are resolved relative to the current working directory,
  deliberately not `:root` (`load_file/2`'s config-file directory) --
  `.env` files live at the project root regardless of where the CASC
  file being loaded happens to sit.

  **`:env` is an override layer, not a replacement.** Passing `env:
  %{"FOO" => "bar"}` does not isolate resolution from the real
  environment or `.env` files -- it guarantees `FOO` resolves to
  `"bar"` specifically, while every other `${...}` reference still
  falls through to `.env`/`.env.local`/the real OS environment. There
  is currently no option that fully replaces every layer below it; a
  test that needs a `${...}` reference to resolve to a specific,
  guaranteed-deterministic value should give that name an explicit
  entry in `:env` rather than relying on it being otherwise unset.

  ## Enabling

  `.env` file loading (layers 2-4) is on by default; `dotenv: false`
  disables just those three layers -- `System.get_env/0` and an
  explicit `:env` still apply either way. If `:dotenvy` isn't
  installed: the *default*-enabled case silently no-ops (same as if no
  `.env` files existed), but an explicit `dotenv: true` with the
  dependency missing is a load-time error naming it -- asking for it by
  name and not getting it is a real misconfiguration, not something to
  paper over.
  """

  alias Ichor.Error

  # `Application.compile_env/3` must be called from the module body --
  # see `compiled_env/0`'s own comment for why this exists at all.
  @compiled_dotenv_env Application.compile_env(:cooper, :dotenv_env)

  @base_file ".env"
  @local_file ".env.local"

  @type opts :: [
          env: %{optional(String.t()) => String.t()},
          dotenv: boolean(),
          dotenv_env: atom() | nil,
          dotenv_files: [String.t()],
          dotenv_override: boolean()
        ]

  @doc """
  Resolves the final env map for `opts` (the same options `load_file/2`/
  `load_string/2` take): the `.env` files layered per the moduledoc
  above unless disabled, then `System.get_env/0`, with `:env` (if given)
  applied last as the final override.

  Pass `dotenv_override: true` to put the files above the real
  environment instead.
  """
  @spec env(opts()) :: {:ok, %{String.t() => String.t()}} | {:error, Error.t()}
  def env(opts) do
    overrides = Keyword.get(opts, :env, %{})

    case enabled(opts) do
      false -> {:ok, Map.merge(System.get_env(), overrides)}
      {true, required?} -> load(overrides, opts, required?)
    end
  end

  defp enabled(opts) do
    case Keyword.fetch(opts, :dotenv) do
      {:ok, true} -> {true, true}
      {:ok, false} -> false
      :error -> {true, false}
    end
  end

  defp load(overrides, opts, required?) do
    if Code.ensure_loaded?(Dotenvy) do
      sources = sources(opts) ++ [overrides]

      case Dotenvy.source(sources, require_files: false) do
        {:ok, env} ->
          {:ok, env}

        {:error, reason} ->
          {:error,
           Error.new(message: "dotenv loading failed: #{inspect(reason)}", stage: :dotenv)}
      end
    else
      missing_dependency(overrides, required?)
    end
  end

  defp missing_dependency(overrides, false), do: {:ok, Map.merge(System.get_env(), overrides)}

  defp missing_dependency(_overrides, true) do
    {:error,
     Error.new(
       message:
         "dotenv: true requires the optional :dotenvy dependency -- add " <>
           "{:dotenvy, \"~> 1.1\"} to your own mix.exs deps",
       stage: :dotenv
     )}
  end

  # Orders the file layers and the real environment, lowest precedence first.
  #
  # The real environment last by default: a deployment controls it, and a file
  # in the working directory silently outranking it is a debugging trap rather
  # than a feature. `dotenv_override: true` restores the opposite order for a
  # developer who wants a file to shadow their shell.
  defp sources(opts) do
    if Keyword.get(opts, :dotenv_override, false) do
      [System.get_env() | files(opts)]
    else
      files(opts) ++ [System.get_env()]
    end
  end

  defp files(opts) do
    case Keyword.fetch(opts, :dotenv_files) do
      {:ok, files} -> files
      :error -> [@base_file] ++ env_file(opts) ++ [@local_file]
    end
  end

  defp env_file(opts) do
    case current_env(opts) do
      nil -> []
      env -> [".env.#{env}"]
    end
  end

  defp current_env(opts) do
    case Keyword.get(opts, :dotenv_env, :auto) do
      :auto -> mix_env() || compiled_env()
      env -> env
    end
  end

  defp mix_env do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      Mix.env()
    end
  end

  # A release has no live `Mix` to call -- this is the only way to
  # still auto-detect an environment there, and it only works if the
  # *consuming* app opts in with `config :cooper, dotenv_env:
  # config_env()` in its own `config/config.exs`. Deliberately not
  # `Application.get_env/3` read from a plain module attribute: Mix
  # compiles *every* dependency (Cooper included) under `Mix.env() ==
  # :prod`, always, regardless of what the host app is actually
  # building for (documented in `mix help deps`, under "Dependencies
  # environment" -- confirmed empirically, not assumed), so capturing
  # `Mix.env()` directly inside Cooper's own source would silently
  # bake in `:prod` no matter what. `Application.compile_env/3` (see
  # `@compiled_dotenv_env` above -- the macro only works at the module
  # body, not from inside a function) reads config resolved from the
  # *host* app's own `config/config.exs` instead, which genuinely does
  # see the host's real build env, and gets Mix's automatic compile-
  # time/runtime consistency check for free (a release warns at boot if
  # the two ever disagree) -- neither of which a bare
  # `Application.get_env/3` would provide.
  defp compiled_env, do: @compiled_dotenv_env
end
