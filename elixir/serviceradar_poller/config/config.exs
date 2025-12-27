import Config

# General application configuration
config :serviceradar_poller,
  namespace: ServiceRadarPoller

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :poller_id, :partition_id]

# Import environment specific config (if present)
import_config "#{config_env()}.exs"
