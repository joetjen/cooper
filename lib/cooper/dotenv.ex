defmodule Cooper.Dotenv do
  @moduledoc """
  Builds the map `Cooper`'s `${...}` resolution (CASC.md §7.2) reads
  from. Called once from `Cooper.load_string/2` -- not a separate
  pipeline stage callers normally reach for directly, but its own
  module (rather than inlined) because the layering rules below are
  non-trivial enough to want one place to read, and one place to test,
  them.

  ## Layering

  Five layers, later winning, `Dotenvy.source/2`'s own convention:

    1. `System.get_env/0` -- always the floor, whether or not `:env` is
       passed.
    2. `.env`
    3. `.env.<env>` -- `<env>` from `:dotenv_env`, defaulting to
       `Mix.env/0` when Mix is loaded. A compiled OTP release typically
       doesn't have Mix available at runtime, so `<env>` (and this
       whole layer) is silently absent there unless `:dotenv_env` is
       passed explicitly.
    4. `.env.local`
    5. the `:env` option, if the caller passed one -- always the final,
       highest-precedence override, on top of every layer above it.

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

  @base_file ".env"
  @local_file ".env.local"

  @type opts :: [
          env: %{optional(String.t()) => String.t()},
          dotenv: boolean(),
          dotenv_env: atom() | nil,
          dotenv_files: [String.t()]
        ]

  @doc """
  Resolves the final env map for `opts` (the same options `load_file/2`/
  `load_string/2` take): `System.get_env/0`, `.env`-layered per the
  moduledoc above unless disabled, with `:env` (if given) applied last
  as the final override.
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
      sources = [System.get_env() | files(opts)] ++ [overrides]

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
      :auto -> mix_env()
      env -> env
    end
  end

  defp mix_env do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      Mix.env()
    end
  end
end
