defmodule ServiceRadarCore.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/carverauto/serviceradar"

  def project do
    [
      app: :serviceradar_core,
      version: @version,
      elixir: "~> 1.17",
      compilers: boundary_compilers() ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :dev,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [ignore_warnings: ".dialyzer_ignore.exs", plt_add_apps: [:mix]],

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
      extra_applications: [
        :logger,
        :ssl,
        :crypto,
        :public_key,
        :swoosh,
        :telemetry,
        :opentelemetry,
        :opentelemetry_experimental,
        :ash_state_machine
      ],
      mod: {ServiceRadar.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp boundary_compilers do
    [:boundary]
  end

  defp deps do
    [
      # SRQL shared library for query parsing and execution
      {:serviceradar_srql, path: "../serviceradar_srql"},

      # Ash Framework
      {:ash, "~> 3.22"},
      {:ash_postgres, "~> 2.4"},
      {:ash_oban, "~> 0.4"},
      {:ash_state_machine, "~> 0.2"},
      {:ash_json_api, "~> 1.4"},
      {:open_api_spex, "~> 3.16"},
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

      # NATS JetStream for event publishing
      {:jetstream, "~> 0.0.9"},
      {:connection, path: "../connection", override: true},

      # Broadway for high-throughput event processing
      {:broadway, "~> 1.1"},
      {:broadway_dashboard, "~> 0.4"},

      # gRPC client for serviceradar-sync communication
      {:grpc, "~> 0.9"},
      {:protobuf, "~> 0.16.0", override: true},

      # Telemetry
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},

      # OpenTelemetry SDK, API, and OTLP exporter
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry_exporter, "~> 1.10"},

      # OpenTelemetry auto-instrumentation libraries
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_bandit, "~> 0.2"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:opentelemetry_oban, path: "../vendor/opentelemetry_oban", override: true},
      # Override: opentelemetry_oban declares ~> 0.2 but works fine with 1.27;
      # upstream fix pending (open-telemetry/opentelemetry-erlang-contrib#528).
      {:opentelemetry_semantic_conventions, "~> 1.27", override: true},

      # OTLP log export via OTP :logger handler
      {:opentelemetry_experimental, "~> 0.5"},
      {:opentelemetry_api_experimental, "~> 0.5"},

      # Utilities
      {:jason, "~> 1.4"},
      {:ex_json_schema, "~> 0.10"},
      {:elixir_uuid, path: "../elixir_uuid"},
      {:file_system, "~> 1.0"},
      {:yaml_elixir, "~> 2.12"},
      {:req, "~> 0.5"},
      # Bundle CA certs for minimal containers (core-elx/web-ng releases) so HTTPS works.
      {:castore, "~> 1.0"},
      {:geolix_adapter_mmdb2, "~> 0.6.0"},

      # Policy SAT solver for Ash policies
      {:simple_sat, "~> 0.1"},

      # Email (for auth senders)
      {:swoosh, "~> 1.5"},

      # Password hashing (for authentication)
      {:bcrypt_elixir, "~> 3.0"},

      # Development & Testing
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ash_credo, "~> 0.7", only: [:dev, :test], runtime: false},
      {:boundary, "~> 0.10.4", runtime: false},
      {:ex_dna, "~> 1.2", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sourceror, "~> 1.7", only: [:dev, :test], runtime: false}
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
          ServiceRadar.Edge,
          ServiceRadar.NetworkDiscovery
        ],
        Cluster: [
          ServiceRadar.Cluster,
          ServiceRadar.ClusterSupervisor,
          ServiceRadar.ClusterHealth
        ],
        Registry: [
          ServiceRadar.GatewayRegistry,
          ServiceRadar.AgentRegistry
        ],
        SPIFFE: [
          ServiceRadar.SPIFFE
        ]
      ]
    ]
  end
end
