defmodule ServiceRadarWebNGWeb.Settings.Catalog do
  @moduledoc """
  Declarative catalog of the web-ng Settings navigation.

  This module is the single source of truth for the Settings information
  architecture. It is modeled on `ServiceRadar.Identity.RBAC.Catalog`: two
  literal data structures (`@categories` and a flat `@views`) plus pure derived
  accessors. Every Settings navigation surface — the icon rail, the topbar
  category switcher, the left view list, the breadcrumbs, and the Ctrl+K command
  palette — renders entirely from this catalog, so adding a page is one map entry
  with zero layout risk.

  ## Why here (web-ng) and not in serviceradar_core

  The RBAC permission catalog lives in `serviceradar_core` because permissions
  are shared by web-ng and the API. This navigation catalog references
  web-ng-only concerns (LiveView modules, `~p` routes, heroicon names, feature
  flags), so it belongs in web-ng. It does **not** inline permission strings:
  each view's `:permission` field carries a KEY that must exist in
  `ServiceRadar.Identity.RBAC.Catalog.permission_keys/0` (a symbolic reference,
  validated by the catalog test), analogous to how the RBAC catalog references
  role constants.

  ## Active-view resolution

  The active view is resolved by `view_for_path/1`, a deterministic
  longest-prefix match over all views' match prefixes. This structurally
  replaces the legacy per-page `current_path` strings and negated
  `String.starts_with?/2` denylists: `/settings/networks` (Sweep Profiles) and
  `/settings/networks/bmp` (BGP / BMP) coexist because the longest matching
  prefix always wins.

  ## Phased population

  Phase 1 populated the full `@categories` set (7 target categories) plus the
  `Audit & System Log` pilot category's `@views`. Phase 2 populates the `@views`
  for the remaining six categories (Core Cluster, Discovery & Sweeps, Edge Ops,
  Network Services, Mail & Alerts, Security & Auth). Categories with no
  permitted, enabled child views are still hidden from the switcher, so a
  category renders only when a scope can see at least one of its views.
  """

  alias ServiceRadarWebNG.Capabilities
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.FeatureFlags

  @typedoc "A settings category (topbar switcher entry)."
  @type category :: %{
          id: atom(),
          title: String.t(),
          icon: String.t(),
          order: non_neg_integer(),
          rail_group: atom(),
          permission: String.t() | nil,
          feature_flag: atom() | nil
        }

  @typedoc "A settings view (left-list entry + deep-linkable page)."
  @type view :: %{
          id: atom(),
          category: atom(),
          title: String.t(),
          description: String.t(),
          icon: String.t(),
          route: String.t(),
          live_view: module(),
          permission: String.t() | nil,
          order: non_neg_integer(),
          feature_flag: atom() | nil,
          capability: atom() | nil,
          match_prefixes: [String.t()] | nil,
          keywords: [String.t()],
          badge: atom() | nil,
          hidden_from_nav: boolean()
        }

  # ---------------------------------------------------------------------------
  # Categories (topbar switcher order). Seven target categories from the mockups.
  # ---------------------------------------------------------------------------
  @categories [
    %{
      id: :core_cluster,
      title: "Core Cluster",
      icon: "hero-server-stack",
      order: 10,
      rail_group: :settings,
      permission: nil,
      feature_flag: nil
    },
    %{
      id: :discovery_sweeps,
      title: "Discovery & Sweeps",
      icon: "hero-magnifying-glass",
      order: 20,
      rail_group: :settings,
      permission: nil,
      feature_flag: nil
    },
    %{
      id: :edge_ops,
      title: "Edge Ops",
      icon: "hero-cpu-chip",
      order: 30,
      rail_group: :settings,
      permission: nil,
      feature_flag: nil
    },
    %{
      id: :network_services,
      title: "Network Services",
      icon: "hero-globe-alt",
      order: 40,
      rail_group: :settings,
      permission: nil,
      feature_flag: nil
    },
    %{
      id: :mail_alerts,
      title: "Mail & Alerts",
      icon: "hero-envelope",
      order: 50,
      rail_group: :settings,
      permission: nil,
      feature_flag: nil
    },
    %{
      id: :security_auth,
      title: "Security & Auth",
      icon: "hero-shield-check",
      order: 60,
      rail_group: :settings,
      permission: nil,
      feature_flag: nil
    },
    %{
      id: :audit_system_log,
      title: "Audit & System Log",
      icon: "hero-clipboard-document-list",
      order: 70,
      rail_group: :settings,
      permission: nil,
      feature_flag: nil
    }
  ]

  # ---------------------------------------------------------------------------
  # Views (flat list; each carries `category:` as an FK into @categories).
  #
  # Phase 2 populates all seven categories. Every entry maps to an existing
  # route + LiveView verified against the router (the orphan detector in the
  # catalog test enforces this). `permission:` carries a KEY validated against
  # `ServiceRadar.Identity.RBAC.Catalog.permission_keys/0`. `match_prefixes:`
  # is set only where a view must also own a legacy `/admin/*` duplicate route
  # so the shell highlights the correct view there (the `/admin/*` MERGE
  # redirects themselves are a follow-up phase).
  # ---------------------------------------------------------------------------
  @views [
    # --- Core Cluster --------------------------------------------------------
    %{
      id: :cluster_status,
      category: :core_cluster,
      title: "Cluster Status",
      description: "Monitor the distributed ERTS cluster, gateways, agents, and job queues.",
      icon: "hero-server-stack",
      route: "/settings/cluster",
      live_view: ServiceRadarWebNGWeb.Settings.ClusterLive.Index,
      permission: "settings.view",
      order: 10,
      feature_flag: nil,
      capability: nil,
      match_prefixes: ["/settings/cluster", "/admin/cluster"],
      keywords: ["cluster", "nodes", "health", "status", "infrastructure"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :jobs,
      category: :core_cluster,
      title: "Jobs",
      description: "Inspect and manage Oban background job queues across the cluster.",
      icon: "hero-queue-list",
      route: "/admin/jobs",
      live_view: ServiceRadarWebNGWeb.Admin.JobLive.Index,
      permission: "settings.jobs.manage",
      order: 20,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["jobs", "oban", "background", "queue", "workers"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :dashboard_packages,
      category: :core_cluster,
      title: "Dashboard Packages",
      description: "Install and manage packaged dashboards shipped as bundles.",
      icon: "hero-squares-2x2",
      route: "/settings/dashboards/packages",
      live_view: ServiceRadarWebNGWeb.Admin.DashboardPackageLive.Index,
      permission: "plugins.view",
      order: 30,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["dashboards", "packages", "wasm", "renderer"],
      badge: nil,
      hidden_from_nav: false
    },

    # --- Discovery & Sweeps --------------------------------------------------
    %{
      id: :sweep_profiles,
      category: :discovery_sweeps,
      title: "Sweep Profiles",
      description: "Configure network discovery sweeps, CIDR ranges, and scanner profiles.",
      icon: "hero-map",
      route: "/settings/networks",
      live_view: ServiceRadarWebNGWeb.Settings.NetworksLive.Index,
      permission: "settings.networks.manage",
      order: 10,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["sweep", "networks", "cidr", "scan", "profiles", "groups"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :discovery_jobs,
      category: :discovery_sweeps,
      title: "Discovery Jobs",
      description: "Schedule and track network mapper discovery jobs.",
      icon: "hero-magnifying-glass-circle",
      route: "/settings/networks/discovery",
      live_view: ServiceRadarWebNGWeb.Settings.NetworksLive.Index,
      permission: "settings.networks.manage",
      order: 20,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["discovery", "mapper", "jobs", "scan"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :device_enrichment,
      category: :discovery_sweeps,
      title: "Device Enrichment",
      description: "Define rules that enrich discovered devices with metadata.",
      icon: "hero-sparkles",
      route: "/settings/networks/device-enrichment",
      live_view: ServiceRadarWebNGWeb.Settings.DeviceEnrichmentRulesLive,
      permission: "settings.networks.manage",
      order: 30,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["enrichment", "device", "rules", "metadata"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :availability_sources,
      category: :discovery_sweeps,
      title: "Availability Sources",
      description: "Choose which sources decide device availability and uptime.",
      icon: "hero-signal",
      route: "/settings/networks/availability-sources",
      live_view: ServiceRadarWebNGWeb.Settings.AvailabilitySourceProfilesLive,
      permission: "settings.networks.manage",
      order: 40,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["availability", "source", "uptime", "reachability"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :visibility_profiles,
      category: :discovery_sweeps,
      title: "Visibility Profiles",
      description: "Scope which devices and partitions each profile can see.",
      icon: "hero-eye",
      route: "/settings/networks/visibility-profiles",
      live_view: ServiceRadarWebNGWeb.Settings.VisibilityProfilesLive.Index,
      permission: "visibility_profiles:read",
      order: 50,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["visibility", "profiles", "scope", "partition"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :credential_rules,
      category: :discovery_sweeps,
      title: "Credential Rules",
      description: "Map network credentials to hosts for authenticated scans.",
      icon: "hero-key",
      route: "/settings/networks/credentials",
      live_view: ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLive,
      permission: "settings.credentials.manage",
      order: 60,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["credentials", "secrets", "rules", "snmp", "ssh"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :snmp_profiles,
      category: :discovery_sweeps,
      title: "SNMP Profiles",
      description: "Configure SNMP versions, communities, and polling profiles.",
      icon: "hero-adjustments-horizontal",
      route: "/settings/snmp",
      live_view: ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index,
      permission: "settings.snmp_profiles.manage",
      order: 70,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["snmp", "oid", "community", "v3", "polling"],
      badge: nil,
      hidden_from_nav: false
    },

    # --- Edge Ops ------------------------------------------------------------
    %{
      id: :agent_releases,
      category: :edge_ops,
      title: "Agent Releases",
      description: "Browse and promote agent release channels and versions.",
      icon: "hero-rocket-launch",
      route: "/settings/agents/releases",
      live_view: ServiceRadarWebNGWeb.Settings.AgentsLive.Releases,
      permission: "settings.edge.manage",
      order: 10,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["agents", "releases", "versions", "rollout"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :agent_deploy,
      category: :edge_ops,
      title: "Agent Deploy",
      description: "Deploy and roll out agents to your fleet.",
      icon: "hero-cloud-arrow-up",
      route: "/settings/agents/deploy",
      live_view: ServiceRadarWebNGWeb.Settings.AgentsLive.Deploy,
      permission: "settings.edge.manage",
      order: 20,
      feature_flag: nil,
      capability: nil,
      match_prefixes: ["/settings/agents/deploy", "/admin/edge-packages"],
      keywords: ["deploy", "edge", "packages", "provisioning", "install"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :plugins,
      category: :edge_ops,
      title: "Plugins",
      description: "Package, sign, and distribute agent plugins.",
      icon: "hero-puzzle-piece",
      route: "/settings/agents/plugins",
      live_view: ServiceRadarWebNGWeb.Admin.PluginPackageLive.Index,
      permission: "plugins.view",
      order: 30,
      feature_flag: nil,
      capability: nil,
      match_prefixes: ["/settings/agents/plugins", "/admin/plugins"],
      keywords: ["plugins", "packages", "extensions"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :addons,
      category: :edge_ops,
      title: "Add-ons",
      description: "Manage optional agent add-on packages.",
      icon: "hero-squares-plus",
      route: "/settings/agents/addons",
      live_view: ServiceRadarWebNGWeb.Admin.AddonPackageLive.Index,
      permission: "plugins.view",
      order: 40,
      feature_flag: nil,
      capability: nil,
      match_prefixes: ["/settings/agents/addons", "/admin/addons"],
      keywords: ["addons", "add-ons", "extensions", "packages"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :addon_fleet,
      category: :edge_ops,
      title: "Add-on Fleet",
      description: "Assign add-ons to agents and track fleet rollout.",
      icon: "hero-server",
      route: "/settings/agents/addons/fleet",
      live_view: ServiceRadarWebNGWeb.Admin.AddonFleetLive.Index,
      permission: "plugins.view",
      order: 50,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["addon", "fleet", "rollout", "assignments"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :host_health,
      category: :edge_ops,
      title: "Host Health",
      description: "Review host-level health and resource telemetry.",
      icon: "hero-cpu-chip",
      route: "/settings/sysmon",
      live_view: ServiceRadarWebNGWeb.Settings.SysmonProfilesLive.Index,
      permission: "settings.sysmon_profiles.manage",
      order: 60,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["sysmon", "host", "cpu", "memory", "disk", "health"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :endpoint_inventory,
      category: :edge_ops,
      title: "Endpoint Inventory",
      description: "Configure endpoint software and SBOM inventory collection.",
      icon: "hero-clipboard-document-check",
      route: "/settings/agents/endpoint-inventory",
      live_view: ServiceRadarWebNGWeb.Settings.EndpointInventoryLive.Index,
      permission: "settings.edge.manage",
      order: 70,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["endpoint", "inventory", "sbom", "packages", "software"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :telemetry_onboarding,
      category: :edge_ops,
      title: "Telemetry Onboarding",
      description: "Send your first telemetry: OTLP endpoints, keys, and snippets.",
      icon: "hero-arrow-up-on-square-stack",
      route: "/settings/agents/telemetry-onboarding",
      live_view: ServiceRadarWebNGWeb.Settings.TelemetryOnboardingLive,
      permission: "settings.edge.manage",
      order: 80,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["telemetry", "otlp", "onboarding", "ingest", "exporter"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :edge_sites,
      category: :edge_ops,
      title: "Edge Sites",
      description: "Manage edge sites and their agent groupings.",
      icon: "hero-building-office-2",
      route: "/admin/edge-sites",
      live_view: ServiceRadarWebNGWeb.Admin.EdgeSitesLive.Index,
      permission: "settings.edge.manage",
      order: 90,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["edge", "sites", "locations", "regions"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :data_collectors,
      category: :edge_ops,
      title: "Data Collectors",
      description: "Configure data collectors that ingest external telemetry.",
      icon: "hero-inbox-arrow-down",
      route: "/admin/collectors",
      live_view: ServiceRadarWebNGWeb.Admin.CollectorLive.Index,
      permission: "plugins.view",
      order: 100,
      feature_flag: nil,
      capability: :collectors_enabled,
      match_prefixes: nil,
      keywords: ["collectors", "nats", "data", "ingest"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :ansible,
      category: :edge_ops,
      title: "Ansible",
      description: "Manage Ansible controllers, repositories, and schedules.",
      icon: "hero-command-line",
      route: "/settings/ansible",
      live_view: ServiceRadarWebNGWeb.Settings.AnsibleLive,
      permission: "ansible.controllers.manage",
      order: 110,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["ansible", "automation", "playbook", "controllers"],
      badge: nil,
      hidden_from_nav: false
    },

    # --- Network Services ----------------------------------------------------
    %{
      id: :network_flows,
      category: :network_services,
      title: "Network Flows",
      description: "Configure NetFlow directionality and enrichment rules.",
      icon: "hero-arrows-right-left",
      route: "/settings/flows",
      live_view: ServiceRadarWebNGWeb.Settings.NetflowLive.Index,
      permission: "settings.netflow.manage",
      order: 10,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["netflow", "flows", "sflow", "ipfix", "app rules"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :bmp,
      category: :network_services,
      title: "BGP / BMP",
      description: "Inspect BGP and BMP monitoring sessions and route state.",
      icon: "hero-globe-alt",
      route: "/settings/networks/bmp",
      live_view: ServiceRadarWebNGWeb.Settings.BmpLive.Index,
      permission: "settings.networks.manage",
      order: 20,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["bmp", "bgp", "routing", "peers", "monitoring"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :field_survey,
      category: :network_services,
      title: "FieldSurvey",
      description: "Review WiFi FieldSurvey captures and coverage.",
      icon: "hero-wifi",
      route: "/settings/networks/field-survey",
      live_view: ServiceRadarWebNGWeb.Settings.FieldSurveyLive.Index,
      permission: "settings.networks.manage",
      order: 30,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["field survey", "wifi", "rf", "spectrum", "site survey"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :mtr,
      category: :network_services,
      title: "MTR",
      description: "Configure MTR traceroute diagnostic profiles.",
      icon: "hero-arrow-trending-up",
      route: "/settings/networks/mtr",
      live_view: ServiceRadarWebNGWeb.Settings.MtrProfilesLive.Index,
      permission: "settings.networks.manage",
      order: 40,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["mtr", "traceroute", "latency", "path", "hops"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :integrations,
      category: :network_services,
      title: "Integrations",
      description: "Connect external asset and inventory integration sources.",
      icon: "hero-link",
      route: "/settings/networks/integrations",
      live_view: ServiceRadarWebNGWeb.Settings.IntegrationsLive.Index,
      permission: "settings.integrations.manage",
      order: 50,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["integrations", "armis", "netbox", "sources", "sync"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :threat_intel,
      category: :network_services,
      title: "Threat Intel",
      description: "Manage threat-intelligence feeds and enrichment.",
      icon: "hero-shield-exclamation",
      route: "/settings/networks/threat-intel",
      live_view: ServiceRadarWebNGWeb.Settings.ThreatIntelLive.Index,
      permission: "plugins.assign",
      order: 60,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["threat", "intel", "ioc", "feeds", "indicators"],
      badge: nil,
      hidden_from_nav: false
    },

    # --- Mail & Alerts -------------------------------------------------------
    %{
      id: :mail,
      category: :mail_alerts,
      title: "Mail",
      description: "Configure outbound mail delivery for notifications.",
      icon: "hero-envelope",
      route: "/settings/mail",
      live_view: ServiceRadarWebNGWeb.Settings.MailLive,
      permission: "settings.mail.manage",
      order: 10,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["mail", "smtp", "email", "notifications"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :rules,
      category: :mail_alerts,
      title: "Rules",
      description: "Author alerting and automation rules.",
      icon: "hero-funnel",
      route: "/settings/rules",
      live_view: ServiceRadarWebNGWeb.Settings.RulesLive.Index,
      permission: "observability.rules.view",
      order: 20,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["rules", "alerting", "zen", "jdm", "conditions"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :anomaly_detection,
      category: :mail_alerts,
      title: "Anomaly Detection",
      description: "Tune anomaly-detection baselines and sensitivity.",
      icon: "hero-bell-alert",
      route: "/settings/anomaly-detection",
      live_view: ServiceRadarWebNGWeb.Settings.AnomalyDetectionLive,
      permission: "observability.alerts.manage",
      order: 30,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["anomaly", "detection", "baseline", "seasonal", "alerts"],
      badge: nil,
      hidden_from_nav: false
    },

    # --- Security & Auth -----------------------------------------------------
    %{
      id: :auth_users,
      category: :security_auth,
      title: "Users",
      description: "Manage user accounts, roles, and access.",
      icon: "hero-users",
      route: "/settings/auth/users",
      live_view: ServiceRadarWebNGWeb.Settings.AuthUsersLive,
      permission: "settings.auth.manage",
      order: 10,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["users", "accounts", "identity", "members"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :policy_editor,
      category: :security_auth,
      title: "Policy Editor",
      description: "Edit authorization policies and role bindings.",
      icon: "hero-shield-check",
      route: "/settings/auth/rbac",
      live_view: ServiceRadarWebNGWeb.Settings.RbacLive,
      permission: "settings.rbac.manage",
      order: 20,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["rbac", "roles", "permissions", "policy", "access"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :authentication,
      category: :security_auth,
      title: "Authentication",
      description: "Configure SSO, OIDC, and login authentication.",
      icon: "hero-identification",
      route: "/settings/authentication",
      live_view: ServiceRadarWebNGWeb.Settings.AuthenticationLive,
      permission: "settings.auth.manage",
      order: 30,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["authentication", "oidc", "saml", "sso", "login"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :user_groups,
      category: :security_auth,
      title: "User Groups",
      description: "Manage reusable groups for dashboard sharing and access.",
      icon: "hero-user-group",
      route: "/settings/user-groups",
      live_view: ServiceRadarWebNGWeb.Settings.UserGroupsLive,
      permission: "identity.user_groups.manage",
      order: 40,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["groups", "teams", "membership", "share"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :vulnerability_feeds,
      category: :security_auth,
      title: "Vulnerability Feeds",
      description: "Configure CVE, CPE, and vulnerability feed sources.",
      icon: "hero-bug-ant",
      route: "/settings/security/vulnerability-feeds",
      live_view: ServiceRadarWebNGWeb.Settings.SecurityLive.VulnerabilityFeeds,
      permission: "settings.integrations.manage",
      order: 50,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["cve", "vulnerability", "feeds", "nvd", "cpe", "advisory"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :host_keys,
      category: :security_auth,
      title: "Host Keys",
      description: "Manage SSH known-host keys and fingerprints.",
      icon: "hero-finger-print",
      route: "/settings/networks/host-keys",
      live_view: ServiceRadarWebNGWeb.Settings.RemoteAccessHostKeysLive,
      permission: "settings.remote_access_host_keys.manage",
      order: 60,
      feature_flag: :remote_access_ssh,
      capability: nil,
      match_prefixes: nil,
      keywords: ["ssh", "host keys", "known hosts", "fingerprint"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :desktop_targets,
      category: :security_auth,
      title: "Desktop Targets",
      description: "Configure RDP desktop remote-access targets.",
      icon: "hero-computer-desktop",
      route: "/settings/networks/desktop-targets",
      live_view: ServiceRadarWebNGWeb.Settings.RemoteAccessDesktopTargetsLive,
      permission: "settings.edge.manage",
      order: 70,
      feature_flag: :remote_access_desktop_rdp,
      capability: nil,
      match_prefixes: nil,
      keywords: ["rdp", "desktop", "remote", "targets"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :recordings,
      category: :security_auth,
      title: "Session Recordings",
      description: "Browse recorded remote-access session replays.",
      icon: "hero-film",
      route: "/settings/networks/recordings",
      live_view: ServiceRadarWebNGWeb.Settings.RemoteAccessRecordingsLive,
      permission: "devices.remote_access.recordings.view_all",
      order: 80,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["session", "recordings", "replay", "audit"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :api_credentials,
      category: :security_auth,
      title: "API Credentials",
      description: "Create and revoke personal API tokens and clients.",
      icon: "hero-key",
      route: "/settings/api-credentials",
      live_view: ServiceRadarWebNGWeb.UserLive.ApiCredentials,
      permission: nil,
      order: 90,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["api", "tokens", "keys", "credentials", "personal"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :cli_sessions,
      category: :security_auth,
      title: "CLI Sessions",
      description: "Review and revoke active serviceradar-cli sessions.",
      icon: "hero-command-line",
      route: "/settings/cli-sessions",
      live_view: ServiceRadarWebNGWeb.Settings.CliSessionsLive,
      permission: "cli.session.read_own",
      order: 100,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["cli", "sessions", "device", "tokens"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :cli_auth,
      category: :security_auth,
      title: "CLI Auth Policy",
      description: "Control the CLI device-code authorization policy.",
      icon: "hero-lock-closed",
      route: "/settings/cli-auth",
      live_view: ServiceRadarWebNGWeb.Settings.CliAuthPolicyLive,
      permission: "cli.policy.manage",
      order: 110,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["cli", "auth", "policy", "device code"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :profile,
      category: :security_auth,
      title: "Profile",
      description: "Manage your account, password, and preferences.",
      icon: "hero-user-circle",
      route: "/settings/profile",
      live_view: ServiceRadarWebNGWeb.UserLive.Settings,
      permission: nil,
      order: 120,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["profile", "account", "password", "me", "preferences"],
      badge: nil,
      hidden_from_nav: true
    },

    # --- Audit & System Log (Phase 1 pilot) ----------------------------------
    %{
      id: :audit_trail,
      category: :audit_system_log,
      title: "Audit Trail",
      description: "Browse stateless security events and audit entries.",
      icon: "hero-finger-print",
      route: "/settings/audit/events",
      live_view: ServiceRadarWebNGWeb.Settings.AuditLive.Events,
      permission: "settings.audit.view",
      order: 10,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["security", "events", "audit", "denials", "signature", "policy", "csp"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :lockouts,
      category: :audit_system_log,
      title: "Lockouts",
      description: "Review account lockouts and rate-limit triggers.",
      icon: "hero-lock-closed",
      route: "/settings/audit/lockouts",
      live_view: ServiceRadarWebNGWeb.Settings.AuditLive.Lockouts,
      permission: "settings.audit.view",
      order: 20,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["lockout", "auth", "failed", "login", "rate limit"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :history,
      category: :audit_system_log,
      title: "History",
      description: "Cross-resource change history from AshPaperTrail.",
      icon: "hero-clock",
      route: "/settings/audit/history",
      live_view: ServiceRadarWebNGWeb.Settings.AuditLive.History,
      permission: "settings.audit.view",
      order: 30,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["history", "papertrail", "versions", "changes", "diff", "timeline"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :system_event_logs,
      category: :audit_system_log,
      title: "System Event Logs",
      description: "Search ingested system and application event logs.",
      icon: "hero-document-text",
      route: "/logs",
      live_view: ServiceRadarWebNGWeb.LogLive.Index,
      permission: "observability.logs.view",
      order: 40,
      feature_flag: nil,
      capability: nil,
      match_prefixes: ["/logs"],
      keywords: ["logs", "syslog", "system", "otel", "explorer"],
      badge: nil,
      hidden_from_nav: false
    }
  ]

  # ---------------------------------------------------------------------------
  # Icon rail roots (persistent, global). Reuses the operations app rail targets.
  # ---------------------------------------------------------------------------
  @rail_groups [
    %{id: :home, title: "Dashboard", icon: "hero-home", route: "/dashboard"},
    %{id: :apps, title: "Dashboards", icon: "hero-squares-2x2", route: "/dashboards"},
    %{id: :stack, title: "Devices", icon: "hero-server-stack", route: "/devices"},
    %{id: :settings, title: "Settings", icon: "hero-cog-6-tooth", route: "/settings/audit/events"}
  ]

  # ---------------------------------------------------------------------------
  # Raw literal accessors
  # ---------------------------------------------------------------------------

  @doc "All categories, unsorted (declaration order)."
  @spec categories() :: [category()]
  def categories, do: @categories

  @doc "All views, unsorted (declaration order)."
  @spec views() :: [view()]
  def views, do: @views

  @doc "The icon-rail roots (home / apps / stack / settings)."
  @spec rail_groups() :: [map()]
  def rail_groups, do: @rail_groups

  @doc "Look up a category by id."
  @spec category(atom()) :: category() | nil
  def category(id) when is_atom(id), do: Enum.find(@categories, &(&1.id == id))

  @doc "Look up a view by id."
  @spec view(atom()) :: view() | nil
  def view(id) when is_atom(id), do: Enum.find(@views, &(&1.id == id))

  @doc """
  The canonical route string for a view id.

  This is the single-source-of-truth accessor the legacy `SettingsComponents`
  tab bar uses (via the thin adapter) so the same route strings drive both the
  legacy chrome and the new catalog shell. Raises on an unknown view id so a
  typo fails fast in tests rather than rendering a broken link.
  """
  @spec route(atom()) :: String.t()
  def route(view_id) when is_atom(view_id) do
    case view(view_id) do
      %{route: route} -> route
      nil -> raise ArgumentError, "unknown settings view #{inspect(view_id)}"
    end
  end

  @doc "The permission key that gates a view id (`nil` when ungated)."
  @spec permission(atom()) :: String.t() | nil
  def permission(view_id) when is_atom(view_id) do
    case view(view_id) do
      %{permission: permission} -> permission
      nil -> raise ArgumentError, "unknown settings view #{inspect(view_id)}"
    end
  end

  @doc "All views belonging to a category, sorted by `:order`."
  @spec views_for_category(atom()) :: [view()]
  def views_for_category(category_id) when is_atom(category_id) do
    @views
    |> Enum.filter(&(&1.category == category_id))
    |> Enum.sort_by(& &1.order)
  end

  @doc """
  The match prefixes for a view.

  Defaults to `[view.route]` unless the view overrides `:match_prefixes`.
  """
  @spec match_prefixes(view()) :: [String.t()]
  def match_prefixes(%{match_prefixes: prefixes}) when is_list(prefixes) and prefixes != [], do: prefixes

  def match_prefixes(%{route: route}), do: [route]

  # ---------------------------------------------------------------------------
  # Active-view resolution (longest-prefix winner)
  # ---------------------------------------------------------------------------

  @doc """
  Resolve the active view for a path via longest-prefix match across all views.

  Returns the view whose matching prefix is the longest, or `nil` when no view
  matches. This is the structural fix for shared URI roots (e.g.
  `/settings/networks` vs `/settings/networks/bmp`).
  """
  @spec view_for_path(String.t() | nil) :: view() | nil
  def view_for_path(path) when is_binary(path) do
    normalized = normalize_path(path)

    @views
    |> Enum.flat_map(fn view ->
      Enum.map(match_prefixes(view), fn prefix -> {view, prefix} end)
    end)
    |> Enum.filter(fn {_view, prefix} -> prefix_match?(normalized, prefix) end)
    |> Enum.max_by(fn {_view, prefix} -> String.length(prefix) end, fn -> nil end)
    |> case do
      nil -> nil
      {view, _prefix} -> view
    end
  end

  def view_for_path(_), do: nil

  @doc "The category that owns the given view."
  @spec category_for_view(view() | nil) :: category() | nil
  def category_for_view(%{category: category_id}), do: category(category_id)
  def category_for_view(_), do: nil

  @doc """
  Breadcrumb trail for a path: `[Settings, Category, View]`.

  Each crumb is `%{label: String.t(), route: String.t() | nil}`. When the path
  does not resolve to a view, only the root `Settings` crumb is returned.
  """
  @spec breadcrumbs_for_path(String.t() | nil) :: [%{label: String.t(), route: String.t() | nil}]
  def breadcrumbs_for_path(path) do
    root = %{label: "Settings", route: settings_landing_route()}

    case view_for_path(path) do
      nil ->
        [root]

      view ->
        category = category_for_view(view)

        [
          root,
          %{label: category_title(category), route: category_landing_route(category)},
          %{label: view.title, route: view.route}
        ]
    end
  end

  @doc """
  The default Settings landing route: the first category's first view. Lets the
  "Settings" breadcrumb crumb be a real navigable link.
  """
  @spec settings_landing_route() :: String.t()
  def settings_landing_route do
    case Enum.sort_by(@categories, & &1.order) do
      [%{id: id} | _] -> category_landing_route(id)
      _ -> "/settings/cluster"
    end
  end

  @doc """
  The landing route for a category: its first view by `:order`. Used by the topbar
  category switcher and the category breadcrumb crumb.
  """
  @spec category_landing_route(atom() | map()) :: String.t()
  def category_landing_route(%{id: id}), do: category_landing_route(id)

  def category_landing_route(category_id) when is_atom(category_id) do
    case views_for_category(category_id) do
      [%{route: route} | _] -> route
      _ -> "/settings/cluster"
    end
  end

  # ---------------------------------------------------------------------------
  # Scope-aware visibility (RBAC + feature flags + capabilities)
  # ---------------------------------------------------------------------------

  @doc """
  Whether a view is visible to `scope`: permitted AND feature-flag enabled AND
  capability enabled.
  """
  @spec visible_view?(term(), view()) :: boolean()
  def visible_view?(scope, view) do
    permitted?(scope, view.permission) and
      feature_enabled?(view.feature_flag) and
      capability_enabled?(view.capability)
  end

  @doc """
  Categories that have at least one view visible to `scope`, sorted by `:order`.

  A category with its own `:permission`/`:feature_flag` must also pass those
  gates.
  """
  @spec visible_categories(term()) :: [category()]
  def visible_categories(scope) do
    @categories
    |> Enum.filter(fn category ->
      permitted?(scope, category.permission) and
        feature_enabled?(category.feature_flag) and
        Enum.any?(visible_views(scope, category.id))
    end)
    |> Enum.sort_by(& &1.order)
  end

  @doc """
  Views in a category that are visible to `scope` and not hidden from nav,
  sorted by `:order`.
  """
  @spec visible_views(term(), atom()) :: [view()]
  def visible_views(scope, category_id) when is_atom(category_id) do
    category_id
    |> views_for_category()
    |> Enum.filter(fn view -> not view.hidden_from_nav and visible_view?(scope, view) end)
  end

  @doc """
  Flattened palette index for the Ctrl+K command palette, over the views visible
  to `scope` (including nav-hidden but deep-linkable views), sorted by category
  then view order.

  Each entry: `%{category_title, view_title, route, icon, keywords, id}`.
  """
  @spec palette_index(term()) :: [map()]
  def palette_index(scope) do
    @views
    |> Enum.filter(fn view -> visible_view?(scope, view) end)
    |> Enum.sort_by(fn view -> {category_order(view.category), view.order} end)
    |> Enum.map(fn view ->
      %{
        id: view.id,
        category_title: category_title(category(view.category)),
        view_title: view.title,
        description: Map.get(view, :description),
        route: view.route,
        icon: view.icon,
        keywords: view.keywords
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp category_title(nil), do: "Settings"
  defp category_title(%{title: title}), do: title

  defp category_order(category_id) do
    case category(category_id) do
      %{order: order} -> order
      _ -> 9_999
    end
  end

  defp normalize_path(path) do
    path
    |> strip_query()
    |> strip_trailing_slash()
  end

  defp strip_query(path) do
    path
    |> String.split("?", parts: 2)
    |> List.first()
  end

  defp strip_trailing_slash("/"), do: "/"

  defp strip_trailing_slash(path) do
    String.replace_suffix(path, "/", "")
  end

  defp prefix_match?(path, prefix) do
    path == prefix or String.starts_with?(path, prefix <> "/")
  end

  # permission: nil means "no gate" (visible to any authenticated scope).
  defp permitted?(_scope, nil), do: true
  defp permitted?(scope, permission) when is_binary(permission), do: RBAC.can?(scope, permission)

  # feature_flag: nil means "always on". Known flags map to FeatureFlags.
  defp feature_enabled?(nil), do: true
  defp feature_enabled?(:remote_access_ssh), do: FeatureFlags.remote_access_ssh_enabled?()
  defp feature_enabled?(:remote_access_desktop_rdp), do: FeatureFlags.remote_access_desktop_rdp_enabled?()
  defp feature_enabled?(:remote_access_app), do: FeatureFlags.remote_access_app_enabled?()
  defp feature_enabled?(:remote_access_tcp), do: FeatureFlags.remote_access_tcp_enabled?()
  defp feature_enabled?(:god_view), do: FeatureFlags.god_view_enabled?()
  # Unknown flag atoms default to disabled so a mis-typed flag hides the view
  # rather than silently exposing it.
  defp feature_enabled?(_), do: false

  # capability: nil means "no capability gate". An unknown capability atom
  # hides the view (fail-closed) rather than crashing the whole nav.
  defp capability_enabled?(nil), do: true

  defp capability_enabled?(capability) do
    Capabilities.enabled?(capability)
  rescue
    _ -> false
  end
end
