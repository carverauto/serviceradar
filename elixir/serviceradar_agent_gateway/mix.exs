defmodule ServiceRadarAgentGateway.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :serviceradar_agent_gateway,
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
      extra_applications: [
        :logger,
        :ssl,
        :crypto,
        :public_key,
        :phoenix_pubsub,
        :horde,
        :grpc,
        :ranch,
        :opentelemetry,
        :opentelemetry_experimental
      ],
      mod: {ServiceRadarAgentGateway.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp boundary_compilers do
    if Mix.env() in [:dev, :test], do: [:boundary], else: []
  end

  defp deps do
    [
      # ServiceRadar Core - shared domains, cluster, registry
      {:serviceradar_core, path: "../serviceradar_core"},

      # HTTP client for health checks
      {:req, "~> 0.5"},

      # JSON encoding
      {:jason, "~> 1.4"},

      # Distributed cluster (libcluster comes from serviceradar_core, but we need it here for config)
      {:libcluster, "~> 3.4"},

      # Testing
      {:mox, "~> 1.0", only: :test},
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
      serviceradar_agent_gateway: [
        include_executables_for: [:unix],
        applications: [
          runtime_tools: :permanent,
          serviceradar_agent_gateway: :permanent
        ],
        steps: [:assemble],
        rel_templates_path: "rel"
      ]
    ]
  end
end
