import Config

# General application configuration
config :serviceradar_agent_gateway,
  namespace: ServiceRadarAgentGateway

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :gateway_id, :partition_id]

# Import environment specific config (if present)
import_config "#{config_env()}.exs"
