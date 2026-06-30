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

  @catalog [
    %{
      section: "analytics",
      label: "Analytics",
      permissions: [
        %{
          key: "analytics.view",
          label: "View analytics",
          description: "View analytics dashboards and queries",
          default_roles: @all_roles
        },
        %{
          key: "analytics.manage_queries",
          label: "Manage analytics queries",
          description: "Create and manage saved analytics queries",
          default_roles: @operator_roles
        },
        %{
          key: "analytics.dashboards.create",
          label: "Create dashboards",
          description: "Create authored SRQL dashboards",
          default_roles: @operator_roles
        },
        %{
          key: "analytics.dashboards.edit",
          label: "Edit dashboards",
          description: "Edit authored dashboard definitions and panels",
          default_roles: @operator_roles
        },
        %{
          key: "analytics.dashboards.delete",
          label: "Delete dashboards",
          description: "Archive or delete authored dashboards",
          default_roles: @operator_roles
        },
        %{
          key: "analytics.dashboards.share",
          label: "Share dashboards",
          description: "Grant authored dashboard access to users and groups",
          default_roles: @operator_roles
        },
        %{
          key: "analytics.dashboards.view_all",
          label: "View all dashboards",
          description: "View authored dashboards regardless of owner or sharing grants",
          default_roles: @admin_roles
        },
        %{
          key: "analytics.reports.schedule",
          label: "Schedule dashboard reports",
          description: "Create and manage scheduled email reports for authored dashboards",
          default_roles: @operator_roles
        },
        %{
          key: "analytics.share_principals.view",
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
          label: "View user groups",
          description: "View reusable user groups and memberships",
          default_roles: @operator_roles
        },
        %{
          key: "identity.user_groups.manage",
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
          label: "View devices",
          description: "View device inventory and details",
          default_roles: @all_roles
        },
        %{
          key: "devices.create",
          label: "Create devices",
          description: "Create devices and inventory records",
          default_roles: @operator_roles
        },
        %{
          key: "devices.update",
          label: "Update devices",
          description: "Edit device properties and metadata",
          default_roles: @operator_roles
        },
        %{
          key: "devices.bulk_edit",
          label: "Bulk edit devices",
          description: "Apply tags and bulk edits to devices",
          default_roles: @operator_roles
        },
        %{
          key: "devices.delete",
          label: "Delete devices",
          description: "Delete devices and inventory records",
          default_roles: @operator_roles
        },
        %{
          key: "devices.bulk_delete",
          label: "Bulk delete devices",
          description: "Bulk delete device inventory records",
          default_roles: @operator_roles
        },
        %{
          key: "devices.import",
          label: "Import devices",
          description: "Import devices via CSV",
          default_roles: @operator_roles
        },
        %{
          key: "devices.export",
          label: "Export devices",
          description: "Export device inventory",
          default_roles: @all_roles
        },
        %{
          key: "devices.console.open",
          label: "Open device consoles",
          description: "Open browser terminal sessions to supported managed devices",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.ssh.open",
          label: "Open SSH remote access",
          description:
            "Open SSH remote-access sessions and request short-lived SSH user certificates",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.ssh.target.override",
          label: "Override SSH remote-access targets",
          description:
            "Open SSH remote-access sessions with explicit upstream host or port overrides",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.rdp.open",
          label: "Open RDP remote access",
          description:
            "Open graphical RDP remote-access sessions through approved desktop targets",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.app.open",
          label: "Open application remote access",
          description: "Open policy-registered HTTP and HTTPS application access sessions",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.tcp.open",
          label: "Open TCP remote access",
          description: "Open policy-registered raw TCP access sessions",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.requests.review",
          label: "Review remote-access requests",
          description: "Approve and deny approval-gated remote-access requests",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.recordings.export",
          label: "Export remote-access recordings",
          description: "Export remote-access replay manifests and transcript events",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.recordings.view_all",
          label: "View all remote-access recordings",
          description: "View remote-access recordings for sessions owned by other users",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.recordings.delete",
          label: "Delete remote-access recordings",
          description: "Delete remote-access recording manifests and replay events",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.files.list",
          label: "List remote files",
          description: "List directories and read metadata through remote-access file transfer",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.files.download",
          label: "Download remote files",
          description: "Download files through policy-gated remote-access file transfer",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.files.upload",
          label: "Upload remote files",
          description: "Upload files through policy-gated remote-access file transfer",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.files.manage",
          label: "Manage remote files",
          description: "Create, rename, remove, chmod, and chown remote files when policy allows",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.files.approve",
          label: "Approve remote file transfers",
          description: "Approve sensitive remote-access file-transfer requests",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.files.export",
          label: "Export retained remote file artifacts",
          description:
            "Export file-transfer content-audit artifacts when retention is explicitly enabled",
          default_roles: @admin_roles
        },
        %{
          key: "devices.remote_access.file_transfers.delete",
          label: "Delete remote file-transfer records",
          description: "Delete remote-access file-transfer metadata records",
          default_roles: @admin_roles
        },
        %{
          key: "endpoint_inventory.force_fresh_scan",
          label: "Force fresh endpoint inventory scans",
          description:
            "Trigger device-scoped fresh endpoint software inventory scans through the agent command bus",
          default_roles: @admin_roles
        }
      ]
    },
    %{
      section: "services",
      label: "Services",
      permissions: [
        %{
          key: "services.view",
          label: "View services",
          description: "View service checks and status",
          default_roles: @all_roles
        },
        %{
          key: "services.create",
          label: "Create services",
          description: "Create service checks",
          default_roles: @operator_roles
        },
        %{
          key: "services.update",
          label: "Update services",
          description: "Update service checks",
          default_roles: @operator_roles
        },
        %{
          key: "services.delete",
          label: "Delete services",
          description: "Delete service checks",
          default_roles: @operator_roles
        },
        %{
          key: "services.run",
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
          label: "View logs",
          description: "View logs and log detail pages",
          default_roles: @all_roles
        },
        %{
          key: "observability.metrics.view",
          label: "View metrics",
          description: "View metrics and metric detail pages",
          default_roles: @all_roles
        },
        %{
          key: "observability.traces.view",
          label: "View traces",
          description: "View traces and trace detail pages",
          default_roles: @all_roles
        },
        %{
          key: "observability.events.view",
          label: "View events",
          description: "View events and event detail pages",
          default_roles: @all_roles
        },
        %{
          key: "observability.netflow.view",
          label: "View netflow",
          description: "View netflow and flow detail pages",
          default_roles: @all_roles
        },
        %{
          key: "observability.alerts.view",
          label: "View alerts",
          description: "View alerts and alert detail pages",
          default_roles: @all_roles
        },
        %{
          key: "observability.rules.view",
          label: "View rules",
          description: "View observability rule definitions",
          default_roles: @all_roles
        },
        %{
          key: "observability.rules.create",
          label: "Create rules",
          description: "Create observability rules",
          default_roles: @operator_roles
        },
        %{
          key: "observability.rules.update",
          label: "Update rules",
          description: "Update observability rules",
          default_roles: @operator_roles
        },
        %{
          key: "observability.rules.delete",
          label: "Delete rules",
          description: "Delete observability rules",
          default_roles: @operator_roles
        },
        %{
          key: "observability.alerts.manage",
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
          label: "View settings",
          description: "View settings pages",
          default_roles: @operator_roles
        },
        %{
          key: "settings.auth.manage",
          label: "Manage users and auth",
          description: "Manage users, roles, and auth settings",
          default_roles: @admin_roles
        },
        %{
          key: "settings.password.manage",
          label: "Change own password",
          description: "Change the signed-in user's password from profile settings",
          default_roles: @all_roles
        },
        %{
          key: "settings.rbac.manage",
          label: "Manage RBAC policies",
          description: "Manage role profiles and permissions",
          default_roles: @admin_roles
        },
        %{
          key: "settings.networks.manage",
          label: "Manage networks",
          description: "Manage sweep groups and discovery",
          default_roles: @operator_roles
        },
        %{
          key: "settings.netflow.manage",
          label: "Manage NetFlow settings",
          description: "Manage NetFlow enrichment and directionality settings",
          default_roles: @operator_roles
        },
        %{
          key: "settings.integrations.manage",
          label: "Manage integrations",
          description: "Manage integration sources and sync configuration",
          default_roles: @operator_roles
        },
        %{
          key: "settings.mail.manage",
          label: "Manage outbound mail",
          description: "Configure deployment-level outbound mail providers and credentials",
          default_roles: @admin_roles
        },
        %{
          key: "settings.credentials.manage",
          label: "Manage network credentials",
          description: "Manage encrypted credentials and edge-scoped credential rules",
          default_roles: @admin_roles
        },
        %{
          key: "settings.remote_access_host_keys.manage",
          label: "Manage remote-access host keys",
          description: "Review, trust, rotate, and revoke SSH host keys for remote access",
          default_roles: @admin_roles
        },
        %{
          key: "settings.remote_access_targets.manage",
          label: "Manage remote-access targets",
          description: "Create and manage registered application and TCP remote-access targets",
          default_roles: @admin_roles
        },
        %{
          key: "settings.snmp_profiles.manage",
          label: "Manage SNMP profiles",
          description: "Manage SNMP profiles",
          default_roles: @operator_roles
        },
        %{
          key: "settings.sysmon_profiles.manage",
          label: "Manage Sysmon profiles",
          description: "Manage Sysmon profiles",
          default_roles: @operator_roles
        },
        %{
          key: "visibility_profiles:read",
          label: "Read visibility profiles",
          description: "View host network visibility profiles and assignments",
          default_roles: @all_roles
        },
        %{
          key: "visibility_profiles:write",
          label: "Manage visibility profiles",
          description: "Create and update host network visibility profiles",
          default_roles: @operator_roles
        },
        %{
          key: "visibility_profiles:delete",
          label: "Delete visibility profiles",
          description: "Delete host network visibility profiles",
          default_roles: @admin_roles
        },
        %{
          key: "settings.jobs.manage",
          label: "Manage jobs",
          description: "Trigger or manage background jobs",
          default_roles: @admin_roles
        },
        %{
          key: "settings.plugins.manage",
          label: "Manage plugins",
          description: "Manage plugin packages and assignments",
          default_roles: @admin_roles
        },
        %{
          key: "settings.edge.manage",
          label: "Manage edge packages",
          description: "Manage edge onboarding packages and endpoint inventory settings",
          default_roles: @admin_roles
        },
        %{
          key: "settings.audit.view",
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
          label: "View plugins",
          description: "View plugins and plugin packages",
          default_roles: @operator_roles
        },
        %{
          key: "plugins.stage",
          label: "Stage plugin packages",
          description: "Stage (upload/import) plugin packages for review",
          default_roles: @admin_roles
        },
        %{
          key: "plugins.approve",
          label: "Approve plugin packages",
          description: "Approve/deny/revoke plugin packages",
          default_roles: @admin_roles
        },
        %{
          key: "plugins.assign",
          label: "Assign plugins",
          description: "Assign plugins to agents and resources",
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
          label: "Manage AWX controllers",
          description:
            "Register, edit, and remove AWX/AAP controllers and the credential broker " <>
              "entries that ServiceRadar uses to authenticate to them.",
          default_roles: @admin_roles
        },
        %{
          key: "ansible.repositories.manage",
          label: "Manage playbook repositories",
          description:
            "Register and configure git repositories used as Ansible playbook catalog sources.",
          default_roles: @admin_roles
        },
        %{
          key: "ansible.catalog.view",
          label: "View playbook catalog",
          description: "Browse the Ansible playbook catalog (git-sourced and AWX-sourced).",
          default_roles: @all_roles
        },
        %{
          key: "ansible.runs.view",
          label: "View Ansible runs",
          description: "View Ansible playbook runs, per-target results, and run history.",
          default_roles: @all_roles
        },
        %{
          key: "ansible.runs.launch",
          label: "Launch Ansible runs",
          description: "Launch Ansible playbooks against one or more Ansible-managed devices.",
          default_roles: @operator_roles
        },
        %{
          key: "ansible.runs.cancel",
          label: "Cancel Ansible runs",
          description: "Cancel an in-progress Ansible playbook run.",
          default_roles: @operator_roles
        },
        %{
          key: "ansible.schedules.view",
          label: "View Ansible schedules",
          description: "View scheduled / recurring Ansible playbook runs.",
          default_roles: @all_roles
        },
        %{
          key: "ansible.schedules.manage",
          label: "Manage Ansible schedules",
          description:
            "Create, edit, enable, disable, and delete scheduled / recurring Ansible playbook runs.",
          default_roles: @operator_roles
        }
      ]
    },
    %{
      section: "northbound",
      label: "Northbound Actions",
      permissions: [
        %{
          key: "northbound.actions.view",
          label: "View northbound actions",
          description: "View configured action providers, descriptors, invocations, and history.",
          default_roles: @all_roles
        },
        %{
          key: "northbound.actions.manage",
          label: "Manage northbound action providers",
          description:
            "Register, approve, disable, and update provider-neutral northbound action providers and descriptors.",
          default_roles: @admin_roles
        },
        %{
          key: "northbound.actions.launch",
          label: "Launch northbound actions",
          description:
            "Launch approved provider-neutral actions against selected devices or interfaces.",
          default_roles: @operator_roles
        },
        %{
          key: "northbound.actions.cancel",
          label: "Cancel northbound actions",
          description: "Cancel in-progress provider-neutral action invocations.",
          default_roles: @operator_roles
        },
        %{
          key: "northbound.event_handlers.manage",
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
          key: "networks.sweeps.run",
          label: "Run sweeps now",
          description: "Trigger on-demand network sweeps",
          default_roles: @operator_roles
        },
        %{
          key: "networks.sweeps.banner_grab",
          label: "Enable banner grab",
          description: "Enable active banner-grab probes in network sweep profiles",
          default_roles: @operator_roles
        },
        %{
          key: "networks.discovery.run",
          label: "Run discovery now",
          description: "Trigger on-demand discovery jobs",
          default_roles: @operator_roles
        }
      ]
    },
    %{
      section: "cli",
      label: "CLI Sessions",
      permissions: [
        %{
          key: "cli.session.create",
          label: "Approve CLI device authorizations",
          description:
            "Approve a pending serviceradar-cli device-code request, " <>
              "issuing a long-lived bearer token bound to your account.",
          default_roles: @operator_roles
        },
        %{
          key: "cli.session.read_own",
          label: "View own CLI sessions",
          description:
            "List your own active and historical CLI sessions in Settings → CLI sessions.",
          default_roles: @all_roles
        },
        %{
          key: "cli.session.revoke_own",
          label: "Revoke own CLI sessions",
          description: "Revoke a CLI session you previously authorized.",
          default_roles: @all_roles
        },
        %{
          key: "cli.session.read_any",
          label: "View all CLI sessions",
          description:
            "List every user's CLI sessions in Settings → CLI sessions, " <>
              "with the User column visible.",
          default_roles: @admin_roles
        },
        %{
          key: "cli.session.revoke_any",
          label: "Revoke any CLI session",
          description: "Revoke a CLI session that belongs to another user.",
          default_roles: @admin_roles
        },
        %{
          key: "cli.policy.manage",
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
          label: "Publish dashboard packages via API",
          description:
            "Upload a dashboard package (manifest + renderer) through the " <>
              "/api/v1/dashboard-packages endpoint, typically from " <>
              "serviceradar-cli dashboard publish.",
          default_roles: @admin_roles
        },
        %{
          key: "cli.dashboard.enable",
          label: "Enable dashboard packages via API",
          description:
            "Flip a dashboard package live and (re)bind a route slug via " <>
              "/api/v1/dashboard-packages/:id/enable.",
          default_roles: @admin_roles
        },
        %{
          key: "cli.dashboard.disable",
          label: "Disable dashboard packages via API",
          description:
            "Take a dashboard package out of service via " <>
              "/api/v1/dashboard-packages/:id/disable without deleting it.",
          default_roles: @admin_roles
        }
      ]
    }
  ]

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
