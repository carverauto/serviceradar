import Config

# General application configuration
config :serviceradar_agent_gateway,
  namespace: ServiceRadarAgentGateway

config :serviceradar_core,
  ash_domains: [
    ServiceRadar.Identity,
    ServiceRadar.Inventory,
    ServiceRadar.Infrastructure,
    ServiceRadar.Monitoring,
    ServiceRadar.Observability,
    ServiceRadar.Edge,
    ServiceRadar.Integrations,
    ServiceRadar.Jobs,
    ServiceRadar.AgentConfig,
    ServiceRadar.SweepJobs,
    ServiceRadar.SysmonProfiles,
    ServiceRadar.SNMPProfiles,
    ServiceRadar.NetworkDiscovery,
    ServiceRadar.Plugins
  ]

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :gateway_id, :partition_id]

# Import environment specific config (if present)
import_config "#{config_env()}.exs"
