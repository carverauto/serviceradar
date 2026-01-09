import Config

# Dev database configuration
# Host applications should override this with their actual connection details
# If DATABASE_URL is set, use it; otherwise use defaults
database_url = System.get_env("DATABASE_URL")

if database_url do
  # Support SSL options via environment
  ssl_mode = System.get_env("CNPG_SSL_MODE", "disable")
  cert_dir = System.get_env("CNPG_CERT_DIR")
  server_name = System.get_env("CNPG_TLS_SERVER_NAME")

  ssl_opts =
    case ssl_mode do
      "disable" ->
        false

      mode when mode in ["require", "verify-full"] and not is_nil(cert_dir) ->
        base_opts = [
          verify: :verify_peer,
          cacertfile: Path.join(cert_dir, "root.pem")
        ]

        base_opts =
          if server_name,
            do: Keyword.put(base_opts, :server_name_indication, String.to_charlist(server_name)),
            else: base_opts

        base_opts

      _ ->
        [verify: :verify_none]
    end

  config :serviceradar_core, ServiceRadar.Repo,
    url: database_url,
    ssl: ssl_opts,
    stacktrace: true,
    show_sensitive_data_on_connection_error: true,
    pool_size: 10
else
  config :serviceradar_core, ServiceRadar.Repo,
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    database: "serviceradar_dev",
    stacktrace: true,
    show_sensitive_data_on_connection_error: true,
    pool_size: 10
end

# Enable cluster in dev for testing
config :serviceradar_core,
  env: :dev,
  cluster_enabled: true,
  status_handler_enabled: true

# Oban in dev mode
config :serviceradar_core, Oban,
  engine: Oban.Engines.Basic,
  repo: ServiceRadar.Repo,
  queues: [default: 10, alerts: 5, sweeps: 20, edge: 10, nats_accounts: 3],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron, crontab: []}
  ]
