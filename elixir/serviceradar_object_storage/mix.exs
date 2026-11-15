defmodule ServiceRadarObjectStorage.MixProject do
  use Mix.Project

  def project do
    [
      app: :serviceradar_object_storage,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: [
        {:rustler, "~> 0.38"},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:ex_dna, "~> 1.3", only: [:dev, :test], runtime: false},
        {:ex_slop, "~> 0.2.0", only: [:dev, :test], runtime: false},
        {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
        {:jump_credo_checks, "~> 0.1", only: [:dev], runtime: false}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
