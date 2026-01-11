# ServiceRadar Core Configuration
#
# This file provides default configuration for serviceradar_core.
# Host applications (web, gateway, agent) should override these
# settings in their own config files.

import Config

# Register Ash domains
config :serviceradar_core,
  ecto_repos: [ServiceRadar.Repo],
  ash_domains: [
    ServiceRadar.Identity,
    ServiceRadar.Inventory,
    ServiceRadar.Infrastructure,
    ServiceRadar.Monitoring,
    ServiceRadar.Observability,
    ServiceRadar.Edge,
    ServiceRadar.Integrations,
    ServiceRadar.Jobs
  ]

# Mailer configuration
config :serviceradar_core, ServiceRadar.Mailer, adapter: Swoosh.Adapters.Local

# Disable Swoosh API client (not needed for Local adapter)
config :swoosh, :api_client, false

# Ash configuration
config :ash,
  include_embedded_source_by_default?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false]

# AshOban configuration
config :ash_oban,
  oban_name: Oban,
  oban_module: ServiceRadar.Oban.Router

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
        :multitenancy,
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

# Default Oban configuration (can be overridden by host app)
config :serviceradar_core, Oban,
  engine: Oban.Engines.Basic,
  repo: ServiceRadar.Repo,
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
    nats_accounts: 3
  ],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       {"*/2 * * * *", ServiceRadar.Jobs.RefreshTraceSummariesWorker, queue: :maintenance},
       {"0 * * * *", ServiceRadar.Observability.StatefulAlertCleanupWorker, queue: :maintenance}
     ]}
  ],
  peer: Oban.Peers.Database

# Cluster configuration (disabled by default)
config :serviceradar_core,
  cluster_enabled: false

config :serviceradar_core,
  run_startup_migrations: false

config :serviceradar_core,
  reset_tenant_schemas: false

# Import environment specific config
import_config "#{config_env()}.exs"
