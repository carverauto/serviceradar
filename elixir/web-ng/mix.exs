defmodule ServiceRadarWebNG.MixProject do
  use Mix.Project

  def project do
    [
      app: :serviceradar_web_ng,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      dialyzer: [ignore_warnings: ".dialyzer_ignore.exs", plt_add_apps: [:mix]],
      deps: deps(),
      compilers: boundary_compilers() ++ [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      usage_rules: usage_rules(),
      releases: releases(),
      # Keep Hex's advisory gate aligned with the documented, temporary
      # exceptions in .deps_audit_ignore. See that file for mitigations and
      # removal criteria for each advisory.
      hex: [
        ignore_advisories: [
          "GHSA-4g2h-vm7x-747c",
          "EEF-CVE-2026-43966",
          "EEF-CVE-2026-43969",
          "EEF-CVE-2026-43971",
          "GHSA-g2wm-735q-3f56",
          "GHSA-w4f7-4cxr-rv3c"
        ]
      ]
    ]
  end

  # Explicit release so we can disable validate_compile_env. Bazel builds bake
  # host temp paths into phoenix_react_ng Application.compile_env keys, which
  # then abort Config.Provider boot when runtime config differs.
  defp releases do
    [
      serviceradar_web_ng: [
        include_executables_for: [:unix],
        include_erts: &shipped_erts/0,
        validate_compile_env: false,
        steps: [:assemble]
      ]
    ]
  end

  # Which ERTS the release embeds.
  #
  # `true` -- the default, and what every amd64 build gets -- copies ERTS and the OTP
  # applications from the VM running `mix release`. That is right whenever the build host and
  # the target share an architecture, and wrong the moment they do not: a release assembled on
  # amd64 for arm64 ships an x86-64 beam.smp regardless of what the build system was told.
  #
  # Mix also accepts a path, and resolves the OTP applications relative to it, so pointing at
  # the erts-* directory of a second OTP root redirects the whole runtime -- VM and NIFs both.
  # //build:elixir_release.bzl sets this variable when it stages such a tree; unset, this is
  # exactly the previous behaviour.
  defp shipped_erts do
    System.get_env("SERVICERADAR_RELEASE_ERTS") || true
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {ServiceRadarWebNG.Application, []},
      extra_applications: [
        :logger,
        :runtime_tools,
        :swoosh,
        :telemetry,
        :opentelemetry,
        :opentelemetry_experimental
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
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

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      # {:usage_rules, "~> 1.0", only: [:dev]},  # Commented out for Docker build
      # ServiceRadar Core - Ash domains, cluster, registry
      {:serviceradar_core, path: "../serviceradar_core"},
      {:gnat, "~> 1.15"},
      {:connection, path: "../../third_party/hex_vendored/connection", override: true},

      # SRQL shared library for query parsing and execution
      {:serviceradar_srql, path: "../serviceradar_srql", override: true},

      # Phoenix Web Framework
      {:bcrypt_elixir, "~> 3.0"},
      {:phoenix, "~> 1.8.11"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2"},
      {:stream_data, "~> 1.1"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:broadway_dashboard, "~> 0.4"},
      {:oban_web, "~> 2.10"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ash_credo, "~> 0.7", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1", only: [:dev], runtime: false},
      {:boundary, "~> 0.10.4", runtime: false},
      {:ex_dna, "~> 1.3", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:swoosh, "~> 1.16"},
      {:gen_smtp, "~> 1.2"},
      {:req, "~> 0.7"},
      {:castore, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:elixlsx, "~> 0.6"},
      {:mdex, "~> 0.13"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:datasvc, path: "../datasvc"},
      {:protobuf, "~> 0.16.0", override: true},
      {:permit, "~> 0.4.1"},
      {:permit_phoenix, "~> 0.5.1"},
      {:permit_ecto, "~> 0.3.1", override: true},

      # Ash Framework - Phoenix integration (UI components)
      {:ash_phoenix, "~> 2.0"},

      # MCP server (AshAi.Mcp.Router). Do not add hermes_mcp.
      {:ash_ai, "~> 0.8"},

      # Guardian - JWT token management (replacing AshAuthentication tokens)
      {:guardian, "~> 2.3"},

      # Ueberauth - OAuth2/OIDC/SAML authentication strategies
      {:ueberauth, "~> 0.10"},
      {:ueberauth_oidcc, "~> 0.4"},

      # Samly - SAML 2.0 Service Provider
      {:samly, "~> 1.0"},

      # Note: ash_admin comes from serviceradar_core dependency

      # OpenAPI spec generation for AshJsonApi
      {:open_api_spex, "~> 3.16"},
      {:redoc_ui_plug, "~> 0.2"},

      # Igniter - code generation and refactoring
      {:igniter, "~> 0.5", only: [:dev, :test]},

      # Phoenix React Server - Server-side rendering for React components
      {:phoenix_react_ng, "~> 0.8.5"}
    ]
  end

  defp usage_rules do
    [
      skills: [
        location: ".claude/skills",
        build: [
          "ash-framework": [
            description:
              "Use this skill working with Ash Framework or any of its extensions. Always consult this when making any domain changes, features or fixes.",
            usage_rules: [~r/^ash_/]
          ],
          "phoenix-framework": [
            description:
              "Use this skill working with Phoenix Framework. Consult this when working with the web layer, controllers, views, liveviews etc.",
            usage_rules: [:phoenix, ~r/^phoenix_/]
          ]
        ]
      ]
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    bundle_output = Path.expand("priv/react/server.js", __DIR__)
    bundle_cd = Path.expand("assets/component", __DIR__)
    dev_node_path = "../deps:../_build/dev/lib"
    prod_node_path = "../deps:../_build/prod/lib"

    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["serviceradar.maybe_test"],
      "assets.setup": [
        "cmd --cd assets bun install",
        "cmd --cd assets/component bun install --frozen-lockfile"
      ],
      "assets.build": [
        "compile",
        "cmd --cd assets bun run build:css",
        "cmd --cd assets env NODE_PATH=#{dev_node_path} bun run build:js"
      ],
      "assets.deploy": [
        "cmd --cd assets bun install",
        "cmd --cd assets/component bun install --frozen-lockfile",
        "cmd --cd assets bun run build:css:minify",
        "cmd --cd assets env NODE_PATH=#{prod_node_path} bun run build:js:minify",
        "phx.react.bun.bundle --component-base=assets/component/src --output=#{bundle_output} --cd=#{bundle_cd}",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      precommit_lint: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "credo"],
      # Fast lint for bazel - skips full compilation (bazel build handles that separately)
      precommit_fast: ["deps.unlock --unused", "format --check-formatted", "credo"]
    ]
  end
end
