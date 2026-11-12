defmodule ServiceRadarRecording.MixProject do
  use Mix.Project

  def project do
    [
      app: :serviceradar_recording,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp deps do
    [
      # UUID casting is a data-type dependency; no Ecto SQL adapter or Repo starts.
      {:ecto, "~> 3.14"},
      {:jason, "~> 1.4"},
      {:membrane_core, "1.2.6"},
      {:membrane_h26x_plugin, "0.10.9"},
      {:membrane_mp4_plugin, "0.36.10"},
      {:membrane_h264_format, "0.6.1"},
      {:membrane_cmaf_format, "0.7.2"},
      {:bundlex, github: "membraneframework/bundlex", tag: "v1.5.4", override: true},
      # Keep Ratio's transitive Decimal/Numbers constraints aligned with core.
      {:decimal, "~> 3.1 and >= 3.1.2", override: true},
      {:numbers, "~> 5.2.5", override: true},
      # membrane_opus_format requires Credo in every Mix environment.
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
