defmodule Crank.MixProject do
  use Mix.Project

  @version "1.1.0"
  @source_url "https://github.com/code-of-kai/crank"

  def project do
    [
      app: :crank,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Crank",
      description: "Moore-style pure finite state machines (FSM) for Elixir — testable data structures first, optional gen_statem process adapter",
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Crank.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:stream_data, "~> 1.1", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      name: "crank",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(lib guides assets .formatter.exs mix.exs README.md LICENSE CHANGELOG.md DESIGN.md ROADMAP.md)
    ]
  end

  defp docs do
    [
      main: "Crank",
      logo: "assets/logo.jpg",
      source_ref: "v#{@version}",
      extras: [
        "guides/composing-work.md",
        "guides/hexagonal-architecture.md",
        "guides/transitions-and-guards.md",
        "guides/typing-state-and-memory.md",
        "guides/property-testing.md",
        "guides/boundary-setup.md",
        "guides/suppressions.md",
        "guides/violations/index.md",
        "guides/violations/CRANK_PURITY_001.md",
        "guides/violations/CRANK_PURITY_002.md",
        "guides/violations/CRANK_PURITY_003.md",
        "guides/violations/CRANK_PURITY_004.md",
        "guides/violations/CRANK_PURITY_005.md",
        "guides/violations/CRANK_PURITY_006.md",
        "guides/violations/CRANK_PURITY_007.md",
        "guides/violations/CRANK_DEP_001.md",
        "guides/violations/CRANK_DEP_002.md",
        "guides/violations/CRANK_DEP_003.md",
        "guides/violations/CRANK_TYPE_001.md",
        "guides/violations/CRANK_TYPE_002.md",
        "guides/violations/CRANK_TYPE_003.md",
        "guides/violations/CRANK_RUNTIME_001.md",
        "guides/violations/CRANK_RUNTIME_002.md",
        "guides/violations/CRANK_TRACE_001.md",
        "guides/violations/CRANK_TRACE_002.md",
        "guides/violations/CRANK_META_001.md",
        "guides/violations/CRANK_META_002.md",
        "guides/violations/CRANK_META_003.md",
        "guides/violations/CRANK_META_004.md",
        "guides/violations/CRANK_SETUP_001.md",
        "guides/violations/CRANK_SETUP_002.md",
        "CHANGELOG.md",
        "DESIGN.md",
        "ROADMAP.md"
      ],
      groups_for_extras: [
        Violations: ~r/guides\/violations\/.*/,
        Guides: ~r/guides\/.*/
      ]
    ]
  end
end
