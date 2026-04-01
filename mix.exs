defmodule Rig.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/code-of-kai/rig"

  def project do
    [
      app: :rig,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Rig",
      description: "Pure state machines for Elixir — testable data structures first, optional gen_statem process adapter",
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

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "Rig",
      source_ref: "v#{@version}"
    ]
  end
end
