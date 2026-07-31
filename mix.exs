defmodule Cooper.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :cooper,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      name: "Cooper",
      docs: docs(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      # `:ichor` (`runtime: false`) is invisible to dialyxir's automatic
      # PLT app discovery -- that walks the OTP *runtime*-dependency
      # graph, which `runtime: false` deliberately excludes it from,
      # even though it's compiled and genuinely called by
      # `test/support/vm_parity.ex` under :test. Added explicitly so
      # `Aether.Parser`/`Grammar.Analysis`/`Grammar.VM.*` are in the PLT
      # dialyzer checks that module against.
      dialyzer: [plt_add_apps: [:mix, :ichor], ignore_warnings: ".dialyzer_ignore.exs"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # `mix precommit` chains "test" alongside "format"/"compile"/"credo"/
  # "sobelow"/"dialyzer" -- unlike a bare `mix test`, Mix doesn't
  # special-case the env for a task run *through* an alias, so without
  # this the "test" step in the chain fails outright ("mix test is
  # running in the dev environment"). Running the *whole* alias under
  # :test is also what makes credo/dialyzer see `test/support/`
  # (`Cooper.Test.VMParity`) -- `elixirc_paths/1` above only adds it for
  # :test in the first place.
  def cli do
    [preferred_envs: [precommit: :test]]
  end

  # Run "mix help compile.app" to learn about applications.
  #
  # `mod:` -- new alongside `Cooper.load_file/2`'s default caching:
  # starts `Cooper.Cache`'s GenServer+ETS table, the only thing under
  # `lib/` that runs as a process. Idle (no work, no timers) until the
  # first `load_file/2` call.
  def application do
    [
      extra_applications: [:logger],
      mod: {Cooper.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  #
  # `ichor_runtime` is the only actual runtime dependency -- the ~24
  # modules a `mix ichor.gen`-generated parser calls at runtime (capture
  # dispatch, error formatting, the compiled Tokenizer/Parser, LR/GLR
  # runtime). `ichor` proper (the Aether front-end, `Grammar.Analysis`,
  # both codegen backends -- the bulk of the library) is only ever
  # needed by `mix ichor.gen` itself and by the `Grammar.VM`-backed
  # parity backend under `test/support/` -- `only: [:dev, :test]` keeps
  # it out of a `mix release` build entirely, `runtime: false` keeps it
  # out of the release's applications list even if something pulled it
  # in as a compile-time-only dep. Both are independently published,
  # own repository/release cadence -- `ichor_runtime` is not a
  # subdirectory of `ichor`'s own repo (see its CHANGELOG.md's 0.2.0
  # entry) -- so no `override:`/`git:`/`sparse:` wiring is needed to
  # pull in a matching pair the way there was pre-Hex-publish.
  defp deps do
    [
      # === CODE QUALITY & STATIC ANALYSIS ===
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      # Credo is invoked via `MIX_ENV=test mix credo`
      # Dialyzer is invoked via `MIX_ENV=test mix dialyzer`
      # Sobelow is invoked via `MIX_ENV=test mix sobelow`
      # Coveralls is invoked via `MIX_ENV=test mix coveralls

      # === TESTING ===
      {:mox, "~> 1.2", only: [:dev, :test]},
      {:faker, "~> 0.19", only: [:test]},
      {:stream_data, "~> 1.4", only: [:test]},

      # === DEVELOPMENT TOOLING ===
      # Mix, and Hex are built-in (no deps needed)
      {:ex_doc, "~> 0.40", only: [:dev], runtime: false},
      # ExDoc is invoked via `MIX_ENV=dev mix docs`

      # === RUNTIME ===
      {:ichor_runtime, "~> 0.1.0"},
      {:ichor, "~> 0.2.1", only: [:dev, :test], runtime: false},
      # `optional: true` -- `Cooper.Dotenv` calls into it, but only when
      # `.env` loading actually runs (the default), so an app that never
      # ends up on that path shouldn't be forced to install it. It's
      # deliberately *not* `only: [:dev, :test]`: `.env.prod` loading is
      # meant to work in a real release too.
      {:dotenvy, "~> 1.1", optional: true},
      # Not optional, unlike dotenvy -- `:telemetry.execute/3` is safe
      # (near-zero cost) to call with zero attached handlers, so there's
      # no real "app that never needs it" case to spare from the
      # dependency the way there is for dotenvy's actual file I/O. Tiny,
      # no transitive deps of its own, the de facto standard for this
      # exact "emit events, let 0-to-N handlers attach" pattern across
      # the Elixir ecosystem.
      {:telemetry, "~> 1.2"}
    ]
  end

  # Fast/cheap checks first so a broken commit fails quickly; dialyzer
  # (slowest, especially its first PLT build) runs last.
  defp aliases do
    [
      precommit: [
        "format",
        "compile --warnings-as-errors",
        "credo --strict",
        "sobelow",
        "test",
        "dialyzer"
      ]
    ]
  end

  defp description do
    "Parses and loads CASC config files -- a hierarchical, extensible config " <>
      "language with imports, variables, interpolation, loops, and consumer-" <>
      "registered resolvers/tags -- into native Elixir terms, secrets redacted " <>
      "by default."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/joetjen/cooper"},
      files: ~w(lib priv/grammar guides .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: extras(),
      groups_for_extras: groups_for_extras(),
      groups_for_modules: groups_for_modules()
    ]
  end

  defp extras do
    [
      "README.md",
      "guides/TUTORIAL.md",
      "guides/EXAMPLES.md",
      "guides/CHEATSHEET.md",
      "guides/casc/TUTORIAL.md",
      "guides/casc/CASC.md",
      "guides/casc/CASC_EXAMPLES.md",
      "guides/casc/CASC_CHEATSHEET.md",
      "CHANGELOG.md",
      "CONTRIBUTION.md",
      "LICENSE"
    ]
  end

  defp groups_for_extras do
    [
      CASC: Path.wildcard("guides/casc/*.md")
    ]
  end

  defp groups_for_modules do
    [
      "Public API": [
        Cooper,
        Cooper.Cache,
        Cooper.Secret,
        Cooper.IPv4,
        Cooper.IPv6
      ],
      "Unresolved AST (seen only if you call a pipeline stage directly)": [
        Cooper.Op,
        Cooper.VarDecl,
        Cooper.Block,
        Cooper.Interp.Text,
        Cooper.Ref.Var,
        Cooper.Ref.Env,
        Cooper.Ref.Config,
        Cooper.Ref.Resolver,
        Cooper.Ref.Tagged,
        Cooper.Merge.Layered
      ],
      Pipeline: [
        Cooper.Dotenv,
        Cooper.Grammar,
        Cooper.Actions,
        Cooper.Loop,
        Cooper.Loader,
        Cooper.Merge,
        Cooper.Resolver,
        Cooper.InterpGrammar,
        Cooper.InterpActions,
        Cooper.NativeGrammar,
        Cooper.NativeInterpGrammar
      ],
      Support: [
        Cooper.Literals,
        Cooper.Display,
        Cooper.RefCommon,
        Cooper.CIDR,
        Cooper.Native.ResolverRef
      ]
    ]
  end
end
