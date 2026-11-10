defmodule ServiceRadarNVR.MixProject do
  use Mix.Project

  def project do
    [
      app: :serviceradar_nvr,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      releases: [
        serviceradar_nvr: [include_executables_for: [:unix], include_erts: &shipped_erts/0]
      ],
      deps: deps()
    ]
  end

  def application, do: [mod: {ServiceRadarNVR.Application, []}, extra_applications: [:logger, :crypto]]

  # Cross-built releases embed the target runtime supplied by the Bazel release rule.
  defp shipped_erts, do: System.get_env("SERVICERADAR_RELEASE_ERTS") || true

  defp deps do
    [
      {:serviceradar_recording_metadata, path: "../serviceradar_recording_metadata"},
      {:serviceradar_recording, path: "../serviceradar_recording"},
      {:ecto, "~> 3.14"},
      {:bandit, "~> 1.8"},
      {:mint, "~> 1.11"},
      {:plug, "~> 1.18"},
      {:credo, "~> 1.7", runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.3", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1", only: [:dev], runtime: false}
    ]
  end
end
