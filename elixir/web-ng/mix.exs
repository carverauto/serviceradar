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
      dialyzer: [ignore_warnings: ".dialyzer_ignore.exs", plt_add_deps: :apps_direct],
      deps: deps(),
      compilers: boundary_compilers() ++ [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      usage_rules: usage_rules()
    ]
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
    [:boundary]
  end

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      # {:usage_rules, "~> 1.0", only: [:dev]},  # Commented out for Docker build
      # ServiceRadar Core - Ash domains, cluster, registry
      {:serviceradar_core, path: "../serviceradar_core"},

      # SRQL shared library for query parsing and execution
      {:serviceradar_srql, path: "../serviceradar_srql", override: true},

      # Phoenix Web Framework
      {:bcrypt_elixir, "~> 3.0"},
      {:phoenix, "~> 1.8.3"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:stream_data, "~> 1.1"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:broadway_dashboard, "~> 0.4"},
      {:oban_web, "~> 2.10"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:boundary, "~> 0.10.4", runtime: false},
      {:ex_dna, "~> 1.2", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:swoosh, "~> 1.16"},
      {:gen_smtp, "~> 1.2"},
      {:req, "~> 0.5"},
      {:castore, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:earmark_parser, "~> 1.4"},
      {:earmark, "~> 1.4"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:datasvc, path: "../datasvc"},
      {:protobuf, "~> 0.16.0", override: true},
      {:permit, "~> 0.3.3"},
      {:permit_phoenix, "~> 0.4.0"},
      {:permit_ecto, github: "curiosum-dev/permit_ecto", ref: "3f5aca703893fe453f9d3d27601e2528bb1a82be", override: true},

      # Ash Framework - Phoenix integration (UI components)
      {:ash_phoenix, "~> 2.0"},

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

      # Igniter - code generation and refactoring
      {:igniter, "~> 0.5", only: [:dev, :test]},

      # Phoenix React Server - Server-side rendering for React components
      {:phoenix_react_server, "~> 0.7.3"}
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
