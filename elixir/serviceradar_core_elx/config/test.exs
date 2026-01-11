import Config

config :swoosh, :api_client, false

config :serviceradar_core, ServiceRadar.Mailer,
  adapter: Swoosh.Adapters.Test

config :serviceradar_core,
  repo_enabled: false

config :serviceradar_core, Oban, false

config :ash, :validate_domain_config_inclusion?, false

config :logger, level: :warning
