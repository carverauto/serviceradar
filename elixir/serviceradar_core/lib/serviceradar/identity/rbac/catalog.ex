defmodule ServiceRadar.Identity.RBAC.Catalog do
  @moduledoc """
  Canonical RBAC permission catalog.

  Permissions are grouped by section and action-level keys.
  """

  @catalog [
    %{
      section: "analytics",
      label: "Analytics",
      permissions: [
        %{
          key: "analytics.view",
          label: "View analytics",
          description: "View analytics dashboards and queries",
          default_roles: [:viewer, :helpdesk, :operator, :admin]
        },
        %{
          key: "analytics.manage_queries",
          label: "Manage analytics queries",
          description: "Create and manage saved analytics queries",
          default_roles: [:operator, :admin]
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
          default_roles: [:viewer, :helpdesk, :operator, :admin]
        },
        %{
          key: "devices.create",
          label: "Create devices",
          description: "Create devices and inventory records",
          default_roles: [:operator, :admin]
        },
        %{
          key: "devices.update",
          label: "Update devices",
          description: "Edit device properties and metadata",
          default_roles: [:operator, :admin]
        },
        %{
          key: "devices.bulk_edit",
          label: "Bulk edit devices",
          description: "Apply tags and bulk edits to devices",
          default_roles: [:operator, :admin]
        },
        %{
          key: "devices.delete",
          label: "Delete devices",
          description: "Delete devices and inventory records",
          default_roles: [:operator, :admin]
        },
        %{
          key: "devices.bulk_delete",
          label: "Bulk delete devices",
          description: "Bulk delete device inventory records",
          default_roles: [:operator, :admin]
        },
        %{
          key: "devices.import",
          label: "Import devices",
          description: "Import devices via CSV",
          default_roles: [:operator, :admin]
        },
        %{
          key: "devices.export",
          label: "Export devices",
          description: "Export device inventory",
          default_roles: [:viewer, :helpdesk, :operator, :admin]
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
          default_roles: [:viewer, :helpdesk, :operator, :admin]
        },
        %{
          key: "services.create",
          label: "Create services",
          description: "Create service checks",
          default_roles: [:operator, :admin]
        },
        %{
          key: "services.update",
          label: "Update services",
          description: "Update service checks",
          default_roles: [:operator, :admin]
        },
        %{
          key: "services.delete",
          label: "Delete services",
          description: "Delete service checks",
          default_roles: [:operator, :admin]
        },
        %{
          key: "services.run",
          label: "Run services",
          description: "Trigger service checks and runs",
          default_roles: [:operator, :admin]
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
          default_roles: [:viewer, :helpdesk, :operator, :admin]
        },
        %{
          key: "observability.metrics.view",
          label: "View metrics",
          description: "View metrics and metric detail pages",
          default_roles: [:viewer, :helpdesk, :operator, :admin]
        },
        %{
          key: "observability.traces.view",
          label: "View traces",
          description: "View traces and trace detail pages",
          default_roles: [:viewer, :helpdesk, :operator, :admin]
        },
        %{
          key: "observability.events.view",
          label: "View events",
          description: "View events and event detail pages",
          default_roles: [:viewer, :helpdesk, :operator, :admin]
        },
        %{
          key: "observability.netflow.view",
          label: "View netflow",
          description: "View netflow and flow detail pages",
          default_roles: [:viewer, :helpdesk, :operator, :admin]
        },
        %{
          key: "observability.alerts.view",
          label: "View alerts",
          description: "View alerts and alert detail pages",
          default_roles: [:viewer, :helpdesk, :operator, :admin]
        },
        %{
          key: "observability.rules.view",
          label: "View rules",
          description: "View observability rule definitions",
          default_roles: [:viewer, :helpdesk, :operator, :admin]
        },
        %{
          key: "observability.rules.create",
          label: "Create rules",
          description: "Create observability rules",
          default_roles: [:operator, :admin]
        },
        %{
          key: "observability.rules.update",
          label: "Update rules",
          description: "Update observability rules",
          default_roles: [:operator, :admin]
        },
        %{
          key: "observability.rules.delete",
          label: "Delete rules",
          description: "Delete observability rules",
          default_roles: [:operator, :admin]
        },
        %{
          key: "observability.alerts.manage",
          label: "Manage alerts",
          description: "Acknowledge and resolve alerts",
          default_roles: [:helpdesk, :operator, :admin]
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
          default_roles: [:operator, :admin]
        },
        %{
          key: "settings.auth.manage",
          label: "Manage users and auth",
          description: "Manage users, roles, and auth settings",
          default_roles: [:admin]
        },
        %{
          key: "settings.rbac.manage",
          label: "Manage RBAC policies",
          description: "Manage role profiles and permissions",
          default_roles: [:admin]
        },
        %{
          key: "settings.networks.manage",
          label: "Manage networks",
          description: "Manage sweep groups and discovery",
          default_roles: [:operator, :admin]
        },
        %{
          key: "settings.integrations.manage",
          label: "Manage integrations",
          description: "Manage integration sources and sync configuration",
          default_roles: [:operator, :admin]
        },
        %{
          key: "settings.snmp_profiles.manage",
          label: "Manage SNMP profiles",
          description: "Manage SNMP profiles",
          default_roles: [:operator, :admin]
        },
        %{
          key: "settings.sysmon_profiles.manage",
          label: "Manage Sysmon profiles",
          description: "Manage Sysmon profiles",
          default_roles: [:operator, :admin]
        },
        %{
          key: "settings.jobs.manage",
          label: "Manage jobs",
          description: "Trigger or manage background jobs",
          default_roles: [:admin]
        },
        %{
          key: "settings.plugins.manage",
          label: "Manage plugins",
          description: "Manage plugin packages and assignments",
          default_roles: [:admin]
        },
        %{
          key: "settings.edge.manage",
          label: "Manage edge packages",
          description: "Manage edge onboarding packages",
          default_roles: [:admin]
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
          default_roles: [:operator, :admin]
        },
        %{
          key: "plugins.stage",
          label: "Stage plugin packages",
          description: "Stage (upload/import) plugin packages for review",
          default_roles: [:admin]
        },
        %{
          key: "plugins.approve",
          label: "Approve plugin packages",
          description: "Approve/deny/revoke plugin packages",
          default_roles: [:admin]
        },
        %{
          key: "plugins.assign",
          label: "Assign plugins",
          description: "Assign plugins to agents and resources",
          default_roles: [:admin]
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
          default_roles: [:operator, :admin]
        },
        %{
          key: "networks.discovery.run",
          label: "Run discovery now",
          description: "Trigger on-demand discovery jobs",
          default_roles: [:operator, :admin]
        }
      ]
    }
  ]

  @system_profiles [
    %{system_name: "admin", name: "Admin", description: "Full access to the platform", role: :admin},
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

  @doc """
  Permission key aliases for retired keys.

  We keep this for forward-compatibility with already-stored role profiles, so
  admins can still edit/sanitize profiles created before the catalog was
  refined.
  """
  def permission_key_aliases do
    %{
      # `observability.view` used to be a coarse, section-wide permission. It was
      # split into per-surface view permissions.
      "observability.view" => [
        "observability.logs.view",
        "observability.metrics.view",
        "observability.traces.view",
        "observability.events.view",
        "observability.netflow.view",
        "observability.alerts.view",
        "observability.rules.view"
      ]
    }
  end

  @doc """
  Normalizes permission keys by expanding deprecated aliases and removing
  duplicates.
  """
  def normalize_permission_keys(keys) when is_list(keys) do
    aliases = permission_key_aliases()

    keys
    |> Enum.flat_map(fn key ->
      case Map.get(aliases, key) do
        nil -> [key]
        expanded when is_list(expanded) -> expanded
      end
    end)
    |> Enum.uniq()
  end

  def permission_keys do
    @catalog
    |> Enum.flat_map(& &1.permissions)
    |> Enum.map(& &1.key)
  end

  def permissions_for_role(role) when is_atom(role) do
    @catalog
    |> Enum.flat_map(& &1.permissions)
    |> Enum.filter(fn permission -> role in permission.default_roles end)
    |> Enum.map(& &1.key)
  end

  def permissions_for_role(role) when is_binary(role) do
    role
    |> String.to_existing_atom()
    |> permissions_for_role()
  rescue
    ArgumentError -> []
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
