# ServiceRadar Core Configuration
#
# This file provides default configuration for serviceradar_core.
# Host applications (web, gateway, agent) should override these
# settings in their own config files.

import Config

# Ash configuration
config :ash,
  include_embedded_source_by_default?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false]

# AshOban configuration
config :ash_oban,
  oban_name: Oban,
  oban_module: ServiceRadar.Oban.Router

# Default Oban configuration (can be overridden by host app)
config :serviceradar_core, Oban,
  engine: Oban.Engines.Basic,
  repo: ServiceRadar.Repo,
  prefix: "platform",
  queues: [
    default: 10,
    alerts: 5,
    service_checks: 10,
    notifications: 5,
    onboarding: 3,
    events: 10,
    sweeps: 20,
    edge: 10,
    integrations: 5,
    nats_accounts: 3,
    maintenance: 2,
    monitoring: 5
  ],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       {System.get_env("TRACE_SUMMARIES_REFRESH_CRON") || "*/2 * * * *",
        ServiceRadar.Jobs.RefreshTraceSummariesWorker, queue: :maintenance},
       {"*/15 * * * *", ServiceRadar.Jobs.ReapStalePeriodicJobsWorker, queue: :maintenance},
       {"17 * * * *", ServiceRadar.Jobs.PruneStaleAgentsWorker, queue: :maintenance},
       {"17 3 * * *", ServiceRadar.Observability.DataRetentionWorker, queue: :maintenance},
       {"31 3 * * *", ServiceRadar.Edge.RemoteAccessVersionRetentionWorker, queue: :maintenance},
       {"23 3 * * *", ServiceRadar.Jobs.SecurityEventsRetentionWorker, queue: :maintenance}
     ]}
  ],
  peer: Oban.Peers.Database

# Mailer configuration
config :serviceradar_core, ServiceRadar.Mailer, adapter: Swoosh.Adapters.Local

config :serviceradar_core, ServiceRadar.Observability.NetflowSecurityRefreshWorker,
  reschedule_seconds: 86_400,
  cache_ttl_seconds: 86_400,
  threat_candidate_limit: 10_000

config :serviceradar_core, ServiceRadar.Observability.ThreatIntelOTXSyncWorker, []
config :serviceradar_core, ServiceRadar.Observability.ThreatIntelRawPayloadStore, []

# Cluster-aware rate limiter buckets. Per-route configuration; the plug
# resolves a bucket name from its opts and falls back to :default_bucket.
config :serviceradar_core, ServiceRadar.Security.RateLimiter,
  default_bucket: [limit: 60, window_seconds: 60],
  buckets: %{
    auth_local: [limit: 5, window_seconds: 60],
    auth_password_reset: [limit: 5, window_seconds: 300],
    auth_oidc_callback: [limit: 30, window_seconds: 60],
    auth_saml_callback: [limit: 30, window_seconds: 60],
    cli_device_auth: [limit: 30, window_seconds: 60],
    dashboard_publish: [limit: 10, window_seconds: 60],
    dashboard_publish_admin: [limit: 30, window_seconds: 60],
    edge_onboarding_package_create_actor: [limit: 10, window_seconds: 60],
    edge_onboarding_package_create_partition: [limit: 30, window_seconds: 60],
    cli_token_poll: [limit: 60, window_seconds: 60],
    plugin_upload: [limit: 10, window_seconds: 60],
    oauth_password_grant: [limit: 10, window_seconds: 60],
    oauth_client_credentials: [limit: 20, window_seconds: 60],
    remote_access_ssh_certificate_issue: [limit: 10, window_seconds: 60],
    api_default: [limit: 120, window_seconds: 60]
  }

# Plugin blob storage download configuration (used to generate signed download URLs)
config :serviceradar_core, :plugin_storage,
  public_url: nil,
  signing_secret: nil,
  download_ttl_seconds: 86_400

config :serviceradar_core,
  age_graph_name: "platform_graph"

# Cluster configuration (disabled by default)
config :serviceradar_core,
  cluster_enabled: false

config :serviceradar_core,
  control_repo_enabled: false

# Register Ash domains
config :serviceradar_core,
  ecto_repos: [ServiceRadar.Repo],
  ash_domains: [
    ServiceRadar.Camera,
    ServiceRadar.Credentials,
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
    ServiceRadar.Spatial,
    ServiceRadar.WifiMap,
    ServiceRadar.Automation.Ansible,
    ServiceRadar.Security
  ]

config :serviceradar_core,
  mtr_automation_enabled: false,
  mtr_automation_baseline_enabled: false,
  mtr_automation_trigger_enabled: false,
  mtr_automation_consensus_enabled: false,
  mtr_baseline_tick_ms: 60_000,
  mtr_consensus_cohort_retention_ms: 300_000

config :serviceradar_core,
  remote_access_desktop_rdp_enabled: false

config :serviceradar_core,
  remote_access_ssh_certificate_policy: %{}

config :serviceradar_core,
  run_startup_migrations: false

# Sweep SRQL paging configuration
config :serviceradar_core,
  sweep_srql_page_limit: 500

config :serviceradar_core,
  topology_v2_contract_consumption_enabled: true

# Spark configuration (Ash DSL)
config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :postgres,
        :authentication,
        :tokens,
        :json_api,
        :state_machine,
        :oban,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [:resources, :policies, :authorization, :domain, :execution]
    ]
  ]

# Settings → Audit → History allow-list. Sets which AshPaperTrail-
# enabled resources surface on the cross-resource history page.

# Import environment specific config
# The module defaults to the full list of AshPaperTrail-enabled
# resources; uncomment + edit to scope tighter or to exclude a

# Disable Swoosh API client (not needed for Local adapter)
# high-write-volume resource (e.g. PlaybookRun during a busy
# ansible run).
#
# config :serviceradar_core, ServiceRadar.Security.AuditHistory,
#   resources: [
#     ServiceRadar.Credentials.NetworkCredentialSecret,
#     ServiceRadar.Credentials.NetworkCredentialRule,
#     ServiceRadar.Security.AuthLockout
#   ]

config :swoosh, :api_client, false

import_config "#{config_env()}.exs"
