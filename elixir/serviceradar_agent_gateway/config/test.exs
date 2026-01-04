import Config

# Disable Swoosh API client in tests (no hackney needed)
config :swoosh, :api_client, false

# Use Test adapter for mailer
config :serviceradar_core, ServiceRadar.Mailer,
  adapter: Swoosh.Adapters.Test

# Disable Repo and Oban for standalone poller tests (no database needed)
config :serviceradar_core,
  repo_enabled: false

config :serviceradar_core, Oban, false

# Disable domain warnings
config :ash, :validate_domain_config_inclusion?, false

# Test-specific configuration
config :logger, level: :warning
