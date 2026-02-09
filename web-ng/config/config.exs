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
config :serviceradar_core, ServiceRadar.Repo, migration_source: "ash_schema_migrations"

# Ash Framework Configuration
config :serviceradar_web_ng,
  ash_domains: [
    ServiceRadar.AgentConfig,
    ServiceRadar.Identity,
    ServiceRadar.Inventory,
    ServiceRadar.Infrastructure,
    ServiceRadar.Monitoring,
    ServiceRadar.Observability,
    ServiceRadar.Edge,
    ServiceRadar.Integrations,
    ServiceRadar.Jobs,
    ServiceRadar.SweepJobs,
    ServiceRadar.SysmonProfiles,
    ServiceRadar.SNMPProfiles,
    ServiceRadar.NetworkDiscovery,
    ServiceRadar.Plugins
  ]

# Also register domains for serviceradar_core OTP app (domains are defined there)
config :serviceradar_core,
  ash_domains: [
    ServiceRadar.AgentConfig,
    ServiceRadar.Identity,
    ServiceRadar.Inventory,
    ServiceRadar.Infrastructure,
    ServiceRadar.Monitoring,
    ServiceRadar.Observability,
    ServiceRadar.Edge,
    ServiceRadar.Integrations,
    ServiceRadar.Jobs,
    ServiceRadar.SweepJobs,
    ServiceRadar.SysmonProfiles,
    ServiceRadar.SNMPProfiles,
    ServiceRadar.NetworkDiscovery,
    ServiceRadar.Plugins
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

# Guardian JWT configuration
# Secret key is loaded from runtime.exs (TOKEN_SIGNING_SECRET or SECRET_KEY_BASE)
config :serviceradar_web_ng, ServiceRadarWebNG.Auth.Guardian,
  issuer: "serviceradar",
  # Secret loaded in runtime.exs
  secret_key: nil,
  # Token lifetimes
  ttl: {1, :hour},
  token_ttl: %{
    "access" => {1, :hour},
    "refresh" => {30, :days},
    "api" => {1, :hour}
  },
  allowed_algos: ["HS256"],
  verify_module: Guardian.JWT,
  allowed_drift: 60_000

# Session configuration for browser-authenticated users
config :serviceradar_web_ng, :session,
  idle_timeout_seconds: 60 * 60,
  absolute_timeout_seconds: 30 * 24 * 60 * 60

config :serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL

config :serviceradar_web_ng, :plugin_storage,
  backend: :filesystem,
  base_path: "/var/lib/serviceradar/plugin-packages",
  upload_ttl_seconds: 900,
  download_ttl_seconds: 900,
  max_upload_bytes: 52_428_800,
  jetstream_bucket: "serviceradar_plugins",
  jetstream_replicas: 1,
  jetstream_storage: :file

config :serviceradar_web_ng, :plugin_verification,
  require_gpg_for_github: false,
  allow_unsigned_uploads: true

# Oban job processing configuration
# web-ng only processes jobs, it does NOT schedule them
# core-elx is the Oban coordinator and handles all scheduled/cron jobs
config :serviceradar_core, Oban,
  engine: Oban.Engines.Basic,
  repo: ServiceRadar.Repo,
  prefix: "platform",
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
    # Keep jobs for 7 days
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}
    # No Cron plugin - core-elx handles all scheduled jobs
  ],
  peer: {Oban.Peers.Database, []}

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
# Note: The JDM editor uses monaco-editor which requires font loaders
config :esbuild,
  version: "0.25.4",
  serviceradar_web_ng: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=. --loader:.ttf=file --loader:.woff=file --loader:.woff2=file),
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

# Phoenix React Server - React rendering for components (GoRules JDM editor)
# Bun runtime renders React components, LiveView handles the interactivity
config :phoenix_react_server, Phoenix.React,
  runtime: Phoenix.React.Runtime.Bun,
  component_base: Path.expand("../assets/component/src", __DIR__),
  render_timeout: 5_000,
  cache_ttl: 60

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :event_type,
    :severity,
    # Auth-related metadata
    :user_id,
    :email,
    :method,
    :timestamp,
    :token_type,
    :jti,
    :reason,
    :type,
    :path,
    :session_started_at,
    :absolute_timeout_seconds,
    :remote_ip,
    :ip,
    :user_agent
  ]

# Pin Rustler temp dir to an explicitly writable path when provided by the build system
config :rustler, :tmp_dir, System.get_env("RUSTLER_TMPDIR") || System.tmp_dir!()

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# OpenTelemetry Configuration
config :opentelemetry, :resource,
  service: [
    name: "serviceradar-web-ng",
    namespace: "serviceradar"
  ]

config :opentelemetry, :processors,
  otel_batch_processor: %{
    exporter: {
      :opentelemetry_exporter,
      %{
        endpoints: ["http://serviceradar-otel:4317"],
        protocol: :grpc
      }
    }
  }

# Ash OpenTelemetry
config :ash, :tracer, [
  Ash.Tracer.OpenTelemetry
]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
