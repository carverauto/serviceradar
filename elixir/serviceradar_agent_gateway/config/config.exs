import Config

alias ServiceRadar.NATS.Connection

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :gateway_id, :partition_id]

config :serviceradar_agent_gateway, :metrics,
  enabled: true,
  ip: {0, 0, 0, 0},
  port: 9090

config :serviceradar_agent_gateway, :otlp_relay_publisher,
  enabled: false,
  traces_subject: "otel.traces.raw",
  logs_subject: "logs.otel",
  metrics_subject: "otel.metrics.raw",
  derived_metrics_subject: "otel.metrics.derived",
  connection: Connection

config :serviceradar_agent_gateway, :plugin_metrics_publisher,
  enabled: false,
  subject_prefix: "metrics.timeseries",
  connection: Connection

config :serviceradar_agent_gateway, :snmp_metrics_publisher,
  enabled: false,
  subject_prefix: "metrics.snmp",
  connection: Connection

config :serviceradar_agent_gateway, :sysmon_metrics_publisher,
  enabled: false,
  subject_prefix: "metrics.sysmon",
  connection: Connection

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
    ServiceRadar.Dashboards,
    ServiceRadar.SweepJobs,
    ServiceRadar.SysmonProfiles,
    ServiceRadar.SNMPProfiles,
    ServiceRadar.NetworkDiscovery,
    ServiceRadar.Plugins,
    ServiceRadar.Credentials,
    ServiceRadar.Camera,
    ServiceRadar.WifiMap,
    ServiceRadar.Automation.Northbound,
    ServiceRadar.Automation.Ansible,
    ServiceRadar.Security,
    # Import environment specific config (if present)
    ServiceRadar.Spatial
  ]

import_config "#{config_env()}.exs"
