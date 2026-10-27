defmodule ServiceRadarWebNGWeb.Settings.Catalog do
  @moduledoc """
  Declarative catalog of the web-ng Settings navigation.

  This module is the single source of truth for the Settings information
  architecture. It is modeled on `ServiceRadar.Identity.RBAC.Catalog`: literal
  data structures (`@categories`, `@parent_groups`, and a flat `@views`) plus
  pure derived accessors. Every Settings navigation surface — the icon rail, the
  topbar category switcher, the left view tree, the breadcrumbs, and the Ctrl+K
  command palette — renders entirely from this catalog, so adding a page is one
  map entry with zero layout risk.

  ## Information architecture (2-level tree)

  There are exactly **three** top-level categories — `System`,
  `Network Services`, and `Edge Ops` — shown as the topbar tabs. Under each
  category the left panel renders a **two-level tree**:

      category → collapsible parent-group → leaf view

  A view names its owning category (`:category`) and its `:parent_group`. Within
  a parent-group, views may additionally carry a `:subgroup` string that renders
  as a non-collapsible labelled run (e.g. Security → *Users & Access* /
  *Credentials* / *Remote Access* / *Threat Intelligence*, Discovery →
  *Profiles*). A subgroup's views must remain contiguous when sorted by `:order`
  within their parent-group, or the run splits into two headed sections. The only
  collapsible level is the parent-group.

  ## Why here (web-ng) and not in serviceradar_core

  The RBAC permission catalog lives in `serviceradar_core` because permissions
  are shared by web-ng and the API. This navigation catalog references
  web-ng-only concerns (LiveView modules, `~p` routes, heroicon names, feature
  flags), so it belongs in web-ng. It does **not** invent permission strings:
  each view's `:permission` field carries a key or OR-list of keys that must exist in
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

  ## Contextual status cards

  Each view carries a `:has_own_stats` boolean. When it is `true` (e.g. the
  Cluster Status page, which renders its own Oban queue metrics) the shell
  suppresses the shared status-card strip entirely. Otherwise the strip is
  contextual: `ServiceRadarWebNGWeb.Settings.StatusCards.for_view/1` resolves a
  card set from the view → parent-group → category, and each metric independently
  degrades to `"—"`.
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

  @typedoc "A collapsible parent-group inside a category (the middle tree level)."
  @type parent_group :: %{
          id: atom(),
          category: atom(),
          title: String.t(),
          icon: String.t(),
          order: non_neg_integer()
        }

  @typedoc """
  An in-page tab sub-entry under a settings view.

  `:route` is the view route with `?tab=<tab>`, or `<view route>/<tab>` for a
  LiveView whose tab is a path segment. The view's LiveView lists every tab it
  handles in `supported_tabs/0`, and the catalog test requires a sub-entry for
  each one.
  """
  @type tab :: %{
          optional(:description) => String.t(),
          id: atom(),
          tab: String.t(),
          title: String.t(),
          route: String.t(),
          keywords: [String.t()],
          permission: String.t() | [String.t()] | nil
        }

  @typedoc "A settings view (left-tree leaf + deep-linkable page)."
  @type view :: %{
          optional(:tabs) => [tab()],
          optional(:visible_tabs) => [tab()],
          id: atom(),
          category: atom(),
          parent_group: atom(),
          subgroup: String.t() | nil,
          title: String.t(),
          description: String.t(),
          icon: String.t(),
          route: String.t(),
          live_view: module(),
          permission: String.t() | [String.t()] | nil,
          order: non_neg_integer(),
          has_own_stats: boolean(),
          feature_flag: atom() | nil,
          capability: atom() | nil,
          match_prefixes: [String.t()] | nil,
          keywords: [String.t()],
          badge: atom() | nil,
          hidden_from_nav: boolean()
        }

  # ---------------------------------------------------------------------------
  # Categories (topbar switcher order). Exactly three.
  # ---------------------------------------------------------------------------
  @categories [
    %{
      id: :system,
      title: "System",
      icon: "hero-server-stack",
      order: 10,
      rail_group: :settings,
      permission: nil,
      feature_flag: nil
    },
    %{
      id: :network_services,
      title: "Network Services",
      icon: "hero-globe-alt",
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
    }
  ]

  # ---------------------------------------------------------------------------
  # Parent-groups (the collapsible middle tree level). Each names its category.
  # ---------------------------------------------------------------------------
  @parent_groups [
    # System
    %{id: :sys_cluster, category: :system, title: "Platform", icon: "hero-server-stack", order: 10},
    %{id: :sys_security, category: :system, title: "Security", icon: "hero-shield-check", order: 20},
    %{id: :sys_alerts, category: :system, title: "Alerts", icon: "hero-bell-alert", order: 30},
    %{
      id: :sys_dashboards,
      category: :system,
      title: "Dashboards",
      icon: "hero-squares-2x2",
      order: 40
    },
    %{
      id: :sys_personal,
      category: :system,
      title: "Personal",
      icon: "hero-user-circle",
      order: 50
    },

    # Network Services
    %{
      id: :net_discovery,
      category: :network_services,
      title: "Discovery",
      icon: "hero-magnifying-glass",
      order: 10
    },
    %{
      id: :net_services,
      category: :network_services,
      title: "Services",
      icon: "hero-globe-alt",
      order: 20
    },

    # Edge Ops
    %{id: :edge_agents, category: :edge_ops, title: "Agents", icon: "hero-rocket-launch", order: 10},
    %{id: :edge_addons, category: :edge_ops, title: "Add-ons", icon: "hero-squares-plus", order: 20},
    %{
      id: :edge_fleet,
      category: :edge_ops,
      title: "Fleet Health",
      icon: "hero-cpu-chip",
      order: 30
    },
    %{
      id: :edge_sites,
      category: :edge_ops,
      title: "Sites & Collectors",
      icon: "hero-building-office-2",
      order: 40
    },
    %{
      id: :edge_automation,
      category: :edge_ops,
      title: "Automation",
      icon: "hero-command-line",
      order: 50
    }
  ]

  # ---------------------------------------------------------------------------
  # Views (flat list; each carries `category:` + `parent_group:` as FKs).
  #
  # Every entry maps to an existing route + LiveView verified against the router
  # (the orphan detector in the catalog test enforces this). `permission:` carries
  # a key or OR-list validated against
  # `ServiceRadar.Identity.RBAC.Catalog.permission_keys/0`.
  # `match_prefixes:` is set only where a view must also own a legacy `/admin/*`
  # duplicate route so the shell highlights the correct view there.
  # ---------------------------------------------------------------------------
  @views [
    # === System · Platform ===================================================
    %{
      id: :cluster_status,
      category: :system,
      parent_group: :sys_cluster,
      subgroup: nil,
      title: "Cluster Status",
      description: "Monitor the distributed ERTS cluster, gateways, agents, and job queues.",
      icon: "hero-server-stack",
      route: "/settings/cluster",
      live_view: ServiceRadarWebNGWeb.Settings.ClusterLive.Index,
      permission: "settings.view",
      order: 10,
      has_own_stats: true,
      feature_flag: nil,
      capability: nil,
      match_prefixes: ["/settings/cluster", "/admin/cluster"],
      keywords: [
        "cluster",
        "nodes",
        "health",
        "status",
        "infrastructure",
        "gateways",
        "agents",
        "job queues",
        "erts",
        "beam",
        "mtls",
        "events"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :jobs,
      category: :system,
      parent_group: :sys_cluster,
      subgroup: nil,
      title: "Jobs",
      description: "Review scheduled background jobs, cron schedules and AshOban triggers, and run a job now.",
      icon: "hero-queue-list",
      route: "/admin/jobs",
      live_view: ServiceRadarWebNGWeb.Admin.JobLive.Index,
      permission: "settings.jobs.manage",
      order: 30,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "jobs",
        "oban",
        "background",
        "queue",
        "workers",
        "scheduler",
        "cron",
        "schedule",
        "trigger",
        "ashoban",
        "leader"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :data_retention,
      category: :system,
      parent_group: :sys_cluster,
      subgroup: nil,
      title: "Data retention",
      description: "Set how many days of each telemetry dataset the warehouse keeps.",
      icon: "hero-archive-box",
      route: "/settings/data-retention",
      live_view: ServiceRadarWebNGWeb.Settings.DataRetentionLive,
      permission: ["settings.data_retention.view", "settings.data_retention.manage"],
      order: 40,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "retention",
        "ttl",
        "warehouse",
        "starrocks",
        "storage",
        "partitions",
        "days",
        "flows",
        "netflow",
        "metrics",
        "logs",
        "events",
        "traces",
        "otel",
        "mtr",
        "bmp",
        "applier"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :endpoint_inventory,
      category: :system,
      parent_group: :sys_cluster,
      subgroup: nil,
      title: "Endpoint Inventory",
      description: "Set how long historical endpoint software and SBOM scans are kept.",
      icon: "hero-clipboard-document-check",
      route: "/settings/agents/endpoint-inventory",
      live_view: ServiceRadarWebNGWeb.Settings.EndpointInventoryLive.Index,
      permission: "settings.edge.manage",
      order: 45,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "endpoint",
        "inventory",
        "sbom",
        "packages",
        "software",
        "retention",
        "days",
        "history",
        "scan"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :mail,
      category: :system,
      parent_group: :sys_cluster,
      subgroup: nil,
      title: "Mail",
      description: "Configure outbound mail for dashboard reports and other system email.",
      icon: "hero-envelope",
      route: "/settings/mail",
      live_view: ServiceRadarWebNGWeb.Settings.MailLive,
      permission: "settings.mail.manage",
      order: 50,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "mail",
        "smtp",
        "email",
        "notifications",
        "outbound",
        "adapter",
        "ses",
        "smtp2go",
        "relay",
        "tls",
        "sender",
        "test email"
      ],
      badge: nil,
      hidden_from_nav: false
    },

    # === System · Security · Users & Access ==================================
    %{
      id: :auth_users,
      category: :system,
      parent_group: :sys_security,
      subgroup: "Users & Access",
      title: "Users",
      description: "Manage user accounts, roles, and access.",
      icon: "hero-users",
      route: "/settings/auth/users",
      live_view: ServiceRadarWebNGWeb.Settings.AuthUsersLive,
      permission: "settings.auth.manage",
      order: 110,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "users",
        "accounts",
        "identity",
        "members",
        "roles",
        "access profile",
        "add account",
        "deactivate",
        "reactivate",
        "password",
        "email",
        "login history"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :user_groups,
      category: :system,
      parent_group: :sys_security,
      subgroup: "Users & Access",
      title: "User Groups",
      description: "Manage reusable groups for dashboard sharing and access.",
      icon: "hero-user-group",
      route: "/settings/user-groups",
      live_view: ServiceRadarWebNGWeb.Settings.UserGroupsLive,
      permission: "identity.user_groups.manage",
      order: 120,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "groups",
        "teams",
        "membership",
        "share",
        "sharing",
        "homepage",
        "default dashboard",
        "priority",
        "add member"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :authentication,
      category: :system,
      parent_group: :sys_security,
      subgroup: "Users & Access",
      title: "Authentication",
      description: "Configure sign-in: local passwords, SSO with OIDC or SAML, or a gateway proxy.",
      icon: "hero-identification",
      route: "/settings/authentication",
      live_view: ServiceRadarWebNGWeb.Settings.AuthenticationLive,
      permission: "settings.auth.manage",
      order: 130,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "authentication",
        "oidc",
        "saml",
        "sso",
        "login",
        "password",
        "jwt",
        "jwks",
        "proxy",
        "pkce",
        "entra",
        "authentik",
        "openid",
        "identity provider",
        "idp",
        "jit",
        "auto-provision",
        "claims",
        "client secret",
        "redirect uri",
        "metadata"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :authorization_mappings,
      category: :system,
      parent_group: :sys_security,
      subgroup: "Users & Access",
      title: "Authorization",
      description: "Map identity provider groups to roles, permission sets, and user groups.",
      icon: "hero-user-group",
      route: "/settings/auth/authorization",
      live_view: ServiceRadarWebNGWeb.Settings.AuthorizationLive,
      permission: "settings.auth.manage",
      order: 145,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "authorization",
        "groups",
        "claims",
        "mapping",
        "sso",
        "entra",
        "default role",
        "idp",
        "identity provider",
        "homepage",
        "default homepage",
        "first login",
        "provisioning",
        "role profile",
        "user group",
        "test claims",
        "permission set"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :policy_editor,
      category: :system,
      parent_group: :sys_security,
      subgroup: "Users & Access",
      title: "Policy Editor",
      description: "Edit authorization policies and role bindings.",
      icon: "hero-shield-check",
      route: "/settings/auth/rbac",
      live_view: ServiceRadarWebNGWeb.Settings.RbacLive,
      permission: "settings.rbac.manage",
      order: 140,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "rbac",
        "roles",
        "permissions",
        "policy",
        "access",
        "role profiles",
        "clone",
        "permission grid",
        "dashboard access",
        "grant",
        "user group",
        "built-in"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :cli_sessions,
      category: :system,
      parent_group: :sys_security,
      subgroup: "Users & Access",
      title: "CLI Sessions",
      description: "Review and revoke active serviceradar-cli sessions.",
      icon: "hero-command-line",
      route: "/settings/cli-sessions",
      live_view: ServiceRadarWebNGWeb.Settings.CliSessionsLive,
      permission: "cli.session.read_own",
      order: 150,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "cli",
        "sessions",
        "device",
        "tokens",
        "revoke",
        "bearer",
        "scope",
        "expires",
        "serviceradar-cli"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :cli_auth,
      category: :system,
      parent_group: :sys_security,
      subgroup: "Users & Access",
      title: "CLI Auth Policy",
      description: "Control the CLI device-code authorization policy.",
      icon: "hero-lock-closed",
      route: "/settings/cli-auth",
      live_view: ServiceRadarWebNGWeb.Settings.CliAuthPolicyLive,
      permission: "cli.policy.manage",
      order: 160,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "cli",
        "auth",
        "authentication",
        "policy",
        "device code",
        "ttl",
        "token",
        "expiry",
        "scopes"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :audit_trail,
      category: :system,
      parent_group: :sys_security,
      subgroup: "Users & Access",
      title: "Audit Trail",
      description: "Browse stateless security events and audit entries.",
      icon: "hero-finger-print",
      route: "/settings/audit/events",
      live_view: ServiceRadarWebNGWeb.Settings.AuditLive.Events,
      permission: "settings.audit.view",
      order: 180,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "security",
        "events",
        "audit",
        "denials",
        "signature",
        "policy",
        "csp",
        "rate limit",
        "violations",
        "severity",
        "actor",
        "ip",
        "correlation id",
        "lockout"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :lockouts,
      category: :system,
      parent_group: :sys_security,
      subgroup: "Users & Access",
      title: "Lockouts",
      description: "Review account lockouts and rate-limit triggers.",
      icon: "hero-lock-closed",
      route: "/settings/audit/lockouts",
      live_view: ServiceRadarWebNGWeb.Settings.AuditLive.Lockouts,
      permission: "settings.audit.view",
      order: 190,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "lockout",
        "auth",
        "failed",
        "login",
        "rate limit",
        "unlock",
        "locked",
        "account",
        "brute force"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :history,
      category: :system,
      parent_group: :sys_security,
      subgroup: "Users & Access",
      title: "History",
      description: "Cross-resource change history from AshPaperTrail.",
      icon: "hero-clock",
      route: "/settings/audit/history",
      live_view: ServiceRadarWebNGWeb.Settings.AuditLive.History,
      permission: "settings.audit.view",
      order: 200,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "history",
        "papertrail",
        "versions",
        "changes",
        "diff",
        "timeline",
        "change log",
        "actor",
        "resource",
        "activity",
        "who changed"
      ],
      badge: nil,
      hidden_from_nav: false
    },

    # === System · Security · Credentials =====================================
    %{
      id: :api_credentials,
      category: :system,
      parent_group: :sys_security,
      subgroup: "Credentials",
      title: "API Credentials",
      description: "Manage access scopes and generate personal API tokens and clients.",
      icon: "hero-key",
      route: "/settings/api-credentials",
      live_view: ServiceRadarWebNGWeb.UserLive.ApiCredentials,
      permission: "settings.api_credentials.manage",
      order: 230,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "api",
        "tokens",
        "keys",
        "credentials",
        "personal",
        "oauth",
        "oauth2",
        "api client",
        "client id",
        "client secret",
        "scopes",
        "revoke",
        "client credentials"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :mcp_sessions,
      category: :system,
      parent_group: :sys_security,
      subgroup: "Credentials",
      title: "MCP Sessions",
      description: "Review and revoke MCP OAuth grants issued to native clients.",
      icon: "hero-cpu-chip",
      route: "/settings/mcp-sessions",
      live_view: ServiceRadarWebNGWeb.Settings.McpSessionsLive,
      permission: "settings.mcp.manage",
      order: 235,
      has_own_stats: false,
      feature_flag: :mcp,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "mcp",
        "oauth",
        "claude",
        "codex",
        "grok",
        "sessions",
        "revoke",
        "grants",
        "scopes",
        "clients",
        "ai"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :credential_rules,
      category: :system,
      parent_group: :sys_security,
      subgroup: "Credentials",
      title: "Credentials and Rules",
      description: "Manage reusable credentials and scoped rules for SNMP, SSH, and integrations.",
      icon: "hero-key",
      route: "/settings/networks/credentials",
      live_view: ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLive,
      permission: "settings.credentials.manage",
      order: 238,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "credentials",
        "secrets",
        "rules",
        "snmp",
        "ssh",
        "reusable",
        "credential rules",
        "rotate",
        "rotation",
        "consumers",
        "conflicts",
        "dry run",
        "provider",
        "password",
        "api key",
        "token",
        "tls",
        "certificate",
        "fingerprint",
        "host key",
        "cadence",
        "vlan",
        "switch port",
        "unifi protect",
        "rtsp"
      ],
      badge: nil,
      hidden_from_nav: false
    },

    # === System · Security · Remote Access ===================================
    %{
      id: :recordings,
      category: :system,
      parent_group: :sys_security,
      subgroup: "Remote Access",
      title: "Session Recordings",
      description: "Browse recorded remote-access session replays.",
      icon: "hero-film",
      route: "/settings/networks/recordings",
      live_view: ServiceRadarWebNGWeb.Settings.RemoteAccessRecordingsLive,
      permission: "devices.remote_access.recordings.view_all",
      order: 250,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "session",
        "recordings",
        "replay",
        "audit",
        "remote access",
        "export",
        "ssh",
        "rdp",
        "desktop",
        "retention"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :host_keys,
      category: :system,
      parent_group: :sys_security,
      subgroup: "Remote Access",
      title: "Host Keys",
      description: "Manage SSH known-host keys and fingerprints.",
      icon: "hero-finger-print",
      route: "/settings/networks/host-keys",
      live_view: ServiceRadarWebNGWeb.Settings.RemoteAccessHostKeysLive,
      permission: "settings.remote_access_host_keys.manage",
      order: 260,
      has_own_stats: false,
      feature_flag: :remote_access_ssh,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "ssh",
        "host keys",
        "known hosts",
        "fingerprint",
        "remote access",
        "trust",
        "reject",
        "rotate",
        "revoke",
        "conflict"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :desktop_targets,
      category: :system,
      parent_group: :sys_security,
      subgroup: "Remote Access",
      title: "Desktop Targets",
      description: "Configure RDP desktop remote-access targets.",
      icon: "hero-computer-desktop",
      route: "/settings/networks/desktop-targets",
      live_view: ServiceRadarWebNGWeb.Settings.RemoteAccessDesktopTargetsLive,
      permission: "settings.edge.manage",
      order: 270,
      has_own_stats: false,
      feature_flag: :remote_access_desktop_rdp,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "rdp",
        "desktop",
        "remote",
        "targets",
        "rdp access",
        "remote access",
        "windows",
        "gateway",
        "sign-in",
        "credential",
        "nla",
        "tls",
        "recording",
        "kerberos",
        "kdc",
        "clipboard",
        "screen",
        "principals"
      ],
      badge: nil,
      hidden_from_nav: false
    },

    # === System · Security · Threat Intelligence =============================
    %{
      id: :threat_intel,
      category: :system,
      parent_group: :sys_security,
      subgroup: "Threat Intelligence",
      title: "Threat Intel",
      description: "Manage threat-intelligence feeds and enrichment.",
      icon: "hero-shield-exclamation",
      route: "/settings/networks/threat-intel",
      live_view: ServiceRadarWebNGWeb.Settings.ThreatIntelLive.Index,
      permission: "plugins.assign",
      order: 280,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "threat",
        "intel",
        "ioc",
        "feeds",
        "indicators",
        "otx",
        "alienvault",
        "retrohunt",
        "netflow",
        "matches",
        "plugin",
        "sync",
        "api key"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :vulnerability_feeds,
      category: :system,
      parent_group: :sys_security,
      subgroup: "Threat Intelligence",
      title: "Vulnerability Feeds",
      description: "Configure CVE, CPE, and vulnerability feed sources.",
      icon: "hero-bug-ant",
      route: "/settings/security/vulnerability-feeds",
      live_view: ServiceRadarWebNGWeb.Settings.SecurityLive.VulnerabilityFeeds,
      permission: "settings.integrations.manage",
      order: 290,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "cve",
        "vulnerability",
        "feeds",
        "nvd",
        "cpe",
        "advisory",
        "advisories",
        "intelligence",
        "kev",
        "cisa",
        "vulncheck",
        "known exploited",
        "nist",
        "cadence",
        "credential"
      ],
      badge: nil,
      hidden_from_nav: false
    },

    # === System · Alerts =====================================================
    %{
      id: :rules,
      category: :system,
      parent_group: :sys_alerts,
      subgroup: nil,
      title: "Rules",
      description: "Author alerting and automation rules.",
      icon: "hero-funnel",
      route: "/settings/rules",
      live_view: ServiceRadarWebNGWeb.Settings.RulesLive.Index,
      permission: ["observability.rules.update", "observability.rules.create"],
      order: 320,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "rules",
        "alerting",
        "alerts",
        "zen",
        "jdm",
        "conditions",
        "logs",
        "normalization",
        "events",
        "event rules",
        "alert rules",
        "stateful",
        "threshold",
        "cooldown",
        "renotify",
        "promotion",
        "pipeline"
      ],
      tabs: [
        %{
          id: :logs,
          tab: "logs",
          title: "Log Normalization Rules",
          route: "/settings/rules?tab=logs",
          keywords: ["logs", "normalization", "normalize", "enrich", "zen rules", "syslog"],
          permission: nil
        },
        %{
          id: :events,
          tab: "events",
          title: "Event Rules",
          route: "/settings/rules?tab=events",
          keywords: ["events", "promotion", "promote", "event rules"],
          permission: nil
        },
        %{
          id: :alerts,
          tab: "alerts",
          title: "Alert Rules",
          route: "/settings/rules?tab=alerts",
          keywords: ["alerts", "stateful", "alert rules", "threshold"],
          permission: nil
        }
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :anomaly_detection,
      category: :system,
      parent_group: :sys_alerts,
      subgroup: nil,
      title: "Anomaly Detection",
      description: "Tune anomaly-detection baselines and sensitivity.",
      icon: "hero-bell-alert",
      route: "/settings/anomaly-detection",
      live_view: ServiceRadarWebNGWeb.Settings.AnomalyDetectionLive,
      permission: "observability.alerts.manage",
      order: 330,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "anomaly",
        "detection",
        "baseline",
        "seasonal",
        "alerts",
        "capacity",
        "forecast",
        "sigma",
        "threshold",
        "cooldown",
        "denylist",
        "drift",
        "cusum",
        "metric classes",
        "window"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    # ONE entry for the whole notification surface. Channels, Routes and
    # Escalation, Silences, Providers, and Delivery Log are nested paths under
    # `/settings/notifications`, not separate views: `view_for_path/1` resolves
    # them here by longest-prefix match, so the shell highlights one view and no
    # second view can claim the prefix.
    %{
      id: :notifications,
      category: :system,
      parent_group: :sys_alerts,
      subgroup: nil,
      title: "Notifications",
      description:
        "Configure notification channels, routing and escalation, silences, providers, and the delivery audit.",
      icon: "hero-megaphone",
      route: "/settings/notifications",
      live_view: ServiceRadarWebNGWeb.Settings.NotificationsLive.Index,
      permission: [
        "notifications.channels.view",
        "notifications.routes.view",
        "notifications.deliveries.view"
      ],
      order: 340,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "notifications",
        "channels",
        "slack",
        "discord",
        "webhook",
        "pagerduty",
        "escalation",
        "silence",
        "delivery log",
        "suppressed",
        "why was I not paged",
        "routes",
        "routing",
        "providers",
        "failover",
        "throttle",
        "dedupe",
        "rate limit",
        "test send",
        "email",
        "mute",
        "snooze",
        "matchers",
        "on-call",
        "alert routing"
      ],
      # The tab is a path segment (`/settings/notifications/<tab>`), not `?tab=`.
      tabs: [
        %{
          id: :channels,
          tab: "channels",
          title: "Channels",
          route: "/settings/notifications/channels",
          keywords: ["channels", "email", "slack", "webhook", "test send"],
          permission: "notifications.channels.view"
        },
        %{
          id: :routes,
          tab: "routes",
          title: "Routes and Escalation",
          route: "/settings/notifications/routes",
          keywords: ["routes", "routing", "escalation", "on-call", "policy"],
          permission: "notifications.routes.view"
        },
        %{
          id: :silences,
          tab: "silences",
          title: "Silences",
          route: "/settings/notifications/silences",
          keywords: ["silences", "silence", "mute", "maintenance"],
          permission: "notifications.routes.view"
        },
        %{
          id: :providers,
          tab: "providers",
          title: "Providers",
          route: "/settings/notifications/providers",
          keywords: ["providers", "provider", "upload", "definition"],
          permission: "notifications.channels.view"
        },
        %{
          id: :deliveries,
          tab: "deliveries",
          title: "Delivery Log",
          route: "/settings/notifications/deliveries",
          keywords: ["delivery log", "deliveries", "suppressed", "failed", "audit"],
          permission: "notifications.deliveries.view"
        }
      ],
      badge: nil,
      hidden_from_nav: false
    },

    # === System · Dashboards =================================================
    %{
      id: :dashboard_packages,
      category: :system,
      parent_group: :sys_dashboards,
      subgroup: nil,
      title: "Dashboard Packages",
      description: "Install and manage packaged dashboards shipped as signed bundles.",
      icon: "hero-squares-2x2",
      route: "/settings/dashboards/packages",
      live_view: ServiceRadarWebNGWeb.Admin.DashboardPackageLive.Index,
      permission: "plugins.view",
      order: 410,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "dashboards",
        "packages",
        "wasm",
        "renderer",
        "import",
        "github",
        "manifest",
        "upload",
        "bundle",
        "dashboard route",
        "placement"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :field_survey,
      category: :system,
      parent_group: :sys_dashboards,
      subgroup: nil,
      title: "FieldSurvey",
      description: "Choose the FieldSurvey heatmaps the dashboard card rotates through.",
      icon: "hero-wifi",
      route: "/settings/networks/field-survey",
      live_view: ServiceRadarWebNGWeb.Settings.FieldSurveyLive.Index,
      permission: "settings.networks.manage",
      order: 420,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "field survey",
        "wifi",
        "wi-fi",
        "rf",
        "spectrum",
        "site survey",
        "dashboard",
        "playlist",
        "heatmap",
        "floorplan",
        "dwell",
        "overlay"
      ],
      badge: nil,
      hidden_from_nav: false
    },

    # === System · Personal ===================================================
    %{
      id: :profile,
      category: :system,
      parent_group: :sys_personal,
      subgroup: nil,
      title: "Profile",
      description: "Manage your account, password, and preferences.",
      icon: "hero-user-circle",
      route: "/settings/profile",
      live_view: ServiceRadarWebNGWeb.UserLive.Settings,
      permission: nil,
      order: 510,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "profile",
        "account",
        "password",
        "me",
        "preferences",
        "email",
        "timezone",
        "homepage",
        "change password"
      ],
      badge: nil,
      hidden_from_nav: true
    },

    # === Network Services · Discovery · Profiles =============================
    %{
      id: :sweep_profiles,
      category: :network_services,
      parent_group: :net_discovery,
      subgroup: "Profiles",
      title: "Sweep Profiles",
      description: "Configure network discovery sweeps and scanner profiles.",
      icon: "hero-map",
      route: "/settings/networks",
      live_view: ServiceRadarWebNGWeb.Settings.NetworksLive.Index,
      permission: "settings.networks.manage",
      order: 10,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "sweep",
        "sweeps",
        "networks",
        "cidr",
        "scan",
        "profiles",
        "groups",
        "interval",
        "partition",
        "srql",
        "static targets",
        "ping",
        "icmp",
        "banner grab",
        "fingerprint",
        "rate limit"
      ],
      tabs: [
        %{
          id: :groups,
          tab: "groups",
          title: "Sweep Groups",
          route: "/settings/networks?tab=groups",
          keywords: ["sweep", "groups", "schedules", "targets"],
          permission: nil
        },
        %{
          id: :profiles,
          tab: "profiles",
          title: "Scanner Profiles",
          route: "/settings/networks?tab=profiles",
          keywords: ["scanner", "profiles", "ports", "icmp", "tcp"],
          permission: nil
        },
        %{
          id: :active_scans,
          tab: "active_scans",
          title: "Active Scans",
          route: "/settings/networks?tab=active_scans",
          keywords: ["active", "scans", "running", "executions", "mtr"],
          permission: nil
        }
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :visibility_profiles,
      category: :network_services,
      parent_group: :net_discovery,
      subgroup: "Profiles",
      title: "Visibility Profiles",
      description: "Scope passive fingerprinting and DPI per device.",
      icon: "hero-eye",
      route: "/settings/networks/visibility-profiles",
      live_view: ServiceRadarWebNGWeb.Settings.VisibilityProfilesLive.Index,
      permission: "visibility_profiles:read",
      order: 20,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "visibility",
        "profiles",
        "fingerprint",
        "dpi",
        "netprobe",
        "capture",
        "scope",
        "partition",
        "retention",
        "sample interval",
        "passive",
        "interfaces",
        "deep packet inspection",
        "tls",
        "dns",
        "quic",
        "flow attribution",
        "process snapshots",
        "srql"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :snmp_profiles,
      category: :network_services,
      parent_group: :net_discovery,
      subgroup: "Profiles",
      title: "SNMP Profiles",
      description: "Configure SNMP polling profiles, credentials, and OID templates.",
      icon: "hero-adjustments-horizontal",
      route: "/settings/snmp",
      live_view: ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index,
      permission: "settings.snmp_profiles.manage",
      order: 30,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "snmp",
        "oid",
        "community",
        "v3",
        "polling",
        "oid templates",
        "custom template",
        "credentials",
        "security level",
        "auth protocol",
        "privacy",
        "interfaces",
        "interface targeting",
        "default profile",
        "interval",
        "timeout",
        "retries",
        "test connection",
        "walk",
        "srql"
      ],
      badge: nil,
      hidden_from_nav: false
    },

    # === Network Services · Discovery (leaves) ===============================
    %{
      id: :discovery_jobs,
      category: :network_services,
      parent_group: :net_discovery,
      subgroup: nil,
      title: "Discovery Jobs",
      description: "View active discovery jobs, mapper runs, and trigger frequencies.",
      icon: "hero-magnifying-glass-circle",
      route: "/settings/networks/discovery",
      live_view: ServiceRadarWebNGWeb.Settings.NetworksLive.Index,
      permission: "settings.networks.manage",
      order: 40,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "discovery",
        "mapper",
        "jobs",
        "scan",
        "topology",
        "interfaces",
        "seeds",
        "unifi",
        "mikrotik",
        "routeros",
        "controller",
        "snmp",
        "interval",
        "run now"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :device_enrichment,
      category: :network_services,
      parent_group: :net_discovery,
      subgroup: nil,
      title: "Device Enrichment",
      description: "Manage asset enrichment criteria and device profile rules.",
      icon: "hero-sparkles",
      route: "/settings/networks/device-enrichment",
      live_view: ServiceRadarWebNGWeb.Settings.DeviceEnrichmentRulesLive,
      permission: "settings.networks.manage",
      order: 50,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "enrichment",
        "device",
        "rules",
        "metadata",
        "yaml",
        "import",
        "export",
        "rule files",
        "classification",
        "vendor",
        "model",
        "device type",
        "sys_descr",
        "sysobjectid",
        "simulation",
        "confidence",
        "built-in"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :device_hostname_rdns,
      category: :network_services,
      parent_group: :net_discovery,
      subgroup: nil,
      title: "Device Hostnames",
      description: "SRQL-scoped reverse-DNS lookups that fill device hostnames.",
      icon: "hero-globe-alt",
      route: "/settings/networks/hostname-rdns",
      live_view: ServiceRadarWebNGWeb.Settings.DeviceHostnameRdnsLive,
      permission: "settings.networks.manage",
      order: 55,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "hostname",
        "rdns",
        "ptr",
        "dns",
        "reverse",
        "devices",
        "cron",
        "schedule",
        "cohort",
        "srql",
        "batch",
        "timeout",
        "lookup",
        "overwrite",
        "run now"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :availability_sources,
      category: :network_services,
      parent_group: :net_discovery,
      subgroup: nil,
      title: "Availability Sources",
      description: "Choose which sources decide device availability and uptime.",
      icon: "hero-signal",
      route: "/settings/networks/availability-sources",
      live_view: ServiceRadarWebNGWeb.Settings.AvailabilitySourceProfilesLive,
      permission: "settings.networks.manage",
      order: 60,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "availability",
        "source",
        "uptime",
        "reachability",
        "merged availability",
        "rollout",
        "cutover",
        "shadow",
        "legacy",
        "readiness",
        "backfill",
        "canonical agent",
        "override",
        "offline",
        "unknown",
        "srql"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :composite_checks,
      category: :network_services,
      parent_group: :net_discovery,
      subgroup: nil,
      title: "Composite Checks",
      description: "Derive isolation verdicts from what several agents can reach.",
      icon: "hero-shield-check",
      route: "/settings/networks/composite-checks",
      live_view: ServiceRadarWebNGWeb.Settings.CompositeChecksLive.Index,
      permission: "composite_checks.view",
      order: 61,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "composite",
        "isolation",
        "verdict",
        "segmentation",
        "vantage",
        "isolated",
        "liveness",
        "readiness",
        "preview",
        "verdict rules",
        "decision table",
        "expectations",
        "device facts",
        "sweep coverage",
        "availability",
        "srql",
        "witness"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :inventory_cleanup,
      category: :network_services,
      parent_group: :net_discovery,
      subgroup: nil,
      title: "Inventory Cleanup",
      description:
        "Expire ephemeral devices, retire source ids their source stopped reporting, " <>
          "purge deleted devices, and set the mass-guard overrides.",
      icon: "hero-trash",
      route: "/settings/networks/inventory-cleanup",
      live_view: ServiceRadarWebNGWeb.Settings.InventoryCleanupLive,
      permission: "settings.networks.manage",
      order: 62,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "inventory",
        "cleanup",
        "device cleanup",
        "purge",
        "retention",
        "stale devices",
        "source retirement",
        "retired",
        "grace",
        "awx",
        "armis",
        "ephemeral",
        "expiry",
        "expire",
        "mass guard",
        "override",
        "soft-deleted",
        "succession",
        "batch size"
      ],
      badge: nil,
      hidden_from_nav: false
    },

    # === Network Services · Services =========================================
    %{
      id: :network_flows,
      category: :network_services,
      parent_group: :net_services,
      subgroup: nil,
      title: "Network Flows",
      description: "Configure NetFlow directionality and enrichment rules.",
      icon: "hero-arrows-right-left",
      route: "/settings/flows",
      live_view: ServiceRadarWebNGWeb.Settings.NetflowLive.Index,
      permission: "settings.netflow.manage",
      order: 110,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "netflow",
        "flows",
        "sflow",
        "ipfix",
        "app rules",
        "directionality",
        "local cidr",
        "cidr",
        "geoip",
        "mmdb",
        "ipinfo",
        "asn",
        "country",
        "enrichment",
        "port scan",
        "classification",
        "application",
        "map anchor",
        "location"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :bmp,
      category: :network_services,
      parent_group: :net_services,
      subgroup: nil,
      title: "BGP / BMP",
      description: "Tune BMP ingestion, routing retention, and the routing causal overlay.",
      icon: "hero-globe-alt",
      route: "/settings/networks/bmp",
      live_view: ServiceRadarWebNGWeb.Settings.BmpLive.Index,
      permission: "settings.networks.manage",
      order: 120,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "bmp",
        "bgp",
        "routing",
        "retention",
        "ingestion",
        "causal",
        "overlay",
        "ocsf",
        "severity",
        "threshold"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :mtr,
      category: :network_services,
      parent_group: :net_services,
      subgroup: nil,
      title: "MTR",
      description: "Configure MTR traceroute diagnostic profiles.",
      icon: "hero-arrow-trending-up",
      route: "/settings/networks/mtr",
      live_view: ServiceRadarWebNGWeb.Settings.MtrProfilesLive.Index,
      permission: "settings.networks.manage",
      order: 140,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "mtr",
        "traceroute",
        "latency",
        "path",
        "hops",
        "automation",
        "profiles",
        "retention",
        "history",
        "baseline",
        "canary",
        "incident",
        "cooldown",
        "consensus",
        "bulk",
        "icmp",
        "udp",
        "tcp",
        "srql"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :integrations,
      category: :network_services,
      parent_group: :net_services,
      subgroup: nil,
      title: "Integrations",
      description: "Connect external asset and inventory integration sources.",
      icon: "hero-link",
      route: "/settings/networks/integrations",
      live_view: ServiceRadarWebNGWeb.Settings.IntegrationsLive.Index,
      permission: "settings.integrations.manage",
      order: 150,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "integrations",
        "armis",
        "netbox",
        "sources",
        "sync",
        "ipam",
        "crm",
        "syslog",
        "northbound",
        "aql",
        "blacklist",
        "reconciliation",
        "export",
        "csv",
        "oauth",
        "custom field",
        "mapbox"
      ],
      tabs: [
        %{
          id: :crm_ipam,
          tab: "crm_ipam",
          title: "CRM/IPAM Sources",
          route: "/settings/networks/integrations?tab=crm_ipam",
          keywords: ["crm", "ipam", "sources", "armis", "netbox"],
          permission: nil
        },
        %{
          id: :mapbox,
          tab: "mapbox",
          title: "Mapbox",
          route: "/settings/networks/integrations?tab=mapbox",
          keywords: ["mapbox", "map", "token", "map style", "tiles"],
          permission: nil
        }
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :prefix_tags,
      category: :network_services,
      parent_group: :net_services,
      subgroup: nil,
      title: "Prefix Tags",
      description: "Manual IP/CIDR prefix tags for flow enrichment (NetBox/TI/DNS-policy read-only).",
      icon: "hero-tag",
      route: "/settings/networks/prefix-tags",
      live_view: ServiceRadarWebNGWeb.Settings.PrefixTagsLive,
      permission: "settings.prefix_tags.manage",
      order: 155,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "prefix",
        "tags",
        "cidr",
        "ipam",
        "netbox",
        "enrichment",
        "lpm",
        "vrf",
        "site",
        "tenant",
        "role",
        "trie",
        "ipv4",
        "ipv6",
        "dns policy",
        "threat intel"
      ],
      badge: nil,
      hidden_from_nav: false
    },

    # === Edge Ops · Agents ===================================================
    %{
      id: :agent_releases,
      category: :edge_ops,
      parent_group: :edge_agents,
      subgroup: nil,
      title: "Agent Releases",
      description: "Publish signed agent releases and orchestrate fleet rollouts from the existing control plane.",
      icon: "hero-rocket-launch",
      route: "/settings/agents/releases",
      live_view: ServiceRadarWebNGWeb.Settings.AgentsLive.Releases,
      permission: "settings.edge.manage",
      order: 10,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "agents",
        "releases",
        "versions",
        "rollout",
        "fleet",
        "github",
        "import",
        "publish",
        "manifest",
        "signature",
        "artifact",
        "sha256",
        "cohort",
        "batch",
        "compatibility",
        "pause",
        "cancel",
        "retry",
        "upgrade",
        "update"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :agent_deploy,
      category: :edge_ops,
      parent_group: :edge_agents,
      subgroup: nil,
      title: "Agent Deploy",
      description: "Deploy and roll out agents to your fleet.",
      icon: "hero-cloud-arrow-up",
      route: "/settings/agents/deploy",
      live_view: ServiceRadarWebNGWeb.Settings.AgentsLive.Deploy,
      permission: "settings.edge.manage",
      order: 20,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "deploy",
        "edge",
        "packages",
        "provisioning",
        "install",
        "enroll",
        "onboarding",
        "token",
        "gateway",
        "srctl"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :edge_onboarding,
      category: :edge_ops,
      parent_group: :edge_agents,
      subgroup: nil,
      title: "Edge Onboarding",
      description: "Issue, track and revoke the onboarding packages agents enroll with.",
      icon: "hero-ticket",
      route: "/admin/edge-packages",
      live_view: ServiceRadarWebNGWeb.Admin.EdgePackageLive.Index,
      permission: "settings.edge.manage",
      order: 25,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "edge onboarding",
        "onboarding",
        "packages",
        "edge packages",
        "enroll",
        "token",
        "revoke",
        "certificate",
        "partition",
        "feature set",
        "security mode",
        "docker",
        "systemd"
      ],
      badge: nil,
      hidden_from_nav: false
    },

    # === Edge Ops · Add-ons ==================================================
    %{
      id: :addons,
      category: :edge_ops,
      parent_group: :edge_addons,
      subgroup: nil,
      title: "Add-ons Catalog",
      description: "Select native agent add-ons (feature sets) and push them down to your agents.",
      icon: "hero-squares-plus",
      route: "/settings/agents/addons",
      live_view: ServiceRadarWebNGWeb.Admin.AddonPackageLive.Index,
      permission: "plugins.view",
      order: 110,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: ["/settings/agents/addons", "/admin/addons"],
      keywords: [
        "addons",
        "add-ons",
        "extensions",
        "packages",
        "catalog",
        "first-party",
        "release",
        "sync",
        "import",
        "approve",
        "approval",
        "deny",
        "provenance",
        "assignment",
        "profile",
        "pin",
        "auto-update",
        "canary",
        "soak",
        "batch",
        "failure tolerance",
        "health timeout",
        "override"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :addon_fleet,
      category: :edge_ops,
      parent_group: :edge_addons,
      subgroup: nil,
      title: "Add-on Fleet",
      description: "Watch add-on health across agents and pause, retry, roll back or cancel rollouts.",
      icon: "hero-server",
      route: "/settings/agents/addons/fleet",
      live_view: ServiceRadarWebNGWeb.Admin.AddonFleetLive.Index,
      permission: "plugins.view",
      order: 120,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "addon",
        "fleet",
        "rollout",
        "assignments",
        "canary",
        "health",
        "inventory",
        "rollback",
        "roll back",
        "pause",
        "retry",
        "needs attention",
        "unhealthy",
        "wave",
        "verification"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :plugins,
      category: :edge_ops,
      parent_group: :edge_addons,
      subgroup: nil,
      title: "Plugins Manager",
      description: "Install or update core engine plugins.",
      icon: "hero-puzzle-piece",
      route: "/settings/agents/plugins",
      live_view: ServiceRadarWebNGWeb.Plugins.InstalledLive,
      permission: "plugins.view",
      order: 130,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      # Also the package detail pages (`/settings/agents/plugins/:id`).
      match_prefixes: ["/settings/agents/plugins", "/admin/plugins"],
      keywords: [
        "plugins",
        "packages",
        "extensions",
        "installed",
        "wasm",
        "assignments",
        "orphaned",
        "health",
        "update policy"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :plugin_updates,
      category: :edge_ops,
      parent_group: :edge_addons,
      subgroup: nil,
      title: "Plugin Updates",
      description: "Review staged plugin packages before they reach agents.",
      icon: "hero-arrow-up-circle",
      route: "/settings/agents/plugins/updates",
      live_view: ServiceRadarWebNGWeb.Plugins.UpdatesLive,
      permission: "plugins.view",
      order: 131,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: ["/settings/agents/plugins/updates", "/admin/plugins/updates"],
      keywords: [
        "plugins",
        "updates",
        "review",
        "staged",
        "approve",
        "imported",
        "packages",
        "denied",
        "revoked",
        "github",
        "upload",
        "first-party",
        "wasm"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :plugin_catalog,
      category: :edge_ops,
      parent_group: :edge_addons,
      subgroup: nil,
      title: "Plugin Catalog",
      description: "Browse plugin repositories and import plugins.",
      icon: "hero-building-storefront",
      route: "/settings/agents/plugins/catalog",
      live_view: ServiceRadarWebNGWeb.Plugins.CatalogLive,
      permission: "plugins.view",
      order: 132,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: [
        "/settings/agents/plugins/catalog",
        "/admin/plugins/catalog",
        "/settings/agents/plugins/new",
        "/admin/plugins/new"
      ],
      keywords: [
        "plugins",
        "catalog",
        "repositories",
        "import",
        "releases",
        "sync",
        "upload",
        "stage",
        "new plugin",
        "egress",
        "proxy",
        "capacity",
        "verification",
        "gpg",
        "signing",
        "unsigned",
        "token",
        "manifest",
        "github"
      ],
      badge: nil,
      hidden_from_nav: false
    },

    # === Edge Ops · Fleet Health =============================================
    %{
      id: :host_health,
      category: :edge_ops,
      parent_group: :edge_fleet,
      subgroup: nil,
      title: "Host Health",
      description: "Choose which CPU, memory, disk, network and process metrics hosts collect.",
      icon: "hero-cpu-chip",
      route: "/settings/sysmon",
      live_view: ServiceRadarWebNGWeb.Settings.SysmonProfilesLive.Index,
      permission: "settings.sysmon_profiles.manage",
      order: 210,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "sysmon",
        "host",
        "cpu",
        "memory",
        "disk",
        "health",
        "profiles",
        "interval",
        "sample",
        "network",
        "processes",
        "mount",
        "exclude",
        "srql",
        "system monitor"
      ],
      badge: nil,
      hidden_from_nav: false
    },

    # === Edge Ops · Sites & Collectors =======================================
    %{
      id: :edge_sites,
      category: :edge_ops,
      parent_group: :edge_sites,
      subgroup: nil,
      title: "Edge Sites",
      description: "Create edge sites and their NATS leaf deployments.",
      icon: "hero-building-office-2",
      route: "/admin/edge-sites",
      live_view: ServiceRadarWebNGWeb.Admin.EdgeSitesLive.Index,
      permission: "settings.edge.manage",
      order: 310,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: ["edge", "sites", "locations", "regions", "nats", "leaf", "bundle", "slug", "offline"],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :data_collectors,
      category: :edge_ops,
      parent_group: :edge_sites,
      subgroup: nil,
      title: "Data Collectors",
      description: "Provision lightweight edge endpoint collectors.",
      icon: "hero-inbox-arrow-down",
      route: "/admin/collectors",
      live_view: ServiceRadarWebNGWeb.Admin.CollectorLive.Index,
      permission: "plugins.view",
      order: 320,
      has_own_stats: false,
      feature_flag: nil,
      capability: :collectors_enabled,
      match_prefixes: nil,
      keywords: [
        "collectors",
        "nats",
        "data",
        "ingest",
        "syslog",
        "flowgger",
        "snmp trap",
        "netflow",
        "opentelemetry",
        "otel",
        "falco",
        "falcosidekick",
        "credentials",
        "revoke",
        "bundle",
        "download",
        "package"
      ],
      badge: nil,
      hidden_from_nav: false
    },
    %{
      id: :telemetry_onboarding,
      category: :edge_ops,
      parent_group: :edge_sites,
      subgroup: nil,
      title: "Telemetry Onboarding",
      description: "Send your first telemetry: OTLP endpoints, keys, and snippets.",
      icon: "hero-arrow-up-on-square-stack",
      route: "/settings/agents/telemetry-onboarding",
      live_view: ServiceRadarWebNGWeb.Settings.TelemetryOnboardingLive,
      permission: "settings.edge.manage",
      order: 330,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "telemetry",
        "otlp",
        "onboarding",
        "ingest",
        "exporter",
        "opentelemetry",
        "otel",
        "ingestion key",
        "api key",
        "secret",
        "grpc",
        "http",
        "helm",
        "kubernetes",
        "endpoint",
        "traces",
        "logs",
        "metrics",
        "snippet",
        "sdk",
        "first data"
      ],
      badge: nil,
      hidden_from_nav: false
    },

    # === Edge Ops · Automation ===============================================
    %{
      id: :ansible,
      category: :edge_ops,
      parent_group: :edge_automation,
      subgroup: nil,
      title: "Ansible",
      description: "Manage Ansible controllers and repositories.",
      icon: "hero-command-line",
      route: "/settings/ansible",
      live_view: ServiceRadarWebNGWeb.Settings.AnsibleLive,
      permission: ["ansible.controllers.manage", "ansible.repositories.manage"],
      order: 410,
      has_own_stats: false,
      feature_flag: nil,
      capability: nil,
      match_prefixes: nil,
      keywords: [
        "ansible",
        "automation",
        "playbook",
        "controllers",
        "repositories",
        "sync",
        "token",
        "credential",
        "callback",
        "execution",
        "interval",
        "inventory sync",
        "rotation",
        "deploy token",
        "git",
        "branch"
      ],
      tabs: [
        %{
          id: :controllers,
          tab: "controllers",
          title: "Controllers",
          route: "/settings/ansible?tab=controllers",
          keywords: ["ansible", "controllers", "awx", "aap"],
          permission: "ansible.controllers.manage"
        },
        %{
          id: :repositories,
          tab: "repositories",
          title: "Repositories",
          route: "/settings/ansible?tab=repositories",
          keywords: ["ansible", "repositories", "playbooks", "git", "scm"],
          permission: "ansible.repositories.manage"
        }
      ],
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
    %{id: :settings, title: "Settings", icon: "hero-cog-6-tooth", route: "/settings/cluster"}
  ]

  # ---------------------------------------------------------------------------
  # Raw literal accessors
  # ---------------------------------------------------------------------------

  @doc "All categories, unsorted (declaration order)."
  @spec categories() :: [category()]
  def categories, do: @categories

  @doc "All parent-groups, unsorted (declaration order)."
  @spec parent_groups() :: [parent_group()]
  def parent_groups, do: @parent_groups

  @doc "All views, unsorted (declaration order)."
  @spec views() :: [view()]
  def views, do: @views

  @doc "The icon-rail roots (home / apps / stack / settings)."
  @spec rail_groups() :: [map()]
  def rail_groups, do: @rail_groups

  @doc "Look up a category by id."
  @spec category(atom()) :: category() | nil
  def category(id) when is_atom(id), do: Enum.find(@categories, &(&1.id == id))

  @doc "Look up a parent-group by id."
  @spec parent_group(atom()) :: parent_group() | nil
  def parent_group(id) when is_atom(id), do: Enum.find(@parent_groups, &(&1.id == id))

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

  @doc "The permission key or OR-list that gates a view id (`nil` when ungated)."
  @spec permission(atom()) :: String.t() | [String.t()] | nil
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

  @doc "All parent-groups belonging to a category, sorted by `:order`."
  @spec parent_groups_for_category(atom()) :: [parent_group()]
  def parent_groups_for_category(category_id) when is_atom(category_id) do
    @parent_groups
    |> Enum.filter(&(&1.category == category_id))
    |> Enum.sort_by(& &1.order)
  end

  @doc "The parent-group that owns a view."
  @spec parent_group_for_view(view() | nil) :: parent_group() | nil
  def parent_group_for_view(%{parent_group: id}), do: parent_group(id)
  def parent_group_for_view(_), do: nil

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
  def breadcrumbs_for_path(path), do: breadcrumbs_for_path(path, nil)

  @doc "Scope-aware breadcrumb trail whose category crumb lands on a visible view."
  @spec breadcrumbs_for_path(String.t() | nil, term()) :: [
          %{label: String.t(), route: String.t() | nil}
        ]
  def breadcrumbs_for_path(path, scope) do
    root = %{label: "Settings", route: settings_landing_route()}

    case view_for_path(path) do
      nil ->
        [root]

      view ->
        category = category_for_view(view)

        [
          root,
          %{label: category_title(category), route: category_landing_route(scope, category)},
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

  @doc "The first category view visible to `scope`, with the global route as fallback."
  @spec category_landing_route(term(), atom() | map()) :: String.t()
  def category_landing_route(nil, category), do: category_landing_route(category)
  def category_landing_route(scope, %{id: id}), do: category_landing_route(scope, id)

  def category_landing_route(scope, category_id) when is_atom(category_id) do
    case visible_views(scope, category_id) do
      [%{route: route} | _] -> route
      _ -> category_landing_route(category_id)
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
    |> Enum.map(fn view -> Map.put(view, :visible_tabs, visible_tabs(scope, view)) end)
  end

  @doc """
  In-page tabs under `view` that are visible to `scope`.

  Respects the parent view's visibility (RBAC + feature flag + capability) and
  each tab's own optional `:permission`.
  """
  @spec visible_tabs(term(), view()) :: [tab()]
  def visible_tabs(scope, view) do
    if visible_view?(scope, view) do
      view
      |> Map.get(:tabs, [])
      |> Enum.filter(fn tab -> permitted?(scope, Map.get(tab, :permission)) end)
    else
      []
    end
  end

  @doc """
  The 2-level nav tree for a category, scoped to `scope`.

  Returns a list of `%{group: parent_group, sections: [...]}`, one per
  parent-group that has at least one visible view, sorted by parent-group order.
  Each section is `%{subgroup: String.t() | nil, views: [view]}` — a contiguous
  run of views sharing a `:subgroup` label (or `nil` for ungrouped leaves), so
  the shell can render *Users & Access* / *Credentials* / *Profiles* sub-headers
  without a third collapsible level.
  """
  @spec nav_tree(term(), atom()) :: [%{group: parent_group(), sections: [map()]}]
  def nav_tree(scope, category_id) when is_atom(category_id) do
    visible = visible_views(scope, category_id)
    by_group = Enum.group_by(visible, & &1.parent_group)

    category_id
    |> parent_groups_for_category()
    |> Enum.flat_map(fn group ->
      case Map.get(by_group, group.id, []) do
        [] -> []
        views -> [%{group: group, sections: sections(views)}]
      end
    end)
  end

  @doc """
  The visible sibling views of `view` — the views in the same parent-group,
  scoped to `scope`, sorted by order. Powers the breadcrumb "Navigate Views"
  dropdown.
  """
  @spec siblings(term(), view() | nil) :: [view()]
  def siblings(_scope, nil), do: []

  def siblings(scope, %{category: category_id, parent_group: group_id}) do
    scope
    |> visible_views(category_id)
    |> Enum.filter(&(&1.parent_group == group_id))
  end

  # Split an ordered view list into contiguous `:subgroup` runs.
  defp sections(views) do
    views
    |> Enum.sort_by(& &1.order)
    |> Enum.chunk_by(& &1.subgroup)
    |> Enum.map(fn [%{subgroup: subgroup} | _] = chunk -> %{subgroup: subgroup, views: chunk} end)
  end

  @doc """
  Flattened palette index for the Ctrl+K command palette, over the views visible
  to `scope` (including nav-hidden but deep-linkable views) and their visible
  in-page tabs, sorted by category then view order.

  Each entry: `%{id, category_title, view_title, description, route, icon,
  keywords}`. A tab entry follows its parent view, additionally carries
  `parent_view_id` and `tab_id`, titles itself `"<View> › <Tab>"`, routes to the
  tab's deep link, and merges the view's and tab's keywords.
  """
  @spec palette_index(term()) :: [map()]
  def palette_index(scope) do
    @views
    |> Enum.filter(fn view -> visible_view?(scope, view) end)
    |> Enum.sort_by(fn view -> {category_order(view.category), view.order} end)
    |> Enum.flat_map(fn view ->
      category_title = category_title(category(view.category))

      view_entry = %{
        id: view.id,
        category_title: category_title,
        view_title: view.title,
        description: Map.get(view, :description),
        route: view.route,
        icon: view.icon,
        keywords: view.keywords
      }

      tab_entries =
        scope
        |> visible_tabs(view)
        |> Enum.map(fn tab ->
          %{
            id: :"#{view.id}_#{tab.id}",
            parent_view_id: view.id,
            tab_id: tab.id,
            category_title: category_title,
            view_title: "#{view.title} › #{tab.title}",
            description: Map.get(tab, :description) || Map.get(view, :description),
            route: tab.route,
            icon: view.icon,
            keywords: Enum.uniq(view.keywords ++ tab.keywords)
          }
        end)

      [view_entry | tab_entries]
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

  defp permitted?(scope, permissions) when is_list(permissions) do
    permissions != [] and Enum.any?(permissions, &RBAC.can?(scope, &1))
  end

  # feature_flag: nil means "always on". Known flags map to FeatureFlags.
  defp feature_enabled?(nil), do: true
  defp feature_enabled?(:remote_access_ssh), do: FeatureFlags.remote_access_ssh_enabled?()
  defp feature_enabled?(:remote_access_desktop_rdp), do: FeatureFlags.remote_access_desktop_rdp_enabled?()
  defp feature_enabled?(:remote_access_app), do: FeatureFlags.remote_access_app_enabled?()
  defp feature_enabled?(:remote_access_tcp), do: FeatureFlags.remote_access_tcp_enabled?()
  defp feature_enabled?(:god_view), do: FeatureFlags.god_view_enabled?()
  defp feature_enabled?(:mcp), do: FeatureFlags.mcp_enabled?()
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
