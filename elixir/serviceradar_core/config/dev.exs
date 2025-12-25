import Config

# Dev database configuration
# Host applications should override this with their actual connection details
config :serviceradar_core, ServiceRadar.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "serviceradar_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# Enable cluster in dev for testing
config :serviceradar_core,
  env: :dev,
  cluster_enabled: true

# Oban in dev mode
config :serviceradar_core, Oban,
  engine: Oban.Engines.Basic,
  queues: [default: 10, alerts: 5, sweeps: 20, edge: 10],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron, crontab: []}
  ]
