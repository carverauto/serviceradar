defmodule ServiceRadarCore.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/carverauto/serviceradar"

  def project do
    [
      app: :serviceradar_core,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :dev,
      deps: deps(),
      aliases: aliases(),

      # Docs
      name: "ServiceRadar Core",
      source_url: @source_url,
      docs: docs(),

      # Package
      description: description(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl, :crypto, :public_key],
      mod: {ServiceRadar.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Ash Framework
      {:ash, "~> 3.4"},
      {:ash_postgres, "~> 2.4"},
      {:ash_authentication, "~> 4.3"},
      {:ash_oban, "~> 0.4"},
      {:ash_state_machine, "~> 0.2"},
      {:ash_json_api, "~> 1.4"},
      {:ash_admin, "~> 0.12"},
      {:ash_cloak, "~> 0.1"},
      {:cloak, "~> 1.1"},

      # Database
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},

      # Distributed systems
      {:horde, "~> 0.9"},
      {:libcluster, "~> 3.4"},

      # Background jobs
      {:oban, "~> 2.18"},

      # Telemetry
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},

      # Utilities
      {:jason, "~> 1.4"},

      # Policy SAT solver for Ash policies
      {:simple_sat, "~> 0.1"},

      # Email (for auth senders)
      {:swoosh, "~> 1.5"},

      # Development & Testing
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      # Don't require database for unit tests - integration tests can use ecto.setup first
      test: ["test"]
    ]
  end

  defp description do
    """
    Core business logic for ServiceRadar distributed monitoring platform.
    Contains Ash domains (Identity, Inventory, Infrastructure, Monitoring, Edge),
    cluster management, partition-namespaced registries, and SPIFFE/SPIRE integration.
    """
  end

  defp package do
    [
      maintainers: ["CarverAuto"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      groups_for_modules: [
        "Ash Domains": [
          ServiceRadar.Identity,
          ServiceRadar.Inventory,
          ServiceRadar.Infrastructure,
          ServiceRadar.Monitoring,
          ServiceRadar.Edge
        ],
        Cluster: [
          ServiceRadar.Cluster,
          ServiceRadar.ClusterSupervisor,
          ServiceRadar.ClusterHealth
        ],
        Registry: [
          ServiceRadar.PollerRegistry,
          ServiceRadar.AgentRegistry
        ],
        SPIFFE: [
          ServiceRadar.SPIFFE
        ]
      ]
    ]
  end
end
