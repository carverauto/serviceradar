defmodule ServiceRadarObjectStorage.MixProject do
  use Mix.Project

  def project do
    [
      app: :serviceradar_object_storage,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      releases: [
        serviceradar_object_storage: [
          include_executables_for: [:unix],
          include_erts: &shipped_erts/0,
          applications: [ex_unit: :none]
        ]
      ],
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
  defp shipped_erts, do: System.get_env("SERVICERADAR_RELEASE_ERTS") || true
end
