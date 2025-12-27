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
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {ServiceRadarWebNG.Application, []},
      extra_applications: [:logger, :runtime_tools, :swoosh, :telemetry]
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

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      # ServiceRadar Core - Ash domains, cluster, registry
      {:serviceradar_core, path: "../elixir/serviceradar_core"},

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
      {:oban_web, "~> 2.10"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:heroicons,
       git: "https://github.com/tailwindlabs/heroicons.git",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:rustler, "~> 0.36"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:datasvc, path: "../elixir/datasvc"},

      # Ash Framework - Phoenix integration (UI components)
      {:ash_authentication_phoenix, "~> 2.0"},
      {:ash_phoenix, "~> 2.0"},

      # Note: ash_admin comes from serviceradar_core dependency

      # OpenAPI spec generation for AshJsonApi
      {:open_api_spex, "~> 3.16"},

      # Igniter - code generation and refactoring
      {:igniter, "~> 0.5", only: [:dev, :test]}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind serviceradar_web_ng", "esbuild serviceradar_web_ng"],
      "assets.deploy": [
        "tailwind serviceradar_web_ng --minify",
        "esbuild serviceradar_web_ng --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      precommit_lint: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "credo"]
    ]
  end
end
