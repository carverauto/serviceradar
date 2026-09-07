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
      package: package(),
      # Keep Hex's advisory gate aligned with the documented, temporary
      # exceptions in .deps_audit_ignore. See that file for mitigations and
      # removal criteria for each advisory.
      hex: [
        ignore_advisories: [
          "EEF-CVE-2026-43966",
          "EEF-CVE-2026-43969",
          "EEF-CVE-2026-43971",
          "GHSA-g2wm-735q-3f56",
          "GHSA-w4f7-4cxr-rv3c"
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [
        :logger,
        :ssl,
        # Required by ServiceRadar.HTTP.EgressClient's :httpc transport.
        :inets,
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
    # dev/test only. Under :prod this is pure cost with a sharp edge: the boundary compiler
    # calls Boundary.Definition.get/2 for EVERY module of every checked app, which reaches
    # `boundary.__info__(:attributes)` and so forces each module to load. For a module backed
    # by a Rustler NIF that runs @on_load -- and cross-compiling to arm64 means dlopen()ing an
    # aarch64 .so on the amd64 build machine, which glibc reports as
    # "cannot open shared object file: No such file or directory" (elf/dl-load.c sets ENOENT
    # by hand on an e_machine mismatch). The compile then dies in :boundary with
    # `function ...Native.__info__/1 is undefined`, naming neither NIFs nor architecture.
    #
    # Nothing is lost: boundary checks run in dev and test, which is where `make test` and the
    # editor exercise them. //elixir/datasvc has been written this way already.
    if Mix.env() in [:dev, :test], do: [:boundary], else: []
  end

  defp deps do
    [
      # SRQL shared library for query parsing and execution
      {:serviceradar_srql, path: "../serviceradar_srql"},

      # Ash Framework
      # CVE-2026-67579: keyset cursor injection is fixed in 3.31.3.
      {:ash, "~> 3.31.3"},
      {:ash_postgres, "~> 2.4"},
      {:ash_oban, "~> 0.4"},
      {:ash_state_machine, "~> 0.2"},
      {:ash_json_api, "~> 1.4"},
      {:ash_paper_trail, "~> 0.6.0"},
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
      {:gnat, "~> 1.15"},
      {:connection, path: "../../third_party/hex_vendored/connection", override: true},

      # Broadway for high-throughput event processing
      {:broadway, "~> 1.1"},
      {:broadway_dashboard, "~> 0.4"},

      # gRPC client for serviceradar-sync communication
      {:grpc, "~> 1.0"},
      # grpc 1.0 made transport adapters optional and pins the default Gun
      # adapter to `~> 2.2.0`. Keep the CVE-patched gun 2.4.1 (Phase-1) and force
      # it via override so the default Gun client adapter stays available.
      {:gun, "~> 2.4", override: true},
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
      {:opentelemetry_oban,
       path: "../../third_party/hex_vendored/opentelemetry_oban", override: true},
      # Override: opentelemetry_oban declares ~> 0.2 but works fine with 1.27;
      # upstream fix pending (open-telemetry/opentelemetry-erlang-contrib#528).
      {:opentelemetry_semantic_conventions, "~> 1.27", override: true},

      # OTLP log export via OTP :logger handler
      {:opentelemetry_experimental, "~> 0.5"},
      {:opentelemetry_api_experimental, "~> 0.5"},

      # Utilities
      {:jason, "~> 1.4"},
      {:rustler, "~> 0.38"},
      {:ex_json_schema, "~> 0.10"},
      {:elixir_uuid, path: "../../third_party/hex_vendored/elixir_uuid"},
      {:file_system, "~> 1.0"},
      {:yaml_elixir, "~> 2.12"},
      {:req, "~> 0.7"},
      # Bundle CA certs for minimal containers (core-elx/web-ng releases) so HTTPS works.
      {:castore, "~> 1.0"},
      {:geolix_adapter_mmdb2, "~> 0.6.0"},

      # Policy SAT solver for Ash policies
      {:simple_sat, "~> 0.1"},

      # Email (auth senders and the native notification email transport).
      # `gen_smtp` is what makes `Swoosh.Adapters.SMTP` exist at runtime: swoosh
      # declares it *optional*, so without it an SMTP relay configuration
      # compiles, deploys, and then fails at the first send. It is a direct
      # dependency rather than an optional one for exactly that reason.
      {:swoosh, "~> 1.5"},
      {:gen_smtp, "~> 1.2"},

      # Password hashing (for authentication)
      {:bcrypt_elixir, "~> 3.0"},

      # Development & Testing
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ash_credo, "~> 0.7", only: [:dev, :test], runtime: false},
      {:boundary, "~> 0.10.4", runtime: false},
      {:ex_dna, "~> 1.3", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sourceror, "~> 1.7", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1", only: [:dev], runtime: false}
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
