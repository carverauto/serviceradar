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
      releases: releases(),
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
      # ServiceRadar Core - shared domains, cluster, registry
      {:serviceradar_core, path: "../serviceradar_core"},
      # gRPC server. grpc 1.0 split the server into the dedicated grpc_server
      # package (the `grpc` client lib, inherited via serviceradar_core, no longer
      # ships GRPC.Server/GRPC.Endpoint/GRPC.Server.Supervisor).
      {:grpc_server, "~> 1.0"},
      # Keep the CVE-patched gun 2.4.1 (Phase-1) for the client adapter; grpc 1.0
      # pins the optional Gun adapter to `~> 2.2.0`, so force it via override.
      {:gun, "~> 2.4", override: true},
      # grpc_core 1.0 conservatively requests protobuf `~> 0.17`; the proto-generated
      # modules across the umbrella target 0.16, so pin it via override (matches the
      # other Elixir apps). grpc_core compiles cleanly against this line.
      {:protobuf, "~> 0.16.0", override: true},
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.18"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},

      # HTTP client for health checks
      # Held with serviceradar_core (a path dep above): a split would run core's
      # code against a Req it was not compiled against. See serviceradar_core.
      {:req, "~> 0.7"},

      # JSON encoding
      {:jason, "~> 1.4"},

      # Distributed cluster (libcluster comes from serviceradar_core, but we need it here for config)
      {:libcluster, "~> 3.4"},

      # Testing
      {:mox, "~> 1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ash_credo, "~> 0.7", only: [:dev, :test], runtime: false},
      {:boundary, "~> 0.10.4", runtime: false},
      {:ex_dna, "~> 1.3", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1", only: [:dev], runtime: false}
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
        include_erts: &shipped_erts/0,
        applications: [
          runtime_tools: :permanent,
          serviceradar_agent_gateway: :permanent
        ],
        # Bazel OCI builds can bake host compile_env keys (e.g. ash) that differ
        # at runtime; match core-elx/web-ng and skip release compile_env validation.
        validate_compile_env: false,
        steps: [:assemble],
        rel_templates_path: "rel"
      ]
    ]
  end

  # Which ERTS the release embeds. `true` -- the default, and what every amd64 build gets --
  # copies ERTS and the OTP applications from the VM running `mix release`, which is wrong
  # the moment the build host and the target differ in architecture. Mix also accepts a path
  # and resolves the OTP applications relative to it, so naming the erts-* directory of a
  # second OTP root redirects VM and NIFs together. //build:elixir_release.bzl sets this
  # variable when it stages such a tree; unset, this is the previous behaviour exactly.
  defp shipped_erts do
    System.get_env("SERVICERADAR_RELEASE_ERTS") || true
  end
end
