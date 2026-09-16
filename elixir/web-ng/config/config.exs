# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

alias ServiceRadar.Automation.Ansible
alias ServiceRadar.Automation.Callbacks
alias ServiceRadar.Automation.Northbound

# Ash configuration
config :ash,
  include_embedded_source_by_default?: false,
  default_page_type: :keyset,
  policies: [
    no_filter_static_forbidden_reads?: false,
    show_policy_breakdowns?: true
  ]

# AshOban configuration
config :ash_oban,
  oban_name: Oban

# AshPostgres configuration
config :ash_postgres,
  manage_migrations?: true

# Configure esbuild (the version is required)
# Note: The JDM editor uses monaco-editor which requires font loaders
config :esbuild,
  version: "0.25.4",
  serviceradar_web_ng: [
    # Keep react/react-dom aliases in lockstep with assets/package.json build:js.
    # Without them, component/node_modules can pull a second React and hooks crash
    # with "Cannot read properties of null (reading 'useState')" on remote-access pages.
    args:
      ~w(js/app.js js/theme_init.js --bundle --target=es2022 --outdir=../priv/static/assets/js --public-path=/assets/js --external:/fonts/* --external:/images/* --alias:@=. --alias:react=./node_modules/react --alias:react-dom=./node_modules/react-dom --alias:stream=stream-browserify --loader:.ttf=file --loader:.woff=file --loader:.woff2=file --loader:.wasm=file),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

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
    :user_agent,
    :relay_session_id,
    :viewer_id
  ]

# The credentials API receives provider-specific material under `values`.
# Filter the entire envelope before Phoenix formats request parameters.
config :phoenix, :filter_parameters, ["password", "token", "secret", "values"]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Phoenix React NG - React rendering for components (GoRules JDM editor)
# Bun runtime renders React components, LiveView handles the interactivity
config :phoenix_react_ng, Phoenix.ReactServer,
  runtime: Phoenix.ReactServer.Runtime.Bun,
  component_base: Path.expand("../assets/component/src", __DIR__),
  render_timeout: 5_000,
  cache_ttl: 60

# Pin Rustler temp dir to an explicitly writable path when provided by the build system
config :rustler, :tmp_dir, System.get_env("RUSTLER_TMPDIR") || System.tmp_dir!()

# Oban job processing configuration
# web-ng only processes jobs, it does NOT schedule them
# core-elx is the Oban coordinator and handles all scheduled/cron jobs
config :serviceradar_core, Oban,
  engine: Oban.Engines.Basic,
  repo: ServiceRadar.Repo,
  prefix: "platform",
  # Keep :integrations runtime-only. Config deep-merges queue keywords, so a
  # compile-time default would survive WEB_NG_OBAN_QUEUE_INTEGRATIONS=0.
  queues: [
    default: 10,
    # AshOban queues
    alerts: 5,
    service_checks: 10,
    notifications: 5,
    onboarding: 3,
    events: 10,
    sweeps: 20,
    edge: 10
  ],
  plugins: [
    # Keep jobs for 7 days
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}
    # No Cron plugin - core-elx handles all scheduled jobs
  ],
  peer: {Oban.Peers.Database, []}

# Configure the shared repo from serviceradar_core
# Ash manages all migrations in serviceradar_core/priv/repo/migrations/
config :serviceradar_core, ServiceRadar.Repo, migration_source: "ash_schema_migrations"
config :serviceradar_core, :dashboard_packages, default_visibility: :public

# Heartbeats still persist as logs.internal.* in CNPG. The live.logs.*
# fan-out is core-only; web-ng's NATS identity cannot publish it.
config :serviceradar_core, :internal_log_live_nats, false

config :serviceradar_core, :plugin_storage,
  backend: :jetstream,
  upload_ttl_seconds: 900,
  download_ttl_seconds: 900,
  max_upload_bytes: 52_428_800,
  jetstream_bucket: "serviceradar_plugins",
  jetstream_replicas: 1,
  jetstream_storage: :file

# Also register domains for serviceradar_core OTP app (domains are defined there)
config :serviceradar_core,
  ash_domains: [
    ServiceRadar.AgentConfig,
    ServiceRadar.Credentials,
    ServiceRadar.Dashboards,
    ServiceRadar.Camera,
    ServiceRadar.CompositeChecks,
    ServiceRadar.Identity,
    ServiceRadar.Inventory,
    ServiceRadar.Infrastructure,
    ServiceRadar.Monitoring,
    ServiceRadar.Notifications,
    ServiceRadar.Observability,
    ServiceRadar.ColdTier,
    ServiceRadar.PrefixTags,
    ServiceRadar.Edge,
    ServiceRadar.Integrations,
    ServiceRadar.Jobs,
    ServiceRadar.Scans,
    ServiceRadar.SweepJobs,
    ServiceRadar.SysmonProfiles,
    ServiceRadar.SNMPProfiles,
    ServiceRadar.NetworkDiscovery,
    ServiceRadar.Plugins,
    ServiceRadar.Spatial,
    ServiceRadar.WifiMap,
    Northbound,
    Ansible,
    Callbacks,
    ServiceRadar.Security
  ]

# Web-ng joins the ERTS cluster but must never host distributed processes —
# agent sessions placed here would pull agent-config compilation
# (SweepCompiler etc.) and other core-elx work onto the web tier.
config :serviceradar_core, host_distributed_processes: false

# Web-ng must also NOT join the Horde registry CRDT mesh. Every Horde member is
# a DeltaCrdt node whose random `node_id` lingers permanently in the merged CRDT
# state, and web-ng rolls frequently — so each rollout would inject a fresh,
# uncollectable dot into the shared causal context, bloating it without bound.
# web-ng only *reads* the registry; those reads are RPC'd to a core node (which
# stays a member), so leaving the mesh is transparent. See
# ServiceRadar.ProcessRegistry.join_process_registry?/0.
config :serviceradar_core, join_process_registry: false

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

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :serviceradar_web_ng, ServiceRadarWebNG.Mailer, adapter: Swoosh.Adapters.Local

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

# Security headers plug. The CSP body is set by the router's
# `put_secure_browser_headers/2` call (already covers script-src,
# style-src, mapbox tile hosts, etc.); this plug appends a
# `report-uri` and optionally rewrites the header to
# `content-security-policy-report-only` during the rollout window.
# Flip `csp_mode` to `:enforce` once reports have been observed for
# at least a week.
config :serviceradar_web_ng, ServiceRadarWebNGWeb.Plugs.SecurityHeaders,
  csp_mode: :report_only,
  csp_report_uri: "/api/security/csp-report"

config :serviceradar_web_ng, :allow_insecure_metadata_urls, false

# Local-login break-glass + SSO toggle. Overridden at runtime from
# SERVICERADAR_AUTH_FORCE_LOCAL_LOGIN / SERVICERADAR_AUTH_DISABLE_SSO (see
# config/runtime.exs). Default off: server-side local-login policy is governed by the
# auth mode plus the per-account `local_login_enabled` flag.
config :serviceradar_web_ng, :auth,
  force_local_login: false,
  disable_sso: false

config :serviceradar_web_ng, :client_ip,
  trust_x_forwarded_for: false,
  trusted_proxy_cidrs: []

# SEED VALUES, not the live source of truth. Plugin catalog sources are rows in
# `platform.plugin_repositories`; the migration that created that table seeded the
# built-in row from `repo_url`, `index_asset_name` and the trusted signing keys
# below. Every import -- foreground and background -- now resolves a repository
# row and verifies against *that repository's* key. These keys remain the
# fallback for callers that pass none (the importer's unit tests, and any
# package whose source is not a registered repository).
config :serviceradar_web_ng, :first_party_plugin_import,
  repo_url: "https://github.com/carverauto/serviceradar",
  index_asset_name: "serviceradar-wasm-plugin-index.json",
  auto_sync_enabled: false,
  sync_release_limit: 10,
  sync_interval_seconds: 3_600,
  cosign_binary: "cosign",
  # Verification key for the first-party plugin artifacts published from the
  # repo_url above. It pairs with that default: a hardcoded first-party source
  # with no key to verify it against makes CosignVerifier fail closed, which is
  # how every install that did not hand-set a key ended up unable to import any
  # plugin at all. Public release key, byte-identical to docs/cosign.pub, kept in
  # step by //:first_party_plugin_cosign_key_consistency_test.
  cosign_public_key: """
  -----BEGIN PUBLIC KEY-----
  MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEhJcdPbybyipSl8sNHSKStAYiqhP7
  cp6jIdZ3L4AkL/WI9oFn5xqJSnwTC29cz+JN/bXzWE807+iPS/DOl3C9EQ==
  -----END PUBLIC KEY-----
  """,
  cosign_public_key_file: nil

config :serviceradar_web_ng, :god_view_enabled, false
config :serviceradar_web_ng, :mcp_client_credentials_enabled, true
config :serviceradar_web_ng, :mcp_enabled, false
config :serviceradar_web_ng, :mcp_idp_refresh_client, ServiceRadarWebNGWeb.Auth.OIDCClient
config :serviceradar_web_ng, :mcp_refresh_ttl_seconds, 8 * 3600

config :serviceradar_web_ng, :native_addon_import,
  repo_url: "https://github.com/carverauto/serviceradar",
  index_asset_name: "serviceradar-native-addon-index.json",
  auto_sync_enabled: false,
  sync_release_limit: 10,
  sync_interval_seconds: 3_600,
  auto_approve_addon_ids: []

config :serviceradar_web_ng, :object_store_retention,
  enabled?: false,
  dry_run?: true,
  plugin_orphan_grace_seconds: 604_800

config :serviceradar_web_ng, :plugin_storage,
  backend: :jetstream,
  upload_ttl_seconds: 900,
  download_ttl_seconds: 900,
  max_upload_bytes: 52_428_800,
  jetstream_bucket: "serviceradar_plugins",
  jetstream_replicas: 1,
  jetstream_storage: :file

config :serviceradar_web_ng, :plugin_verification,
  require_gpg_for_github: false,
  allow_unsigned_uploads: true,
  trusted_github_signers: [],
  trusted_github_owners: [],
  trusted_github_repositories: [],
  # Ed25519 public key the release pipeline signs first-party Wasm plugin uploads with.
  # first_party_importer/3 rejects the whole import with :trusted_upload_signers_not_configured
  # when this map is empty, so an empty default meant no install could import a first-party
  # plugin -- the same failure as an unset cosign_public_key, one gate further in. Public
  # verification key, not a secret; kept in step by
  # //:first_party_plugin_cosign_key_consistency_test.
  # Fallback only. A package imported from a registered repository is verified
  # against that repository's `signing_public_key` instead of this map; see
  # `Packages.repository_policy/2`.
  trusted_upload_signing_keys: %{
    "serviceradar-first-party-v1" => "L+H5fG0eEraBsWAd2aKMzK7I+AMhbnSxlOKny5/+dLo=",
    "serviceradar-first-party-v2" => "2KMsaqvof357MV3RQl4/0DNXfF6+eIMQ+qjDJfL/N8I="
  }

config :serviceradar_web_ng, :saml_assertion_max_validity_seconds, 300

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

# Session configuration for browser-authenticated users
config :serviceradar_web_ng, :session,
  idle_timeout_seconds: 60 * 60,
  absolute_timeout_seconds: 30 * 24 * 60 * 60

# Session cookie configuration. These values are *defaults for
# development* — they're shipped in source so the dev build works
# out of the box. Production deployments MUST override them via
# `config/prod.exs` (or a release config) sourced from environment
# variables (SESSION_SIGNING_SALT, SESSION_ENCRYPTION_SALT,
# SESSION_COOKIE_SECURE). The cookie's confidentiality also depends
# on SECRET_KEY_BASE, which is already required from the environment
# in `config/runtime.exs`.
#
# DO NOT TREAT THESE STRINGS AS SECRETS. They are public placeholders;
# any deployment that wants real isolation must override them.
config :serviceradar_web_ng, :session,
  signing_salt: "dev-signing-salt-replace-in-prod",
  encryption_salt: "dev-encryption-salt-replace-in-prod",
  secure: false

config :serviceradar_web_ng, :srql_catalog, {ServiceRadarWebNGWeb.SRQL.Catalog, :for_scope}
config :serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL
config :serviceradar_web_ng, :srql_query_timeout_ms, 15_000

# Ash Framework Configuration
config :serviceradar_web_ng,
  ash_domains: [
    ServiceRadar.AgentConfig,
    ServiceRadar.Credentials,
    ServiceRadar.Dashboards,
    ServiceRadar.Camera,
    ServiceRadar.CompositeChecks,
    ServiceRadar.Identity,
    ServiceRadar.Inventory,
    ServiceRadar.Infrastructure,
    ServiceRadar.Monitoring,
    ServiceRadar.Notifications,
    ServiceRadar.Observability,
    ServiceRadar.ColdTier,
    ServiceRadar.PrefixTags,
    ServiceRadar.Edge,
    ServiceRadar.Integrations,
    ServiceRadar.Jobs,
    ServiceRadar.Scans,
    ServiceRadar.SweepJobs,
    ServiceRadar.SysmonProfiles,
    ServiceRadar.SNMPProfiles,
    ServiceRadar.NetworkDiscovery,
    ServiceRadar.Plugins,
    ServiceRadar.Spatial,
    ServiceRadar.WifiMap,
    Northbound,
    Ansible,
    Callbacks,
    ServiceRadar.Security,
    ServiceRadarWebNG.Mcp
  ]

config :serviceradar_web_ng,
  namespace: ServiceRadarWebNG,
  # Use ServiceRadar.Repo from serviceradar_core
  ecto_repos: [ServiceRadar.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure tailwind (the version is required).
config :tailwind,
  version: "4.1.12",
  serviceradar_web_ng: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

if System.get_env("SERVICERADAR_SKIP_NIF_COMPILATION") == "1" do
  # Rustler app-env options override module options, including in path dependencies.
  # Skip both cargo metadata and NIF builds for source-only lint; other builds keep them.
  config :serviceradar_core, ServiceRadar.Observability.DispositionKernels, skip_compilation?: true
  config :serviceradar_core, ServiceRadar.Observability.Zen.Native, skip_compilation?: true

  config :serviceradar_srql, ServiceRadarSRQL.Native, skip_compilation?: true

  config :serviceradar_web_ng, ServiceRadarWebNG.Topology.Native, skip_compilation?: true
end

# Import environment-specific config last so it overrides the configuration above.
import_config "#{config_env()}.exs"
