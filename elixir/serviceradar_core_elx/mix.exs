defmodule ServiceRadarCoreElx.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :serviceradar_core_elx,
      version: @version,
      elixir: "~> 1.17",
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

  defp deps do
    [
      # ServiceRadar Core - shared domains, repo, cluster, registry
      {:serviceradar_core, path: "../serviceradar_core"},

      # Distributed cluster
      {:libcluster, "~> 3.4"},

      # Minimal gRPC footprint for sync/checker coordination
      {:grpc, "~> 0.9"},
      {:protobuf, "~> 0.15"}
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
        steps: [:assemble, :tar],
        rel_templates_path: "rel"
      ]
    ]
  end
end
