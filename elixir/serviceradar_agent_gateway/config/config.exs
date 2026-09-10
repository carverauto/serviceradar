import Config

alias ServiceRadar.NATS.Connection

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :gateway_id,
    :partition_id,
    :agent_id,
    :partition,
    :subject,
    :reason,
    :service_name,
    :message_size,
    :payload_kind,
    :event_id,
    :command_id,
    :expected_command_type,
    :reported_command_type,
    :phase,
    :desktop_session_id,
    :command_type,
    :success,
    :payload_field_count,
    :progress_percent,
    :config_version,
    :section_count
  ]

config :serviceradar_agent_gateway, :edge_records_publisher, enabled: false

config :serviceradar_agent_gateway, :icmp_metrics_publisher,
  enabled: false,
  subject_prefix: "metrics.icmp",
  connection: Connection

config :serviceradar_agent_gateway, :metrics,
  enabled: true,
  ip: {0, 0, 0, 0},
  port: 9090

config :serviceradar_agent_gateway, :mtr_metrics_publisher,
  enabled: false,
  subject_prefix: "metrics.mtr",
  connection: Connection

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

config :serviceradar_agent_gateway, :rperf_metrics_publisher,
  enabled: false,
  subject_prefix: "metrics.rperf",
  connection: Connection

config :serviceradar_agent_gateway, :snmp_metrics_publisher,
  enabled: false,
  subject_prefix: "metrics.snmp",
  connection: Connection

config :serviceradar_agent_gateway, :sweep_metrics_publisher,
  enabled: false,
  subject_prefix: "metrics.sweep",
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
    ServiceRadar.Notifications,
    ServiceRadar.Observability,
    ServiceRadar.ColdTier,
    ServiceRadar.PrefixTags,
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
    ServiceRadar.Automation.Callbacks,
    ServiceRadar.Scans,
    ServiceRadar.Security,
    # Import environment specific config (if present)
    ServiceRadar.Spatial
  ]

# The gateway joins the ERTS cluster and stays in the Horde registry CRDT mesh
# (it *writes* the control-stream/agent entries core reads — see
# ServiceRadar.ProcessRegistry.join_process_registry?/0), but it must never
# host distributed processes: the gateway runs without the core Repo, so a
# StatefulAlertEngine shard (or any repo-backed worker) placed here would load
# zero rules and silently drop alert evaluations.
config :serviceradar_core, host_distributed_processes: false

# Lint-only CI sets SERVICERADAR_SKIP_NIF_COMPILATION so mix deps.compile of
# path-dep NIFs does not shell out to cargo. See elixir/web-ng/config/config.exs.
if System.get_env("SERVICERADAR_SKIP_NIF_COMPILATION") == "1" do
  config :serviceradar_core, ServiceRadar.Observability.DispositionKernels, skip_compilation?: true
  config :serviceradar_core, ServiceRadar.Observability.Zen.Native, skip_compilation?: true

  config :serviceradar_srql, ServiceRadarSRQL.Native, skip_compilation?: true
end

import_config "#{config_env()}.exs"
