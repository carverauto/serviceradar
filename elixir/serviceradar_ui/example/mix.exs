defmodule ServiceRadarUIExample.MixProject do
  use Mix.Project

  def project do
    [
      app: :serviceradar_ui_example,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [
      mod: {ServiceRadarUIExample.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:serviceradar_ui, path: ".."},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_html, "~> 4.1"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:lazy_html, ">= 0.1.0", only: :test},
      # Present so the repo format hook can run `mix format` in this app.
      # The formatter config does not load the Styler plugin.
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      test: ["test"]
    ]
  end
end
