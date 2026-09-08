import Config

config :ash,
  include_embedded_source_by_default?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false]

config :ash_oban, oban_name: Oban

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :node]

config :serviceradar_core, ServiceRadar.Mailer, adapter: Swoosh.Adapters.Local

# Plugin blob storage download configuration (used to generate signed download URLs)
config :serviceradar_core, :plugin_storage,
  public_url: nil,
  signing_secret: nil,
  download_ttl_seconds: 86_400

config :serviceradar_core,
  ecto_repos: [ServiceRadar.Repo],
  ash_domains: [
    ServiceRadar.Camera,
    ServiceRadar.CompositeChecks,
    ServiceRadar.Identity,
    ServiceRadar.Inventory,
    ServiceRadar.Infrastructure,
    ServiceRadar.Monitoring,
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
    ServiceRadar.Credentials,
    ServiceRadar.Automation.Northbound,
    ServiceRadar.Automation.Ansible,
    ServiceRadar.Automation.Callbacks,
    ServiceRadar.Scans,
    ServiceRadar.Security,
    # The deployed core image evaluates THIS config, not serviceradar_core's, so
    # a domain registered only there is invisible in production: runtime.exs
    # reads `:ash_domains` to expand the AshOban scheduler, and an unregistered
    # domain's triggers are never scheduled.
    ServiceRadar.Notifications
  ]

config :serviceradar_core_elx, :metrics,
  enabled: true,
  ip: {0, 0, 0, 0},
  port: 9090

config :serviceradar_core_elx,
  namespace: ServiceRadarCoreElx

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

# Lint-only CI sets SERVICERADAR_SKIP_NIF_COMPILATION so mix deps.compile of
# path-dep NIFs does not shell out to cargo. See elixir/web-ng/config/config.exs.
if System.get_env("SERVICERADAR_SKIP_NIF_COMPILATION") == "1" do
  config :serviceradar_core, ServiceRadar.Observability.DispositionKernels, skip_compilation?: true
  config :serviceradar_core, ServiceRadar.Observability.Zen.Native, skip_compilation?: true

  config :serviceradar_srql, ServiceRadarSRQL.Native, skip_compilation?: true
end

import_config "#{config_env()}.exs"
