# ServiceRadar Core Configuration
#
# This file provides default configuration for serviceradar_core.
# Host applications (web, poller, agent) should override these
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
    ServiceRadar.Integrations
  ]

# Mailer configuration
config :serviceradar_core, ServiceRadar.Mailer, adapter: Swoosh.Adapters.Local

# Ash configuration
config :ash,
  include_embedded_source_by_default?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  # Disable domain inclusion warnings (domains are registered above)
  validate_domain_config_inclusion?: false

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
  queues: [default: 10, alerts: 5, sweeps: 20, edge: 10],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron, crontab: []}
  ]

# Cluster configuration (disabled by default)
config :serviceradar_core,
  cluster_enabled: false

# Import environment specific config
import_config "#{config_env()}.exs"
