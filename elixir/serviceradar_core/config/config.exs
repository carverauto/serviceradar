# ServiceRadar Core Configuration
#
# This file provides default configuration for serviceradar_core.
# Host applications (web, gateway, agent) should override these
# settings in their own config files.

import Config

alias ServiceRadar.Observability.CapacityForecasting.Worker

alias ServiceRadar.Observability.SeasonalDisposition.EdgeBaselineProducer,
  as: SeasonalEdgeBaselineProducer

alias ServiceRadar.Observability.SeasonalDisposition.Worker, as: SeasonalDispositionWorker

# Ash configuration
config :ash,
  include_embedded_source_by_default?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false]

# AshOban configuration
config :ash_oban,
  oban_name: Oban,
  oban_module: ServiceRadar.Oban.Router

# Export is opt-in at the host boundary. Core can be started standalone by
# tests and tooling that do not evaluate a host application's runtime.exs; in
# those contexts the SDK's default localhost HTTP exporter is unintended.
config :opentelemetry, traces_exporter: :none

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
    monitoring: 5,
    ansible_pulse: 5,
    ansible_catalog: 3,
    ansible_retention: 1
  ],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Lifeline, rescue_after: to_timeout(minute: 240)},
    {Oban.Plugins.Cron,
     crontab: [
       {System.get_env("TRACE_SUMMARIES_REFRESH_CRON") || "*/2 * * * *",
        ServiceRadar.Jobs.RefreshTraceSummariesWorker, queue: :maintenance},
       {"*/5 * * * *", ServiceRadar.Jobs.RootSpanRatioWorker, queue: :maintenance},
       {"*/15 * * * *", ServiceRadar.Jobs.ReapStalePeriodicJobsWorker, queue: :maintenance},
       {"17 * * * *", ServiceRadar.Jobs.PruneStaleAgentsWorker, queue: :maintenance},
       {"17 3 * * *", ServiceRadar.Observability.DataRetentionWorker, queue: :maintenance},
       {"41 * * * *", Worker, args: %{"trigger" => "cron"}, queue: :maintenance},
       {"47 * * * *", SeasonalDispositionWorker,
        args: %{"trigger" => "cron"}, queue: :maintenance},
       {"53 * * * *", SeasonalEdgeBaselineProducer,
        args: %{"trigger" => "cron"}, queue: :maintenance},
       {"*/10 * * * *", ServiceRadar.Edge.RemoteAccessRecordingReaperWorker, queue: :maintenance},
       {"31 3 * * *", ServiceRadar.Edge.RemoteAccessVersionRetentionWorker, queue: :maintenance},
       {"23 3 * * *", ServiceRadar.Jobs.SecurityEventsRetentionWorker, queue: :maintenance},
       {"*/5 * * * *", ServiceRadar.Observability.AnomalyEpisodeStaleCloseWorker,
        queue: :maintenance},
       {"*/30 * * * *", ServiceRadar.Observability.ResolveStaleAnomaliesWorker,
        queue: :maintenance}
     ]}
  ],
  peer: Oban.Peers.Database

# Advisory-feed staging reaper. Oban :kill skips FeedWorker after-cleanup.
config :serviceradar_core, ServiceRadar.Inventory.AdvisoryFeeds.StagingCleanupWorker,
  reschedule_seconds: 60

# Agent-to-device link repair (periodic; see AgentLinkRepairWorker)
config :serviceradar_core, ServiceRadar.Inventory.AgentLinkRepairWorker,
  enabled: true,
  batch_size: 100,
  reschedule_seconds: 900

config :serviceradar_core, ServiceRadar.Inventory.BumblebeeCatalogRefreshWorker,
  enabled: false,
  timeout_ms: 30_000,
  reschedule_seconds: 86_400,
  failure_reschedule_seconds: 3_600,
  max_entries: 250_000

# Unseen-identifier TTL garbage collection (daily; see DeviceIdentifierGcWorker)
config :serviceradar_core, ServiceRadar.Inventory.DeviceIdentifierGcWorker,
  enabled: true,
  ttl_days: 90,
  batch_size: 5_000,
  max_batches: 200,
  reschedule_seconds: 86_400

# Device risk assessment (periodic; see DeviceRiskAssessmentWorker). Matching
# is hourly; this pass re-scores KEV/CVSS/CWE without waiting for a rematch.
config :serviceradar_core, ServiceRadar.Inventory.DeviceRiskAssessmentWorker,
  reschedule_seconds: 900

# ng_job_schedules staleness alerting (see ScheduleHealthWorker)
config :serviceradar_core, ServiceRadar.Jobs.ScheduleHealthWorker, reschedule_seconds: 900

# Mailer configuration
config :serviceradar_core, ServiceRadar.Mailer, adapter: Swoosh.Adapters.Local

# Topology state cleanup cadence (see TopologyStateCleanupWorker). The cleanup is a
# heavy maintenance sweep (9 full UPDATEs + canonical rebuild); 1h keeps the table
# canonical without the every-5-minute load that drove DB CPU/bloat.
config :serviceradar_core, ServiceRadar.NetworkDiscovery.TopologyStateCleanupWorker,
  reschedule_seconds: 3_600

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
    mcp: [limit: 60, window_seconds: 60],
    remote_access_ssh_certificate_issue: [limit: 10, window_seconds: 60],
    automation_callback_grant: [limit: 30, window_seconds: 60],
    # Notification action links. Unauthenticated by design, so this limit is the
    # only cost of guessing at one. Generous enough that a shared office egress
    # IP acknowledging a page storm is never throttled.
    notification_action: [limit: 60, window_seconds: 60],
    api_default: [limit: 120, window_seconds: 60]
  }

config :serviceradar_core, Worker,
  enabled: true,
  horizon_seconds: 90 * 24 * 60 * 60,
  warning_horizon_seconds: 90 * 24 * 60 * 60,
  emit_verdicts?: true,
  min_points: 24,
  seasonal_period: 24

# Visibility applied to newly created dashboard instances. Existing rows are
# backfilled to public and are not affected when this setting later changes.
config :serviceradar_core, :dashboard_packages, default_visibility: :public

config :serviceradar_core, :object_store_retention,
  enabled?: true,
  dry_run?: false,
  agent_release_keep_latest: 1,
  native_addon_orphan_grace_seconds: 604_800,
  datasvc_timeout_ms: 30_000

# Plugin blob storage download configuration (used to generate signed download URLs)
config :serviceradar_core, :plugin_storage,
  public_url: nil,
  signing_secret: nil,
  download_ttl_seconds: 86_400

config :serviceradar_core, :required_agent_addons, ["otel-collector"]

config :serviceradar_core,
  age_graph_name: "platform_graph"

config :serviceradar_core,
  bumblebee_catalog_refresh_enabled: false

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
    ServiceRadar.CompositeChecks,
    ServiceRadar.Credentials,
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
    ServiceRadar.Spatial,
    ServiceRadar.WifiMap,
    ServiceRadar.Automation.Northbound,
    ServiceRadar.Automation.Ansible,
    ServiceRadar.Automation.Callbacks,
    ServiceRadar.Scans,
    ServiceRadar.Security
  ]

config :serviceradar_core,
  endpoint_inventory_ingestor_async: true,
  endpoint_inventory_ingestor_max_concurrency: 4,
  endpoint_inventory_ingestor_queue_max_pending: 256,
  endpoint_inventory_ingestor_queue_max_pending_per_agent: 32,
  endpoint_inventory_ingestor_admission_timeout_ms: 5_000,
  endpoint_inventory_ingestor_timeout_ms: 20_000

config :serviceradar_core,
  mtr_automation_enabled: false,
  mtr_automation_baseline_enabled: false,
  mtr_automation_trigger_enabled: false,
  mtr_automation_consensus_enabled: false,
  mtr_baseline_tick_ms: 60_000,
  mtr_consensus_cohort_retention_ms: 300_000

# Prefix-tag flow enrichment (LPM trie). Default OFF until migrations are known
# applied on every EventWriter node (deploy-before-migration would fail inserts
# once the Diesel schema expects the new columns). Fail-open when enabled.
# Provider trie defaults ON (SQL is boot/empty-trie fallback only; no ETS cache).
config :serviceradar_core,
  prefix_tag_enrichment_enabled: false,
  # Serve hosting-provider lookups from the provider: trie (ProviderSource loads at boot).
  prefix_tag_provider_trie_enabled: true,
  # CTI IpThreatIntelCache current-match via ti: trie (SQL fallback if trie empty).
  threat_intel_engine_match_enabled: true,
  # Derive geo:country:/geo:asn: tags from Geolix (not stored in the trie).
  geo_tag_derivation_enabled: false,
  prefix_tags_loader_enabled: true

config :serviceradar_core,
  remote_access_desktop_rdp_enabled: false,
  northbound_callback_base_url: nil,
  # Base URL the signed notification action links point at (design D7 Phase 1).
  # Unset means no action links are rendered at all: a bare
  # "/api/notifications/actions/..." path is a dead link in a mail client, and a
  # notification with no links is better than one that looks broken.
  # `SERVICERADAR_NOTIFICATION_ACTION_BASE_URL` is read as a fallback.
  notification_action_base_url: nil

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
    # Settings → Audit → History allow-list. Sets which AshPaperTrail-
    # enabled resources surface on the cross-resource history page.
    # Import environment specific config
    # The module defaults to the full list of AshPaperTrail-enabled
    # resources; uncomment + edit to scope tighter or to exclude a

    "Ash.Domain": [
      section_order: [:resources, :policies, :authorization, :domain, :execution]
    ]
  ]

# Disable Swoosh API client (not needed for Local adapter)
# high-write-volume resource (e.g. PlaybookRun during a busy
# ansible run).
#
# config :serviceradar_core, ServiceRadar.Security.AuditHistory,
#   resources: [
#     ServiceRadar.Credentials.NetworkCredentialSecret,
#     ServiceRadar.Credentials.NetworkCredentialRule,
# Lint-only CI sets SERVICERADAR_SKIP_NIF_COMPILATION so mix deps.compile does
#     ServiceRadar.Security.AuthLockout
# not shell out to cargo. mix_app already skips these NIFs under Bazel via
#   ]
# extra_config. See elixir/web-ng/config/config.exs for the full rationale.
config :swoosh, :api_client, false

if System.get_env("SERVICERADAR_SKIP_NIF_COMPILATION") == "1" do
  config :serviceradar_core, ServiceRadar.Observability.DispositionKernels,
    skip_compilation?: true

  config :serviceradar_core, ServiceRadar.Observability.Zen.Native, skip_compilation?: true

  config :serviceradar_srql, ServiceRadarSRQL.Native, skip_compilation?: true
end

import_config "#{config_env()}.exs"
