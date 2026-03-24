defmodule ServiceRadarCoreElx.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :serviceradar_core_elx,
      version: @version,
      elixir: "~> 1.17",
      compilers: boundary_compilers() ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl, :crypto, :public_key],
      mod: {ServiceRadarCoreElx.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp boundary_compilers do
    if Mix.env() in [:dev, :test], do: [:boundary], else: []
  end

  defp deps do
    [
      # ServiceRadar Core - shared domains, repo, cluster, registry
      {:serviceradar_core, path: "../serviceradar_core"},

      # Distributed cluster
      {:libcluster, "~> 3.4"},

      # Minimal gRPC footprint for sync/checker coordination
      {:grpc, "~> 0.9"},
      {:membrane_core, "~> 1.2.6"},
      {:membrane_webrtc_plugin, "~> 0.26.3"},
      {:bundlex, github: "membraneframework/bundlex", tag: "v1.5.4", override: true},
      {:elixir_uuid, path: "../elixir_uuid", override: true},
      {:protobuf, "~> 0.16.0", override: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:boundary, "~> 0.10.4", runtime: false},
      {:ex_dna, "~> 1.2", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      test: ["test"]
    ]
  end

  defp releases do
    [
      serviceradar_core_elx: [
        include_executables_for: [:unix],
        applications: [
          runtime_tools: :permanent,
          serviceradar_core: :permanent,
          serviceradar_core_elx: :permanent
        ],
        steps: [:assemble],
        rel_templates_path: "rel"
      ]
    ]
  end
end
