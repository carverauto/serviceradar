# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :serviceradar_web_ng, :scopes,
  user: [
    default: true,
    module: ServiceRadarWebNG.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :ng_users,
    test_data_fixture: ServiceRadarWebNG.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :serviceradar_web_ng,
  namespace: ServiceRadarWebNG,
  # Use ServiceRadar.Repo from serviceradar_core
  ecto_repos: [ServiceRadar.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the shared repo from serviceradar_core
# Ash manages all migrations in serviceradar_core/priv/repo/migrations/
config :serviceradar_core, ServiceRadar.Repo,
  migration_source: "ash_schema_migrations"

# Ash Framework Configuration
config :serviceradar_web_ng,
  ash_domains: [
    ServiceRadar.Identity,
    ServiceRadar.Inventory,
    ServiceRadar.Infrastructure,
    ServiceRadar.Monitoring,
    ServiceRadar.Observability,
    ServiceRadar.Edge
  ]

# Ash configuration
config :ash,
  include_embedded_source_by_default?: false,
  default_page_type: :keyset,
  policies: [
    no_filter_static_forbidden_reads?: false,
    show_policy_breakdowns?: true
  ]

# AshPostgres configuration
config :ash_postgres,
  manage_migrations?: true

# Feature flags for Ash integration
# Note: All Ash domains are now active by default. The ash_srql_adapter flag
# controls whether SRQL queries for devices/pollers/agents route through Ash.
config :serviceradar_web_ng, :feature_flags,
  ash_srql_adapter: true

config :serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL

# Oban job processing configuration
# Configured in serviceradar_core, but we add web-specific cron jobs here
config :serviceradar_core, Oban,
  repo: ServiceRadar.Repo,
  queues: [
    default: 10,
    maintenance: 2,
    # AshOban queues
    alerts: 5,
    service_checks: 10,
    notifications: 5,
    onboarding: 3,
    events: 10,
    sweeps: 20,
    edge: 10,
    integrations: 5
  ],
  plugins: [
    # Built-in Cron plugin for system maintenance jobs (non-Ash resources)
    {Oban.Plugins.Cron,
     crontab: [
       # Refresh trace summaries materialized view every 2 minutes
       {"*/2 * * * *", ServiceRadarWebNG.Jobs.RefreshTraceSummariesWorker, queue: :maintenance}
     ]},
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}  # Keep jobs for 7 days
  ],
  peer: Oban.Peers.Database

# AshOban configuration
config :ash_oban,
  oban_name: Oban

# Configure the endpoint
config :serviceradar_web_ng, ServiceRadarWebNGWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ServiceRadarWebNGWeb.ErrorHTML, json: ServiceRadarWebNGWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ServiceRadarWebNG.PubSub,
  live_view: [signing_salt: "3bWAu579"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :serviceradar_web_ng, ServiceRadarWebNG.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  serviceradar_web_ng: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  serviceradar_web_ng: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Pin Rustler temp dir to an explicitly writable path when provided by the build system
config :rustler, :tmp_dir, System.get_env("RUSTLER_TMPDIR") || System.tmp_dir!()

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
