defmodule Cooper.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :cooper,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      name: "Cooper",
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ichor, "~> 0.1"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
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
      files: ~w(lib priv/grammar guides .formatter.exs mix.exs README.md CHANGELOG.md LICENSE.txt)
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
      "LICENSE.txt"
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
