import Config

alias Swoosh.Adapters.Test

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
guarded_database_url = System.get_env("SERVICERADAR_TEST_DATABASE_URL")

guarded_database? =
  is_binary(guarded_database_url) and String.trim(guarded_database_url) != ""

guarded_ca_pem = System.get_env("SERVICERADAR_TEST_DATABASE_CA_CERT")
guarded_tls_server_name = System.get_env("SERVICERADAR_TEST_DATABASE_SERVER_NAME")

guarded_ca_certs =
  case guarded_ca_pem do
    pem when is_binary(pem) and pem != "" ->
      pem
      |> :public_key.pem_decode()
      |> Enum.filter(&match?({:Certificate, _der, _cipher}, &1))
      |> Enum.map(fn {:Certificate, der, _cipher} -> der end)

    _ ->
      []
  end

if guarded_database? and guarded_ca_certs == [] do
  raise "guarded web-ng database tests require SERVICERADAR_TEST_DATABASE_CA_CERT"
end

if guarded_database? and
     (not is_binary(guarded_tls_server_name) or guarded_tls_server_name == "") do
  raise "guarded web-ng database tests require SERVICERADAR_TEST_DATABASE_SERVER_NAME"
end

if guarded_database? do
  Code.require_file(Path.expand("../../serviceradar_core/config/test_database_guard.exs", __DIR__))

  ServiceRadar.DB.TestDatabaseGuard.validate!(guarded_database_url,
    tls_server_name: guarded_tls_server_name,
    ssl_mode: "verify-full",
    ca_configured?: guarded_ca_certs != [],
    template_lifecycle?: false
  )
end

cnpg_ssl_mode = System.get_env("CNPG_SSL_MODE", "disable")
cnpg_ssl_enabled = guarded_database? or cnpg_ssl_mode != "disable"
cnpg_hostname = System.get_env("CNPG_HOST", "localhost")

cnpg_tls_server_name =
  guarded_tls_server_name || System.get_env("CNPG_TLS_SERVER_NAME", cnpg_hostname)

cnpg_cert_dir = System.get_env("CNPG_CERT_DIR", "")

cnpg_ca_file =
  System.get_env(
    "CNPG_CA_FILE",
    if(cnpg_cert_dir == "", do: "", else: Path.join(cnpg_cert_dir, "root.pem"))
  )

cnpg_cert_file =
  System.get_env(
    "CNPG_CERT_FILE",
    if(cnpg_cert_dir == "", do: "", else: Path.join(cnpg_cert_dir, "db-client.pem"))
  )

cnpg_key_file =
  System.get_env(
    "CNPG_KEY_FILE",
    if(cnpg_cert_dir == "", do: "", else: Path.join(cnpg_cert_dir, "db-client-key.pem"))
  )

cnpg_verify_peer = guarded_database? or cnpg_ssl_mode in ~w(verify-ca verify-full)

cnpg_ssl_opts =
  [verify: if(cnpg_verify_peer, do: :verify_peer, else: :verify_none)]
  |> then(fn opts ->
    cond do
      cnpg_verify_peer and guarded_ca_certs != [] ->
        Keyword.put(opts, :cacerts, guarded_ca_certs)

      cnpg_verify_peer and cnpg_ca_file != "" ->
        Keyword.put(opts, :cacertfile, cnpg_ca_file)

      true ->
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
    if (guarded_database? or cnpg_ssl_mode == "verify-full") and
         cnpg_tls_server_name != "" do
      opts
      |> Keyword.put(:server_name_indication, String.to_charlist(cnpg_tls_server_name))
      |> Keyword.put(:customize_hostname_check,
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      )
    else
      opts
    end
  end)

# Token signing secret for tests (runtime.exs isn't loaded under `mix test`)
token_signing_secret = "test_token_signing_secret_at_least_32_chars_long!"

# Configure ServiceRadar.Repo from serviceradar_core
repo_connection_options =
  if guarded_database? do
    [url: guarded_database_url]
  else
    [
      username: System.get_env("TEST_CNPG_USERNAME", System.get_env("CNPG_USERNAME", "postgres")),
      password: System.get_env("TEST_CNPG_PASSWORD", System.get_env("CNPG_PASSWORD", "postgres")),
      hostname: System.get_env("TEST_CNPG_HOST", System.get_env("CNPG_HOST", "localhost")),
      port: String.to_integer(System.get_env("TEST_CNPG_PORT", System.get_env("CNPG_PORT", "5432"))),
      database:
        System.get_env("TEST_CNPG_DATABASE", System.get_env("CNPG_DATABASE", "serviceradar")) <>
          (System.get_env("MIX_TEST_PARTITION") || "")
    ]
  end

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Oban test configuration for serviceradar_core
config :serviceradar_core, Oban,
  repo: ServiceRadar.Repo,
  prefix: "platform",
  testing: :manual,
  queues: false,
  plugins: false

# Configure ServiceRadar.Mailer (used by AshAuthentication in serviceradar_core)
config :serviceradar_core, ServiceRadar.Mailer, adapter: Test

config :serviceradar_core,
       ServiceRadar.Repo,
       repo_connection_options ++
         [
           ssl: if(cnpg_ssl_enabled, do: cnpg_ssl_opts, else: false),
           pool: Ecto.Adapters.SQL.Sandbox,
           pool_size:
             case System.get_env("TEST_CNPG_POOL_SIZE") do
               nil -> min(max(System.schedulers_online() * 2, 10), 30)
               "" -> min(max(System.schedulers_online() * 2, 10), 30)
               value -> min(String.to_integer(value), 40)
             end,
           # Reduce flakiness under `mix test` with higher concurrency when using a remote CNPG DB.
           queue_target: String.to_integer(System.get_env("TEST_CNPG_QUEUE_TARGET_MS", "1000")),
           queue_interval: String.to_integer(System.get_env("TEST_CNPG_QUEUE_INTERVAL_MS", "1000")),
           # Some migrations take minutes on CI/dev hardware, and at least one
           # (`MovePublicSchemaObjectsToPlatform`) stalls for ~264s against a remote
           # database while doing ~340ms of actual work -- see
           # https://github.com/carverauto/serviceradar/issues/4151. When the connection
           # is held past this timeout the whole `mix ecto.migrate` run aborts with
           # `{:error, :rollback}` out of `do_lock_for_migrations/5`, which names neither
           # the migration nor the timeout as the cause. Configurable so a slower or
           # remote database is a longer wait rather than a hard failure; the default is
           # unchanged. `serviceradar_core`'s test config already reads the same variable.
           ownership_timeout:
             String.to_integer(
               System.get_env("SERVICERADAR_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS") ||
                 System.get_env("TEST_CNPG_OWNERSHIP_TIMEOUT_MS") ||
                 "300000"
             ),
           parameters: [
             search_path: System.get_env("CNPG_SEARCH_PATH", "platform, public, ag_catalog")
           ],
           types: ServiceRadar.PostgresTypes
         ]

# Avoid SQL sandbox ownership errors from delayed seeders that run on application start.
config :serviceradar_core, :seeders_enabled, false

config :serviceradar_core,
  datasvc_enabled: false,
  nats_enabled: false,
  service_heartbeat_enabled: false,
  state_monitor_enabled: false,
  event_batcher_enabled: false,
  health_check_runner_enabled: false,
  health_check_registrar_enabled: false

# Set env for serviceradar_core (enables Vault fallback key in tests)
config :serviceradar_core, env: :test

config :serviceradar_web_ng, ServiceRadarWebNG.Auth.Guardian, secret_key: token_signing_secret

# In test we don't send emails
config :serviceradar_web_ng, ServiceRadarWebNG.Mailer, adapter: Test

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :serviceradar_web_ng, ServiceRadarWebNGWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "H8DPohD5rFUqGboVqCKLYXrlyofYUJk6k+XBzKEb5G8LN9brhYpNloE3UgxBQmPW",
  server: false

config :serviceradar_web_ng, :base_url, "http://localhost:4002"

# Mark this as test environment for single-deployment defaults
config :serviceradar_web_ng, :env, :test
config :serviceradar_web_ng, :god_view_runtime_graph_auto_refresh, false
config :serviceradar_web_ng, :mcp_enabled, true
config :serviceradar_web_ng, :telemetry_poller_enabled, false
config :serviceradar_web_ng, :token_signing_secret, token_signing_secret

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false
