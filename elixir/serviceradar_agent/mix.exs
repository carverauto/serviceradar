defmodule ServiceRadarAgent.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :serviceradar_agent,
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
      mod: {ServiceRadarAgent.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # ServiceRadar Core - shared domains, cluster, registry
      {:serviceradar_core, path: "../serviceradar_core"},

      # gRPC for communicating with external checkers (Go-based)
      {:grpc, "~> 0.9"},
      {:protobuf, "~> 0.15"},

      # HTTP client for health checks
      {:req, "~> 0.5"},

      # JSON encoding
      {:jason, "~> 1.4"},

      # Distributed cluster
      {:libcluster, "~> 3.4"},

      # Testing
      {:mox, "~> 1.0", only: :test}
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
      serviceradar_agent: [
        include_executables_for: [:unix],
        applications: [
          runtime_tools: :permanent,
          serviceradar_core: :permanent,
          serviceradar_agent: :permanent
        ],
        steps: [:assemble, :tar],
        rel_templates_path: "rel"
      ]
    ]
  end
end
