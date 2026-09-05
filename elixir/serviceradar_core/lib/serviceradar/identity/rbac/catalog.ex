defmodule ServiceRadar.Identity.RBAC.Catalog do
  @moduledoc """
  Canonical RBAC permission catalog.

  Permissions are grouped by section and action-level keys.
  """

  alias ServiceRadar.Identity.Constants

  @all_roles Constants.all_roles()
  @operator_roles Constants.operator_roles()
  @helpdesk_roles Constants.helpdesk_roles()
  @admin_roles Constants.admin_roles()

  @raw_catalog [
    %{
      section: "analytics",
      label: "Analytics",
      permissions: [
        %{
          key: "analytics.view",
          section: "analytics",
          resource: "analytics",
          action: "view",
          label: "View analytics",
          description: "View analytics dashboards and queries",
          default_roles: @all_roles
        },
        %{
          key: "analytics.manage_queries",
          section: "analytics",
          resource: "analytics",
          action: "manage_queries",
          label: "Manage analytics queries",
          description: "Create and manage saved analytics queries",
          default_roles: @operator_roles
        },
        %{
          key: "analytics.dashboards.create",
          section: "dashboards",
          resource: "dashboards.authored",
          action: "create",
          label: "Create dashboards",
          description: "Create authored SRQL dashboards",
          default_roles: @operator_roles
        },
        %{
          key: "analytics.dashboards.edit",
          section: "dashboards",
          resource: "dashboards.authored",
          action: "edit",
          label: "Edit dashboards",
          description: "Edit authored dashboard definitions and panels",
          default_roles: @operator_roles
        },
        %{
          key: "analytics.dashboards.delete",
          section: "dashboards",
          resource: "dashboards.authored",
          action: "delete",
          label: "Delete dashboards",
          description: "Archive or delete authored dashboards",
          default_roles: @operator_roles
        },
        %{
          key: "analytics.dashboards.share",
          section: "dashboards",
          resource: "dashboards.authored",
          action: "share",
          label: "Share dashboards",
          description: "Grant authored dashboard access to users and groups",
          default_roles: @operator_roles
        },
        %{
          key: "analytics.dashboards.view_all",
          section: "dashboards",
          resource: "dashboards.authored",
          action: "view_all",
          label: "View all dashboards",
          description: "View authored dashboards regardless of owner or sharing grants",
          default_roles: @admin_roles
        },
        %{
          key: "analytics.reports.schedule",
          section: "analytics",
          resource: "analytics.reports",
          action: "schedule",
          label: "Schedule dashboard reports",
          description: "Create and manage scheduled email reports for authored dashboards",
          default_roles: @operator_roles
        },
        %{
          key: "analytics.share_principals.view",
          section: "analytics",
          resource: "analytics.share_principals",
          action: "view",
          label: "View dashboard share principals",
          description: "Browse users and groups when sharing dashboards",
          default_roles: @operator_roles
        }
      ]
    },
    %{
      section: "identity_groups",
      label: "User Groups",
      permissions: [
        %{
          key: "identity.user_groups.view",
          section: "identity_groups",
          resource: "identity.user_groups",
          action: "view",
          label: "View user groups",
          description: "View reusable user groups and memberships",
          default_roles: @operator_roles
        },
        %{
          key: "identity.user_groups.manage",
          section: "identity_groups",
          resource: "identity.user_groups",
          action: "manage",
          label: "Manage user groups",
          description: "Create and manage reusable user groups and memberships",
          default_roles: @admin_roles
        }
      ]
    },
    %{
      section: "devices",
      label: "Devices",
      permissions: [
        %{
          key: "devices.view",
          section: "devices",
          resource: "devices",
          action: "view",
          label: "View devices",
          description: "View device inventory and details",
          default_roles: @all_roles
        },
        %{
          key: "devices.create",
          section: "devices",
          resource: "devices",
          action: "create",
          label: "Create devices",
          description: "Create devices and inventory records",
          default_roles: @operator_roles
        },
        %{
          key: "devices.update",
          section: "devices",
          resource: "devices",
          action: "update",
          label: "Update devices",
          description: "Edit device properties and metadata",
          default_roles: @operator_roles
        },
        %{
          key: "devices.bulk_edit",
          section: "devices",
          resource: "devices",
          action: "bulk_edit",
          label: "Bulk edit devices",
          description: "Apply tags and bulk edits to devices",
          default_roles: @operator_roles
        },
        %{
          key: "devices.delete",
          section: "devices",
          resource: "devices",
          action: "delete",
          label: "Delete devices",
          description: "Delete devices and inventory records",
          default_roles: @operator_roles
        },
        %{
          key: "devices.bulk_delete",
          section: "devices",
          resource: "devices",
          action: "bulk_delete",
          label: "Bulk delete devices",
          description: "Bulk delete device inventory records",
          default_roles: @operator_roles
        },
        %{
          key: "devices.facts.write",
          section: "devices",
          resource: "devices.facts",
          action: "write",
          label: "Write device facts",
          description:
            "Set bounded scalar facts on device metadata via the API, used by external " <>
              "validation tools. Does not grant any other device edit.",
          default_roles: @operator_roles
        },
        %{
          key: "identity.resolve",
          section: "devices",
          resource: "devices.identity",
          action: "resolve",
          label: "Resolve a device identity from an address",
          description:
            "Look up the device uid at an IP and partition, without probing it. Separate " <>
              "from validation_runs.execute so a caller that needs an id does not need " <>
              "the right to start scans. Reveals less than viewing the inventory does.",
          default_roles: @all_roles
        },
        %{
          key: "devices.import",
          section: "devices",
          resource: "devices",
          action: "import",
          label: "Import devices",
          description: "Import devices via CSV",
          default_roles: @operator_roles
        },
        %{
          key: "devices.export",
          section: "devices",
          resource: "devices",
          action: "export",
          label: "Export devices",
          description: "Export device inventory",
          default_roles: @all_roles
        },
        %{
          key: "devices.console.open",
          section: "devices",
          resource: "devices.console",
          action: "open",
          label: "Open device consoles",
          description: "Open browser terminal sessions to supported managed devices",
          default_roles: @admin_roles
        },
        %{
          key: "devices.console.credentials.use",
          section: "devices",
          resource: "devices.console.credentials",
          action: "use",
          label: "Use device console credentials",
          description:
            "Use scoped broker-managed credentials while opening supported device consoles",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.ssh.open",
          section: "devices",
          resource: "devices.remote_access.ssh",
          action: "open",
          label: "Open SSH remote access",
          description:
            "Open SSH remote-access sessions and request short-lived SSH user certificates",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.ssh.target.override",
          section: "devices",
          resource: "devices.remote_access.ssh.target",
          action: "override",
          label: "Override SSH remote-access targets",
          description:
            "Open SSH remote-access sessions with explicit upstream host or port overrides",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.ssh.ca_bundle.read",
          section: "devices",
          resource: "devices.remote_access.ssh.ca_bundle",
          action: "read",
          label: "Distribute SSH remote-access CA policy",
          description:
            "Authorize target-scoped SSH CA bundle and principal policy retrieval by reviewed automation callbacks",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.rdp.open",
          section: "devices",
          resource: "devices.remote_access.rdp",
          action: "open",
          label: "Open RDP remote access",
          description:
            "Open graphical RDP remote-access sessions through approved desktop targets",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.app.open",
          section: "devices",
          resource: "devices.remote_access.app",
          action: "open",
          label: "Open application remote access",
          description: "Open policy-registered HTTP and HTTPS application access sessions",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.tcp.open",
          section: "devices",
          resource: "devices.remote_access.tcp",
          action: "open",
          label: "Open TCP remote access",
          description: "Open policy-registered raw TCP access sessions",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.requests.review",
          section: "devices",
          resource: "devices.remote_access.requests",
          action: "review",
          label: "Review remote-access requests",
          description: "Approve and deny approval-gated remote-access requests",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.recordings.export",
          section: "devices",
          resource: "devices.remote_access.recordings",
          action: "export",
          label: "Export remote-access recordings",
          description: "Export remote-access replay manifests and transcript events",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.recordings.view_all",
          section: "devices",
          resource: "devices.remote_access.recordings",
          action: "view_all",
          label: "View all remote-access recordings",
          description: "View remote-access recordings for sessions owned by other users",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.recordings.delete",
          section: "devices",
          resource: "devices.remote_access.recordings",
          action: "delete",
          label: "Delete remote-access recordings",
          description: "Delete remote-access recording manifests and replay events",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.files.list",
          section: "devices",
          resource: "devices.remote_access.files",
          action: "list",
          label: "List remote files",
          description: "List directories and read metadata through remote-access file transfer",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.files.download",
          section: "devices",
          resource: "devices.remote_access.files",
          action: "download",
          label: "Download remote files",
          description: "Download files through policy-gated remote-access file transfer",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.files.upload",
          section: "devices",
          resource: "devices.remote_access.files",
          action: "upload",
          label: "Upload remote files",
          description: "Upload files through policy-gated remote-access file transfer",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.files.manage",
          section: "devices",
          resource: "devices.remote_access.files",
          action: "manage",
          label: "Manage remote files",
          description: "Create, rename, remove, chmod, and chown remote files when policy allows",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.files.approve",
          section: "devices",
          resource: "devices.remote_access.files",
          action: "approve",
          label: "Approve remote file transfers",
          description: "Approve sensitive remote-access file-transfer requests",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.files.export",
          section: "devices",
          resource: "devices.remote_access.files",
          action: "export",
          label: "Export retained remote file artifacts",
          description:
            "Export file-transfer content-audit artifacts when retention is explicitly enabled",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.file_transfers.delete",
          section: "devices",
          resource: "devices.remote_access.file_transfers",
          action: "delete",
          label: "Delete remote file-transfer records",
          description: "Delete remote-access file-transfer metadata records",
          default_roles: @admin_roles
        },
        %{
          key: "endpoint_inventory.force_fresh_scan",
          section: "devices",
          resource: "endpoint_inventory",
          action: "force_fresh_scan",
          label: "Force fresh endpoint inventory scans",
          description:
            "Trigger device-scoped fresh endpoint software inventory scans through the agent command bus",
          default_roles: @admin_roles
        }
      ]
    },
    %{
      section: "composite_checks",
      label: "Composite Checks",
      permissions: [
        %{
          key: "composite_checks.view",
          section: "composite_checks",
          resource: "composite_checks",
          action: "view",
          label: "View composite checks",
          description: "View composite check definitions and per-device verdicts",
          default_roles: @all_roles
        },
        %{
          key: "composite_checks.manage",
          section: "composite_checks",
          resource: "composite_checks",
          action: "manage",
          label: "Manage composite checks",
          description: "Create, edit, enable, and delete composite checks",
          default_roles: @operator_roles
        },
        %{
          key: "composite_checks.evaluate",
          section: "composite_checks",
          resource: "composite_checks",
          action: "evaluate",
          label: "Run composite check previews",
          description:
            "Run an on-demand composite check evaluation without persisting results or events",
          default_roles: @operator_roles
        }
      ]
    },
    %{
      section: "validation_runs",
      label: "Validation Runs",
      permissions: [
        %{
          key: "validation_runs.execute",
          section: "validation_runs",
          resource: "validation_runs",
          action: "execute",
          label: "Start composite-check validation runs",
          description:
            "Create a validation run that resolves IP+partition to a device and re-probes vantage points",
          default_roles: @operator_roles
        },
        %{
          key: "validation_runs.read",
          section: "validation_runs",
          resource: "validation_runs",
          action: "read",
          label: "View validation runs",
          description: "Read validation run status and composite-check verdicts",
          default_roles: @all_roles
        }
      ]
    },
    %{
      section: "services",
      label: "Services",
      permissions: [
        %{
          key: "services.view",
          section: "services",
          resource: "services",
          action: "view",
          label: "View services",
          description: "View service checks and status",
          default_roles: @all_roles
        },
        %{
          key: "services.create",
          section: "services",
          resource: "services",
          action: "create",
          label: "Create services",
          description: "Create service checks",
          default_roles: @operator_roles
        },
        %{
          key: "services.update",
          section: "services",
          resource: "services",
          action: "update",
          label: "Update services",
          description: "Update service checks",
          default_roles: @operator_roles
        },
        %{
          key: "services.delete",
          section: "services",
          resource: "services",
          action: "delete",
          label: "Delete services",
          description: "Delete service checks",
          default_roles: @operator_roles
        },
        %{
          key: "services.run",
          section: "services",
          resource: "services",
          action: "run",
          label: "Run services",
          description: "Trigger service checks and runs",
          default_roles: @operator_roles
        }
      ]
    },
    %{
      section: "observability",
      label: "Observability",
      permissions: [
        %{
          key: "observability.logs.view",
          section: "observability",
          resource: "observability.logs",
          action: "view",
          label: "View logs",
          description: "View logs and log detail pages",
          default_roles: @all_roles
        },
        %{
          key: "observability.metrics.view",
          section: "observability",
          resource: "observability.metrics",
          action: "view",
          label: "View metrics",
          description: "View metrics and metric detail pages",
          default_roles: @all_roles
        },
        %{
          key: "observability.traces.view",
          section: "observability",
          resource: "observability.traces",
          action: "view",
          label: "View traces",
          description: "View traces and trace detail pages",
          default_roles: @all_roles
        },
        %{
          key: "observability.events.view",
          section: "observability",
          resource: "observability.events",
          action: "view",
          label: "View events",
          description: "View events and event detail pages",
          default_roles: @all_roles
        },
        %{
          key: "observability.netflow.view",
          section: "observability",
          resource: "observability.netflow",
          action: "view",
          label: "View netflow",
          description: "View netflow and flow detail pages",
          default_roles: @all_roles
        },
        %{
          key: "observability.alerts.view",
          section: "observability",
          resource: "observability.alerts",
          action: "view",
          label: "View alerts",
          description: "View alerts and alert detail pages",
          default_roles: @all_roles
        },
        %{
          key: "observability.rules.view",
          section: "observability",
          resource: "observability.rules",
          action: "view",
          label: "View rules",
          description: "View observability rule definitions",
          default_roles: @all_roles
        },
        %{
          key: "observability.rules.create",
          section: "observability",
          resource: "observability.rules",
          action: "create",
          label: "Create rules",
          description: "Create observability rules",
          default_roles: @operator_roles
        },
        %{
          key: "observability.rules.update",
          section: "observability",
          resource: "observability.rules",
          action: "update",
          label: "Update rules",
          description: "Update observability rules",
          default_roles: @operator_roles
        },
        %{
          key: "observability.rules.delete",
          section: "observability",
          resource: "observability.rules",
          action: "delete",
          label: "Delete rules",
          description: "Delete observability rules",
          default_roles: @operator_roles
        },
        %{
          key: "observability.alerts.manage",
          section: "observability",
          resource: "observability.alerts",
          action: "manage",
          label: "Manage alerts",
          description: "Acknowledge and resolve alerts",
          default_roles: @helpdesk_roles
        }
      ]
    },
    %{
      section: "settings",
      label: "Settings",
      permissions: [
        %{
          key: "settings.view",
          section: "settings",
          resource: "settings",
          action: "view",
          label: "View settings",
          description: "View settings pages",
          default_roles: @operator_roles
        },
        %{
          key: "settings.auth.manage",
          section: "settings",
          resource: "settings.auth",
          action: "manage",
          label: "Manage users and auth",
          description: "Manage users, roles, and auth settings",
          default_roles: @admin_roles
        },
        %{
          key: "settings.password.manage",
          section: "settings",
          resource: "settings.password",
          action: "manage",
          label: "Change own password",
          description: "Change the signed-in user's password from profile settings",
          default_roles: @all_roles
        },
        %{
          key: "settings.api_credentials.manage",
          section: "settings",
          resource: "settings.api_credentials",
          action: "manage",
          label: "Manage API credentials",
          description: "Create and revoke personal OAuth API clients from Settings",
          default_roles: @all_roles
        },
        %{
          key: "settings.mcp.manage",
          section: "settings",
          resource: "settings.mcp",
          action: "manage",
          label: "Use MCP",
          description: "Authorize native MCP clients, call the MCP server, and revoke MCP grants",
          default_roles: @all_roles
        },
        %{
          key: "settings.rbac.manage",
          section: "settings",
          resource: "settings.rbac",
          action: "manage",
          label: "Manage RBAC policies",
          description: "Manage role profiles and permissions",
          default_roles: @admin_roles
        },
        %{
          key: "settings.networks.manage",
          section: "settings",
          resource: "settings.networks",
          action: "manage",
          label: "Manage networks",
          description: "Manage sweep groups and discovery",
          default_roles: @operator_roles
        },
        %{
          key: "settings.netflow.manage",
          section: "settings",
          resource: "settings.netflow",
          action: "manage",
          label: "Manage NetFlow settings",
          description: "Manage NetFlow enrichment and directionality settings",
          default_roles: @operator_roles
        },
        %{
          key: "settings.prefix_tags.manage",
          section: "settings",
          resource: "settings.prefix_tags",
          action: "manage",
          label: "Manage prefix tags",
          description:
            "Manage manual IP/CIDR prefix tags, import configuration, and snapshot " <>
              "operations used for flow enrichment",
          default_roles: @operator_roles
        },
        %{
          key: "settings.integrations.manage",
          section: "settings",
          resource: "settings.integrations",
          action: "manage",
          label: "Manage integrations",
          description: "Manage integration sources and sync configuration",
          default_roles: @operator_roles
        },
        %{
          key: "settings.mail.manage",
          section: "settings",
          resource: "settings.mail",
          action: "manage",
          label: "Manage outbound mail",
          description: "Configure deployment-level outbound mail providers and credentials",
          default_roles: @admin_roles
        },
        %{
          key: "settings.credentials.manage",
          section: "settings",
          resource: "settings.credentials",
          action: "manage",
          label: "Manage network credentials",
          description: "Manage encrypted credentials and edge-scoped credential rules",
          default_roles: @admin_roles
        },
        %{
          key: "settings.remote_access_host_keys.manage",
          section: "settings",
          resource: "settings.remote_access_host_keys",
          action: "manage",
          label: "Manage remote-access host keys",
          description: "Review, trust, rotate, and revoke SSH host keys for remote access",
          default_roles: @admin_roles
        },
        %{
          key: "settings.remote_access_targets.manage",
          section: "settings",
          resource: "settings.remote_access_targets",
          action: "manage",
          label: "Manage remote-access targets",
          description: "Create and manage registered application and TCP remote-access targets",
          default_roles: @admin_roles
        },
        %{
          key: "settings.snmp_profiles.manage",
          section: "settings",
          resource: "settings.snmp_profiles",
          action: "manage",
          label: "Manage SNMP profiles",
          description: "Manage SNMP profiles",
          default_roles: @operator_roles
        },
        %{
          key: "settings.sysmon_profiles.manage",
          section: "settings",
          resource: "settings.sysmon_profiles",
          action: "manage",
          label: "Manage Sysmon profiles",
          description: "Manage Sysmon profiles",
          default_roles: @operator_roles
        },
        %{
          key: "visibility_profiles:read",
          section: "settings",
          resource: "visibility_profiles",
          action: "read",
          label: "Read visibility profiles",
          description: "View host network visibility profiles and assignments",
          default_roles: @all_roles
        },
        %{
          key: "visibility_profiles:write",
          section: "settings",
          resource: "visibility_profiles",
          action: "write",
          label: "Manage visibility profiles",
          description: "Create and update host network visibility profiles",
          default_roles: @operator_roles
        },
        %{
          key: "visibility_profiles:delete",
          section: "settings",
          resource: "visibility_profiles",
          action: "delete",
          label: "Delete visibility profiles",
          description: "Delete host network visibility profiles",
          default_roles: @admin_roles
        },
        %{
          key: "settings.jobs.manage",
          section: "settings",
          resource: "settings.jobs",
          action: "manage",
          label: "Manage jobs",
          description: "Trigger or manage background jobs",
          default_roles: @admin_roles
        },
        %{
          key: "settings.plugins.manage",
          section: "settings",
          resource: "settings.plugins",
          action: "manage",
          label: "Manage plugins",
          description: "Manage plugin packages and assignments",
          default_roles: @admin_roles
        },
        %{
          key: "settings.edge.manage",
          section: "settings",
          resource: "settings.edge",
          action: "manage",
          label: "Manage edge packages",
          description: "Manage edge onboarding packages and endpoint inventory settings",
          default_roles: @admin_roles
        },
        %{
          key: "settings.audit.view",
          section: "settings",
          resource: "settings.audit",
          action: "view",
          label: "View audit & security events",
          description:
            "Open Settings → Audit and view AshPaperTrail version history, the " <>
              "SecurityEvent stream (rate-limit denials, signature failures, " <>
              "policy denials, CSP violations, lockouts), and current rate-limit " <>
              "pressure.",
          default_roles: @operator_roles
        },
        %{
          key: "settings.audit.manage",
          section: "settings",
          resource: "settings.audit",
          action: "manage",
          label: "Manage audit & security state",
          description:
            "Clear an AuthLockout, rotate a WebhookSecret, and perform other " <>
              "mutating actions on Settings → Audit.",
          default_roles: @admin_roles
        }
      ]
    },
    %{
      section: "plugins",
      label: "Plugins",
      permissions: [
        %{
          key: "plugins.view",
          section: "plugins",
          resource: "plugins",
          action: "view",
          label: "View plugins",
          description: "View plugins and plugin packages",
          default_roles: @operator_roles
        },
        %{
          key: "plugins.stage",
          section: "plugins",
          resource: "plugins",
          action: "stage",
          label: "Stage plugin packages",
          description: "Stage (upload/import) plugin packages for review",
          default_roles: @admin_roles
        },
        %{
          key: "plugins.approve",
          section: "plugins",
          resource: "plugins",
          action: "approve",
          label: "Approve plugin packages",
          description: "Approve/deny/revoke plugin packages",
          default_roles: @admin_roles
        },
        %{
          key: "plugins.assign",
          section: "plugins",
          resource: "plugins",
          action: "assign",
          label: "Assign plugins",
          description: "Assign plugins to agents and resources",
          default_roles: @admin_roles
        },
        %{
          key: "plugins.repositories.manage",
          section: "plugins",
          resource: "plugins.repositories",
          action: "manage",
          label: "Manage plugin repositories",
          description:
            "Add, edit, enable, disable and remove the catalog sources plugins " <>
              "are imported from. Deliberately separate from plugins.stage: " <>
              "staging imports from a trusted source, this decides which " <>
              "sources are trusted.",
          default_roles: @admin_roles
        }
      ]
    },
    %{
      section: "ansible",
      label: "Ansible",
      permissions: [
        %{
          key: "ansible.controllers.manage",
          section: "ansible",
          resource: "ansible.controllers",
          action: "manage",
          label: "Manage AWX controllers",
          description:
            "Register, edit, and remove AWX/AAP controllers and the credential broker " <>
              "entries that ServiceRadar uses to authenticate to them.",
          default_roles: @admin_roles
        },
        %{
          key: "ansible.repositories.manage",
          section: "ansible",
          resource: "ansible.repositories",
          action: "manage",
          label: "Manage playbook repositories",
          description:
            "Register and configure git repositories used as Ansible playbook catalog sources.",
          default_roles: @admin_roles
        },
        %{
          key: "ansible.catalog.view",
          section: "ansible",
          resource: "ansible.catalog",
          action: "view",
          label: "View playbook catalog",
          description: "Browse the Ansible playbook catalog (git-sourced and AWX-sourced).",
          default_roles: @all_roles
        },
        %{
          key: "ansible.runs.view",
          section: "ansible",
          resource: "ansible.runs",
          action: "view",
          label: "View Ansible operations",
          description:
            "View canonical Ansible operation history, per-target evidence, and dispatch outcomes.",
          default_roles: @all_roles
        },
        %{
          key: "ansible.runs.launch",
          section: "ansible",
          resource: "ansible.runs",
          action: "launch",
          label: "Launch Ansible playbooks",
          description:
            "Launch a reviewed Ansible playbook as a canonical operation against one or more Ansible-managed devices.",
          default_roles: @operator_roles
        },
        %{
          key: "ansible.runs.cancel",
          section: "ansible",
          resource: "ansible.runs",
          action: "cancel",
          label: "Cancel Ansible operations",
          description: "Authorize cancellation of an in-progress Ansible operation.",
          default_roles: @operator_roles
        },
        %{
          key: "ansible.schedules.view",
          section: "ansible",
          resource: "ansible.schedules",
          action: "view",
          label: "Reserved Ansible schedule access",
          description:
            "Reserved permission key for stored schedule records; no schedule UI or execution authority is exposed.",
          default_roles: @all_roles
        },
        %{
          key: "ansible.schedules.manage",
          section: "ansible",
          resource: "ansible.schedules",
          action: "manage",
          label: "Reserved Ansible schedule management",
          description:
            "Reserved permission key for stored schedule records; it does not enable or authorize scheduled execution.",
          default_roles: @operator_roles
        },
        %{
          key: "ansible.delegations.manage",
          section: "ansible",
          resource: "ansible.delegations",
          action: "manage",
          label: "Manage Ansible execution delegations",
          description:
            "Bind an owned, fixed-ceiling service principal to an Ansible schedule or operation.",
          default_roles: @admin_roles
        },
        %{
          key: "ansible.targets.holds.clear",
          section: "ansible",
          resource: "ansible.targets.holds",
          action: "clear",
          label: "Clear Ansible target holds",
          description:
            "Reconcile and clear a device-wide Ansible mutation hold using current approval, policy, and recovery evidence.",
          default_roles: @admin_roles
        }
      ]
    },
    %{
      section: "northbound",
      label: "Northbound Actions",
      permissions: [
        %{
          key: "northbound.actions.view",
          section: "northbound",
          resource: "northbound.actions",
          action: "view",
          label: "View northbound actions",
          description: "View configured action providers, descriptors, invocations, and history.",
          default_roles: @all_roles
        },
        %{
          key: "northbound.actions.manage",
          section: "northbound",
          resource: "northbound.actions",
          action: "manage",
          label: "Manage northbound action providers",
          description:
            "Register, approve, disable, and update provider-neutral northbound action providers and descriptors.",
          default_roles: @admin_roles
        },
        %{
          key: "northbound.actions.launch",
          section: "northbound",
          resource: "northbound.actions",
          action: "launch",
          label: "Launch northbound actions",
          description:
            "Launch approved provider-neutral actions against selected devices or interfaces.",
          default_roles: @operator_roles
        },
        %{
          key: "northbound.actions.cancel",
          section: "northbound",
          resource: "northbound.actions",
          action: "cancel",
          label: "Cancel northbound actions",
          description: "Cancel in-progress provider-neutral action invocations.",
          default_roles: @operator_roles
        },
        %{
          key: "northbound.event_handlers.manage",
          section: "northbound",
          resource: "northbound.event_handlers",
          action: "manage",
          label: "Manage northbound event handlers",
          description:
            "Create, approve, enable, disable, and tune event handlers that invoke northbound actions.",
          default_roles: @admin_roles
        }
      ]
    },
    %{
      section: "networks",
      label: "Network Ops",
      permissions: [
        %{
          key: "networks.sweeps.view",
          section: "networks",
          resource: "networks.sweeps",
          action: "view",
          label: "View sweep diagnostics",
          description:
            "View sweep group configuration, execution history, and per-host sweep results",
          default_roles: @all_roles
        },
        %{
          key: "networks.sweeps.run",
          section: "networks",
          resource: "networks.sweeps",
          action: "run",
          label: "Run sweeps now",
          description: "Trigger on-demand network sweeps",
          default_roles: @operator_roles
        },
        %{
          key: "networks.sweeps.banner_grab",
          section: "networks",
          resource: "networks.sweeps",
          action: "banner_grab",
          label: "Enable banner grab",
          description: "Enable active banner-grab probes in network sweep profiles",
          default_roles: @operator_roles
        },
        %{
          key: "networks.discovery.run",
          section: "networks",
          resource: "networks.discovery",
          action: "run",
          label: "Run discovery now",
          description: "Trigger on-demand discovery jobs",
          default_roles: @operator_roles
        }
      ]
    },
    %{
      section: "scans",
      label: "Ad-hoc Scans",
      permissions: [
        %{
          key: "scans.execute",
          section: "scans",
          resource: "scans",
          action: "execute",
          label: "Run ad-hoc scans",
          description:
            "Start ad-hoc ICMP/TCP/MTR scans against a target list from a chosen agent",
          default_roles: @operator_roles
        },
        %{
          key: "scans.read",
          section: "scans",
          resource: "scans",
          action: "read",
          label: "View scans",
          description: "View ad-hoc scan runs and their results",
          default_roles: @all_roles
        },
        %{
          key: "scans.export",
          section: "scans",
          resource: "scans",
          action: "export",
          label: "Export scan results",
          description: "Export ad-hoc scan results to CSV or XLSX",
          default_roles: @all_roles
        },
        %{
          key: "scans.manage",
          section: "scans",
          resource: "scans",
          action: "manage",
          label: "Manage scan policy",
          description: "Toggle the inventory-scoping guardrail for ad-hoc scans",
          default_roles: @admin_roles
        }
      ]
    },
    %{
      section: "cli",
      label: "CLI Sessions",
      permissions: [
        %{
          key: "cli.session.create",
          section: "cli",
          resource: "cli.session",
          action: "create",
          label: "Approve CLI device authorizations",
          description:
            "Approve a pending serviceradar-cli device-code request, " <>
              "issuing a long-lived bearer token bound to your account.",
          default_roles: @operator_roles
        },
        %{
          key: "cli.session.read_own",
          section: "cli",
          resource: "cli.session",
          action: "read_own",
          label: "View own CLI sessions",
          description:
            "List your own active and historical CLI sessions in Settings → CLI sessions.",
          default_roles: @all_roles
        },
        %{
          key: "cli.session.revoke_own",
          section: "cli",
          resource: "cli.session",
          action: "revoke_own",
          label: "Revoke own CLI sessions",
          description: "Revoke a CLI session you previously authorized.",
          default_roles: @all_roles
        },
        %{
          key: "cli.session.read_any",
          section: "cli",
          resource: "cli.session",
          action: "read_any",
          label: "View all CLI sessions",
          description:
            "List every user's CLI sessions in Settings → CLI sessions, " <>
              "with the User column visible.",
          default_roles: @admin_roles
        },
        %{
          key: "cli.session.revoke_any",
          section: "cli",
          resource: "cli.session",
          action: "revoke_any",
          label: "Revoke any CLI session",
          description: "Revoke a CLI session that belongs to another user.",
          default_roles: @admin_roles
        },
        %{
          key: "cli.policy.manage",
          section: "cli",
          resource: "cli.policy",
          action: "manage",
          label: "Manage CLI authentication policy",
          description:
            "Toggle the CLI device-code flow per instance, change the " <>
              "issued-token TTL, and pin the allowed scope list.",
          default_roles: @admin_roles
        }
      ]
    },
    %{
      section: "dashboards",
      label: "Dashboards",
      permissions: [
        %{
          key: "cli.dashboard.publish",
          section: "dashboards",
          resource: "dashboards.packages",
          action: "publish",
          alias_of: "dashboards.packages.publish",
          label: "Publish dashboard packages via API",
          description:
            "Upload a dashboard package (manifest + renderer) through the " <>
              "/api/v1/dashboard-packages endpoint, typically from " <>
              "serviceradar-cli dashboard publish.",
          default_roles: @admin_roles
        },
        %{
          key: "cli.dashboard.enable",
          section: "dashboards",
          resource: "dashboards.packages",
          action: "enable",
          alias_of: "dashboards.packages.enable",
          label: "Enable dashboard packages via API",
          description:
            "Flip a dashboard package live and (re)bind a route slug via " <>
              "/api/v1/dashboard-packages/:id/enable.",
          default_roles: @admin_roles
        },
        %{
          key: "cli.dashboard.disable",
          section: "dashboards",
          resource: "dashboards.packages",
          action: "disable",
          alias_of: "dashboards.packages.disable",
          label: "Disable dashboard packages via API",
          description:
            "Take a dashboard package out of service via " <>
              "/api/v1/dashboard-packages/:id/disable without deleting it.",
          default_roles: @admin_roles
        },
        %{
          key: "dashboards.packages.publish",
          section: "dashboards",
          resource: "dashboards.packages",
          action: "publish",
          label: "Publish dashboard packages",
          description:
            "Upload a dashboard package (manifest + renderer) through the " <>
              "/api/v1/dashboard-packages endpoint.",
          default_roles: @admin_roles
        },
        %{
          key: "dashboards.packages.enable",
          section: "dashboards",
          resource: "dashboards.packages",
          action: "enable",
          label: "Enable dashboard packages",
          description:
            "Flip a dashboard package live and (re)bind a route slug via " <>
              "/api/v1/dashboard-packages/:id/enable.",
          default_roles: @admin_roles
        },
        %{
          key: "dashboards.packages.disable",
          section: "dashboards",
          resource: "dashboards.packages",
          action: "disable",
          label: "Disable dashboard packages",
          description:
            "Take a dashboard package out of service via " <>
              "/api/v1/dashboard-packages/:id/disable without deleting it.",
          default_roles: @admin_roles
        },
        %{
          key: "dashboards.packages.share",
          section: "dashboards",
          resource: "dashboards.packages",
          action: "share",
          label: "Share package dashboards",
          description: "Change package dashboard visibility and manage user and group grants.",
          default_roles: @operator_roles
        },
        %{
          key: "dashboards.packages.view_all",
          section: "dashboards",
          resource: "dashboards.packages",
          action: "view_all",
          label: "View all package dashboards",
          description:
            "View package dashboards regardless of owner, visibility, or sharing grants.",
          default_roles: @admin_roles
        }
      ]
    },
    %{
      section: "notifications",
      label: "Notifications",
      permissions: [
        %{
          key: "notifications.channels.view",
          section: "notifications",
          resource: "notifications.channels",
          action: "view",
          label: "View notification channels",
          description: "View configured notification channels and their health.",
          default_roles: @operator_roles
        },
        %{
          key: "notifications.channels.manage",
          section: "notifications",
          resource: "notifications.channels",
          action: "manage",
          label: "Manage notification channels",
          description:
            "Create, edit, disable, and delete notification channels, " <>
              "including their provider configuration and secret references.",
          default_roles: @admin_roles
        },
        %{
          key: "notifications.routes.view",
          section: "notifications",
          resource: "notifications.routes",
          action: "view",
          label: "View notification routes",
          description: "View notification routing rules and escalation policies.",
          default_roles: @operator_roles
        },
        %{
          key: "notifications.routes.manage",
          section: "notifications",
          resource: "notifications.routes",
          action: "manage",
          label: "Manage notification routes",
          description:
            "Create and edit notification routing rules, escalation policies, " <>
              "escalation steps, and schedules.",
          default_roles: @admin_roles
        },
        %{
          key: "notifications.providers.manage",
          section: "notifications",
          resource: "notifications.providers",
          action: "manage",
          label: "Manage notification providers",
          description:
            "Upload, version, enable, and disable notification provider " <>
              "definitions, including declarative channel definitions.",
          default_roles: @admin_roles
        },
        %{
          key: "notifications.deliveries.view",
          section: "notifications",
          resource: "notifications.deliveries",
          action: "view",
          label: "View notification delivery log",
          description:
            "View notification delivery attempts, including suppressed " <>
              "deliveries and their suppression reason.",
          default_roles: @helpdesk_roles
        },
        %{
          key: "notifications.test.send",
          section: "notifications",
          resource: "notifications.test",
          action: "send",
          label: "Send test notifications",
          description:
            "Send a test notification through a channel using its real " <>
              "configuration and secrets.",
          default_roles: @admin_roles
        },
        %{
          key: "notifications.silences.manage",
          section: "notifications",
          resource: "notifications.silences",
          action: "manage",
          label: "Manage notification silences",
          description:
            "Create, edit, and cancel notification silences and maintenance " <>
              "windows.",
          default_roles: @operator_roles
        },
        %{
          key: "notifications.stream.subscribe",
          section: "notifications",
          resource: "notifications.stream",
          action: "subscribe",
          label: "Subscribe to the notification stream",
          description:
            "Subscribe to the authenticated notification firehose over the " <>
              "stream provider topic.",
          default_roles: @operator_roles
        }
      ]
    }
  ]

  @action_order ~w(view create update delete manage manage_queries bulk_edit bulk_delete import export run)

  @aliases %{
    "cli.dashboard.publish" => "dashboards.packages.publish",
    "cli.dashboard.enable" => "dashboards.packages.enable",
    "cli.dashboard.disable" => "dashboards.packages.disable"
  }

  @resource_labels %{
    "dashboards.authored" => "Authored",
    "dashboards.packages" => "Packages"
  }

  @catalog (
             labels = Map.new(@raw_catalog, &{&1.section, &1.label})

             perms =
               for section <- @raw_catalog, perm <- section.permissions do
                 perm = Map.put_new(perm, :section, section.section)

                 for field <- [:section, :resource, :action, :key] do
                   value = Map.get(perm, field)

                   if !(is_binary(value) and value != "") do
                     raise ArgumentError,
                           "catalog entry #{inspect(Map.get(perm, :key))} omits #{field}"
                   end
                 end

                 perm
               end

             grouped = Enum.group_by(perms, & &1.section)

             for sec <- Enum.map(@raw_catalog, & &1.section),
                 match = Map.get(grouped, sec),
                 match != nil do
               %{section: sec, label: Map.fetch!(labels, sec), permissions: match}
             end
           )

  @system_profiles [
    %{
      system_name: "admin",
      name: "Admin",
      description: "Full access to the platform",
      role: :admin
    },
    %{
      system_name: "operator",
      name: "Operator",
      description: "Create and update resources without destructive deletes",
      role: :operator
    },
    %{
      system_name: "helpdesk",
      name: "Helpdesk",
      description: "Respond to alerts with read-only access to inventory and dashboards",
      role: :helpdesk
    },
    %{system_name: "viewer", name: "Viewer", description: "Read-only access", role: :viewer}
  ]

  def catalog, do: @catalog

  def action_order, do: @action_order

  def aliases, do: @aliases

  def canonical_key(key) when is_binary(key), do: Map.get(@aliases, key, key)

  def equivalent_keys(key) when is_binary(key) do
    canonical = canonical_key(key)

    alias_keys =
      for {alias_key, can} <- @aliases, can == canonical, do: alias_key

    Enum.uniq([canonical | alias_keys])
  end

  def holds?(permissions, key) when is_binary(key) do
    perms =
      cond do
        match?(%MapSet{}, permissions) -> permissions
        is_list(permissions) -> MapSet.new(permissions)
        true -> MapSet.new()
      end

    Enum.any?(equivalent_keys(key), &MapSet.member?(perms, &1))
  end

  def alias_of(key) when is_binary(key), do: Map.get(@aliases, key)

  def grid_permissions do
    @catalog
    |> Enum.flat_map(& &1.permissions)
    |> Enum.reject(&Map.get(&1, :alias_of))
  end

  def resource_label(resource) when is_binary(resource) do
    Map.get_lazy(@resource_labels, resource, fn ->
      resource
      |> String.split(".")
      |> List.last()
      |> String.replace("_", " ")
    end)
  end

  def system_profiles, do: @system_profiles

  def permission_keys do
    @catalog
    |> Enum.flat_map(& &1.permissions)
    |> Enum.map(& &1.key)
  end

  def permissions_for_role(role) when is_atom(role) do
    @catalog
    |> Enum.flat_map(& &1.permissions)
    |> Enum.filter(fn permission -> role in permission.default_roles end)
    |> MapSet.new(& &1.key)
  end

  def permissions_for_role(role) when is_binary(role) do
    role
    |> String.to_existing_atom()
    |> permissions_for_role()
  rescue
    ArgumentError -> MapSet.new()
  end

  def system_profile_for_role(role) when is_atom(role) do
    Enum.find(@system_profiles, fn profile -> profile.role == role end)
  end

  def system_profile_for_role(role) when is_binary(role) do
    role
    |> String.to_existing_atom()
    |> system_profile_for_role()
  rescue
    ArgumentError -> nil
  end
end
