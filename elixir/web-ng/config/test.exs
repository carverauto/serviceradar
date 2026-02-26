import Config

# Mark this as test environment for single-deployment defaults
config :serviceradar_web_ng, :env, :test
config :serviceradar_web_ng, :god_view_runtime_graph_auto_refresh, false

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
cnpg_ssl_mode = System.get_env("CNPG_SSL_MODE", "disable")
cnpg_ssl_enabled = cnpg_ssl_mode != "disable"
cnpg_hostname = System.get_env("CNPG_HOST", "localhost")
cnpg_tls_server_name = System.get_env("CNPG_TLS_SERVER_NAME", cnpg_hostname)

cnpg_cert_dir = System.get_env("CNPG_CERT_DIR", "")

cnpg_ca_file =
  System.get_env(
    "CNPG_CA_FILE",
    if(cnpg_cert_dir != "", do: Path.join(cnpg_cert_dir, "root.pem"), else: "")
  )

cnpg_cert_file =
  System.get_env(
    "CNPG_CERT_FILE",
    if(cnpg_cert_dir != "", do: Path.join(cnpg_cert_dir, "db-client.pem"), else: "")
  )

cnpg_key_file =
  System.get_env(
    "CNPG_KEY_FILE",
    if(cnpg_cert_dir != "", do: Path.join(cnpg_cert_dir, "db-client-key.pem"), else: "")
  )

cnpg_verify_peer = cnpg_ssl_mode in ~w(verify-ca verify-full)

cnpg_ssl_opts =
  [verify: if(cnpg_verify_peer, do: :verify_peer, else: :verify_none)]
  |> then(fn opts ->
    if cnpg_verify_peer and cnpg_ca_file != "" do
      Keyword.put(opts, :cacertfile, cnpg_ca_file)
    else
      opts
    end
  end)
  |> then(fn opts ->
    if cnpg_cert_file != "" and cnpg_key_file != "" do
      opts
      |> Keyword.put(:certfile, cnpg_cert_file)
      |> Keyword.put(:keyfile, cnpg_key_file)
    else
      opts
    end
  end)
  |> then(fn opts ->
    if cnpg_ssl_mode == "verify-full" and cnpg_tls_server_name != "" do
      opts
      |> Keyword.put(:server_name_indication, String.to_charlist(cnpg_tls_server_name))
      |> Keyword.put(:customize_hostname_check,
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      )
    else
      opts
    end
  end)

# Configure ServiceRadar.Repo from serviceradar_core
config :serviceradar_core, ServiceRadar.Repo,
  username: System.get_env("TEST_CNPG_USERNAME", System.get_env("CNPG_USERNAME", "postgres")),
  password: System.get_env("TEST_CNPG_PASSWORD", System.get_env("CNPG_PASSWORD", "postgres")),
  hostname: System.get_env("TEST_CNPG_HOST", System.get_env("CNPG_HOST", "localhost")),
  port: String.to_integer(System.get_env("TEST_CNPG_PORT", System.get_env("CNPG_PORT", "5432"))),
  database:
    System.get_env("TEST_CNPG_DATABASE", System.get_env("CNPG_DATABASE", "serviceradar")) <>
      (System.get_env("MIX_TEST_PARTITION") || ""),
  ssl: if(cnpg_ssl_enabled, do: cnpg_ssl_opts, else: false),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size:
    (case System.get_env("TEST_CNPG_POOL_SIZE") do
       nil -> min(max(System.schedulers_online() * 2, 10), 30)
       "" -> min(max(System.schedulers_online() * 2, 10), 30)
       value -> min(String.to_integer(value), 40)
     end),
  # Reduce flakiness under `mix test` with higher concurrency when using a remote CNPG DB.
  queue_target: 1_000,
  queue_interval: 1_000,
  # Some migrations (Timescale hypertables, indexes) can take > 2 minutes on CI/dev hardware.
  ownership_timeout: 300_000,
  parameters: [search_path: System.get_env("CNPG_SEARCH_PATH", "platform, public, ag_catalog")],
  types: ServiceRadar.PostgresTypes

config :serviceradar_core,
  datasvc_enabled: false,
  nats_enabled: false,
  service_heartbeat_enabled: false,
  state_monitor_enabled: false,
  event_batcher_enabled: false,
  health_check_runner_enabled: false,
  health_check_registrar_enabled: false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :serviceradar_web_ng, ServiceRadarWebNGWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "H8DPohD5rFUqGboVqCKLYXrlyofYUJk6k+XBzKEb5G8LN9brhYpNloE3UgxBQmPW",
  server: false

# In test we don't send emails
config :serviceradar_web_ng, ServiceRadarWebNG.Mailer, adapter: Swoosh.Adapters.Test

# Configure ServiceRadar.Mailer (used by AshAuthentication in serviceradar_core)
config :serviceradar_core, ServiceRadar.Mailer, adapter: Swoosh.Adapters.Test

# Token signing secret for tests (runtime.exs isn't loaded under `mix test`)
token_signing_secret = "test_token_signing_secret_at_least_32_chars_long!"
config :serviceradar_web_ng, :token_signing_secret, token_signing_secret
config :serviceradar_web_ng, ServiceRadarWebNG.Auth.Guardian, secret_key: token_signing_secret

config :serviceradar_web_ng, :base_url, "http://localhost:4002"

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Oban test configuration for serviceradar_core
config :serviceradar_core, Oban,
  repo: ServiceRadar.Repo,
  prefix: "platform",
  testing: :manual,
  queues: false,
  plugins: false

# Avoid SQL sandbox ownership errors from delayed seeders that run on application start.
config :serviceradar_core, :seeders_enabled, false

# Set env for serviceradar_core (enables Vault fallback key in tests)
config :serviceradar_core, env: :test
