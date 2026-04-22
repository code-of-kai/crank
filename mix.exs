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
      description: "Pure finite state machines (FSM) for Elixir — testable data structures first, optional gen_statem process adapter",
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
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
      files: ~w(lib guides assets .formatter.exs mix.exs README.md LICENSE CHANGELOG.md DESIGN.md)
    ]
  end

  defp docs do
    [
      main: "Crank",
      logo: "assets/logo.jpg",
      source_ref: "v#{@version}",
      extras: [
        "guides/composing-commands.md",
        "guides/hexagonal-architecture.md",
        "CHANGELOG.md",
        "DESIGN.md"
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ]
    ]
  end
end
