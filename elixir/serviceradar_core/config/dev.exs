import Config

# Dev database configuration
# Host applications should override this with their actual connection details
# If DATABASE_URL is set, use it; otherwise use defaults
database_url = System.get_env("DATABASE_URL")
search_path = System.get_env("CNPG_SEARCH_PATH", "platform, public, ag_catalog")

if database_url do
  # Support SSL options via environment
  ssl_mode = System.get_env("CNPG_SSL_MODE", "disable")
  cert_dir = System.get_env("CNPG_CERT_DIR")
  server_name = System.get_env("CNPG_TLS_SERVER_NAME")
  ca_file = System.get_env("CNPG_CA_FILE") || (cert_dir && Path.join(cert_dir, "root.pem"))

  cert_file =
    System.get_env("CNPG_CERT_FILE") || (cert_dir && Path.join(cert_dir, "db-client.pem"))

  key_file =
    System.get_env("CNPG_KEY_FILE") || (cert_dir && Path.join(cert_dir, "db-client-key.pem"))

  put_if = fn opts, key, value ->
    if value && value != "", do: Keyword.put(opts, key, value), else: opts
  end

  ssl_opts =
    case ssl_mode do
      "disable" ->
        false

      mode when mode in ["require", "verify-ca", "verify-full"] ->
        base_opts =
          []
          |> put_if.(:cacertfile, ca_file)
          |> put_if.(:certfile, cert_file)
          |> put_if.(:keyfile, key_file)
          |> Keyword.put(
            :verify,
            if(mode in ["verify-ca", "verify-full"], do: :verify_peer, else: :verify_none)
          )

        base_opts =
          if server_name,
            do: Keyword.put(base_opts, :server_name_indication, String.to_charlist(server_name)),
            else: base_opts

        base_opts

      _ ->
        [verify: :verify_none]
    end

  config :serviceradar_core, ServiceRadar.ControlRepo,
    url: database_url,
    ssl: ssl_opts,
    stacktrace: true,
    show_sensitive_data_on_connection_error: true,
    pool_size: 5,
    parameters: [search_path: search_path],
    types: ServiceRadar.PostgresTypes

  config :serviceradar_core, ServiceRadar.Repo,
    url: database_url,
    ssl: ssl_opts,
    stacktrace: true,
    show_sensitive_data_on_connection_error: true,
    pool_size: 10,
    parameters: [search_path: search_path],
    types: ServiceRadar.PostgresTypes
else
  config :serviceradar_core, ServiceRadar.ControlRepo,
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    database: "serviceradar_dev",
    stacktrace: true,
    show_sensitive_data_on_connection_error: true,
    pool_size: 5,
    parameters: [search_path: search_path],
    types: ServiceRadar.PostgresTypes

  config :serviceradar_core, ServiceRadar.Repo,
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    database: "serviceradar_dev",
    stacktrace: true,
    show_sensitive_data_on_connection_error: true,
    pool_size: 10,
    parameters: [search_path: search_path],
    types: ServiceRadar.PostgresTypes
end

# Oban in dev mode
config :serviceradar_core, Oban,
  engine: Oban.Engines.Basic,
  repo: ServiceRadar.Repo,
  prefix: "platform",
  queues: [default: 10, alerts: 5, sweeps: 20, edge: 10, nats_accounts: 3],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron, crontab: []}
  ]

config :serviceradar_core, control_repo_enabled: true

# Enable cluster in dev for testing
config :serviceradar_core,
  env: :dev,
  cluster_enabled: true,
  status_handler_enabled: true
