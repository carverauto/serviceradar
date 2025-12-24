import Config

# Disable Swoosh API client in tests (no hackney needed)
config :swoosh, :api_client, false

# Use Test adapter for mailer
config :serviceradar_core, ServiceRadar.Mailer,
  adapter: Swoosh.Adapters.Test

# Test database configuration
config :serviceradar_core, ServiceRadar.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "serviceradar_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Disable cluster in tests by default
config :serviceradar_core,
  cluster_enabled: false

# Oban in test mode
config :serviceradar_core, Oban,
  testing: :inline

# Reduce log noise in tests
config :logger, level: :warning
