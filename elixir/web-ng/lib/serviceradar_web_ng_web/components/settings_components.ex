defmodule ServiceRadarWebNGWeb.SettingsComponents do
  @moduledoc """
  Shared components for the Settings section layout and navigation.
  """

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.FeatureFlags
  alias ServiceRadarWebNGWeb.Settings.Catalog

  attr(:current_path, :string, required: true)
  attr(:class, :any, default: nil)
  slot(:inner_block, required: true)

  def settings_shell(assigns) do
    ~H"""
    <div class={["mx-auto w-full max-w-7xl p-6 space-y-6", @class]}>
      <section class="space-y-6">
        {render_slot(@inner_block)}
      </section>
    </div>
    """
  end

  attr(:current_path, :string, required: true)
  attr(:class, :any, default: nil)
  attr(:current_scope, :map, default: nil)

  def settings_nav(assigns) do
    assigns =
      assign(
        assigns,
        :tabs,
        settings_tabs(assigns.current_path, assigns[:current_scope])
      )

    ~H"""
    <div class={["flex flex-wrap items-center gap-2", @class]}>
      <.ui_tabs tabs={@tabs} class="flex-wrap" />
    </div>
    """
  end

  # Adapter (OpenSpec redesign-settings-catalog-nav, task 1.6): the top-level
  # tab bar is unchanged in appearance, but every tab now sources its route from
  # the single `Settings.Catalog` source of truth (`Catalog.route/1`) instead of
  # a duplicated `~p"..."` literal, so the legacy chrome and the new catalog
  # shell can never disagree on a route. Active-state and multi-permission
  # visibility logic stay legacy here and are removed at the visual cutover.
  def settings_tabs(current_path, current_scope \\ nil) do
    path = current_path || ""

    Enum.filter(
      [
        cluster_tab(path, current_scope),
        discovery_tab(path, current_scope),
        network_tab(path, current_scope),
        mail_tab(path, current_scope),
        security_tab(path, current_scope),
        events_tab(path, current_scope),
        dashboards_tab(path, current_scope),
        edge_ops_tab(path, current_scope),
        ansible_tab(path, current_scope),
        jobs_tab(path, current_scope),
        auth_tab(path, current_scope),
        audit_tab(path, current_scope)
      ],
      &Map.get(&1, :show, true)
    )
  end

  defp audit_tab(path, current_scope) do
    %{
      label: "Audit",
      navigate: Catalog.route(:audit_trail),
      active: String.starts_with?(path, "/settings/audit"),
      show: RBAC.can?(current_scope, "settings.audit.view")
    }
  end

  defp ansible_tab(path, current_scope) do
    %{
      label: "Ansible",
      navigate: Catalog.route(:ansible),
      active: String.starts_with?(path, "/settings/ansible"),
      show: can_ansible_tab?(current_scope)
    }
  end

  defp can_ansible_tab?(current_scope) do
    RBAC.can?(current_scope, "ansible.controllers.manage") or
      RBAC.can?(current_scope, "ansible.repositories.manage")
  end

  defp cluster_tab(path, current_scope) do
    %{
      label: "Cluster",
      navigate: Catalog.route(:cluster_status),
      active:
        String.starts_with?(path, "/settings/cluster") or
          String.starts_with?(path, "/admin/cluster"),
      show: RBAC.can?(current_scope, "settings.view")
    }
  end

  defp network_tab(path, current_scope) do
    %{
      label: "Network",
      navigate: Catalog.route(:network_flows),
      active: network_active?(path),
      show: can_networks_tab?(current_scope)
    }
  end

  defp mail_tab(path, current_scope) do
    %{
      label: "Mail",
      navigate: Catalog.route(:mail),
      active: String.starts_with?(path, "/settings/mail"),
      show: RBAC.can?(current_scope, "settings.mail.manage")
    }
  end

  defp security_tab(path, current_scope) do
    %{
      label: "Security",
      navigate: Catalog.route(:vulnerability_feeds),
      active: String.starts_with?(path, "/settings/security"),
      show: RBAC.can?(current_scope, "settings.integrations.manage")
    }
  end

  defp discovery_tab(path, current_scope) do
    %{
      label: "Discovery",
      navigate: Catalog.route(:sweep_profiles),
      active: discovery_active?(path),
      show: can_discovery_tab?(current_scope)
    }
  end

  defp can_discovery_tab?(current_scope) do
    RBAC.can?(current_scope, "settings.networks.manage") or
      RBAC.can?(current_scope, "visibility_profiles:read") or
      RBAC.can?(current_scope, "settings.snmp_profiles.manage") or
      RBAC.can?(current_scope, "settings.credentials.manage") or
      remote_access_discovery_tab_visible?(current_scope)
  end

  defp can_networks_tab?(current_scope) do
    RBAC.can?(current_scope, "settings.networks.manage") or
      RBAC.can?(current_scope, "settings.netflow.manage") or
      RBAC.can?(current_scope, "settings.integrations.manage") or
      RBAC.can?(current_scope, "settings.snmp_profiles.manage") or
      RBAC.can?(current_scope, "plugins.assign")
  end

  defp can_agents_tab?(current_scope) do
    RBAC.can?(current_scope, "settings.sysmon_profiles.manage") or
      RBAC.can?(current_scope, "settings.edge.manage") or
      RBAC.can?(current_scope, "plugins.view") or
      RBAC.can?(current_scope, "settings.plugins.manage")
  end

  defp events_tab(path, current_scope) do
    %{
      label: "Events",
      navigate: events_tab_href(current_scope),
      active: events_active?(path),
      show: can_events_tab?(current_scope)
    }
  end

  defp can_events_tab?(current_scope) do
    RBAC.can?(current_scope, "observability.rules.update") or
      RBAC.can?(current_scope, "observability.rules.create") or
      RBAC.can?(current_scope, "observability.alerts.manage")
  end

  defp events_tab_href(current_scope) do
    if can_rules_tab?(current_scope),
      do: Catalog.route(:rules),
      else: Catalog.route(:anomaly_detection)
  end

  defp events_active?(path) do
    String.starts_with?(path, "/settings/rules") or
      String.starts_with?(path, "/settings/anomaly-detection")
  end

  defp dashboards_tab(path, current_scope) do
    %{
      label: "Dashboards",
      navigate: Catalog.route(:dashboard_packages),
      active: String.starts_with?(path, "/settings/dashboards"),
      show: RBAC.can?(current_scope, "plugins.view")
    }
  end

  defp edge_ops_tab(path, current_scope) do
    %{
      label: "Edge Ops",
      href: edge_ops_tab_href(current_scope),
      active:
        String.starts_with?(path, "/admin/collectors") or
          String.starts_with?(path, "/admin/edge-sites") or
          String.starts_with?(path, "/admin/nats") or
          String.starts_with?(path, "/settings/sysmon") or
          String.starts_with?(path, "/settings/agents") or
          String.starts_with?(path, "/admin/edge-packages") or
          String.starts_with?(path, "/admin/plugins"),
      show: can_edge_ops_tab?(current_scope)
    }
  end

  defp edge_ops_tab_href(current_scope) do
    cond do
      RBAC.can?(current_scope, "settings.edge.manage") -> Catalog.route(:agent_releases)
      RBAC.can?(current_scope, "settings.sysmon_profiles.manage") -> Catalog.route(:host_health)
      RBAC.can?(current_scope, "plugins.view") -> Catalog.route(:plugins)
      true -> Catalog.route(:edge_sites)
    end
  end

  defp can_edge_ops_tab?(current_scope) do
    RBAC.can?(current_scope, "settings.edge.manage") or can_agents_tab?(current_scope)
  end

  defp jobs_tab(path, current_scope) do
    %{
      label: "Jobs",
      navigate: Catalog.route(:jobs),
      active: String.starts_with?(path, "/admin/jobs"),
      show: RBAC.can?(current_scope, "settings.jobs.manage")
    }
  end

  defp auth_tab(path, current_scope) do
    %{
      label: "Auth",
      navigate: Catalog.route(:auth_users),
      active:
        String.starts_with?(path, "/settings/authentication") or
          String.starts_with?(path, "/settings/auth/"),
      show: show_auth_tab?(current_scope)
    }
  end

  # Auth section sub-navigation
  attr(:current_path, :string, required: true)
  attr(:class, :any, default: nil)

  attr(:current_scope, :map, default: nil)

  def auth_nav(assigns) do
    assigns = assign(assigns, :tabs, auth_tabs(assigns.current_path, assigns[:current_scope]))

    ~H"""
    <div class={["flex flex-wrap items-center gap-2", @class]}>
      <.ui_tabs tabs={@tabs} class="flex-wrap" size="sm" />
    </div>
    """
  end

  def auth_tabs(current_path, current_scope) do
    path = current_path || ""

    can_auth = RBAC.can?(current_scope, "settings.auth.manage")
    can_rbac = RBAC.can?(current_scope, "settings.rbac.manage")

    tabs =
      Enum.filter(
        [
          %{
            label: "Users",
            navigate: ~p"/settings/auth/users",
            active: String.starts_with?(path, "/settings/auth/users"),
            show: can_auth
          },
          %{
            label: "Policy Editor",
            navigate: ~p"/settings/auth/rbac",
            active: String.starts_with?(path, "/settings/auth/rbac"),
            show: can_auth or can_rbac
          },
          %{
            label: "Authorization",
            navigate: ~p"/settings/auth/authorization",
            active: String.starts_with?(path, "/settings/auth/authorization"),
            show: can_auth
          },
          %{
            label: "Authentication",
            navigate: ~p"/settings/authentication",
            active: String.starts_with?(path, "/settings/authentication"),
            show: can_auth
          }
        ],
        &Map.get(&1, :show, true)
      )

    tabs
  end

  defp show_auth_tab?(%{user: user} = scope) when not is_nil(user) do
    RBAC.can?(scope, "settings.auth.manage") or RBAC.can?(scope, "settings.rbac.manage")
  end

  defp show_auth_tab?(_), do: false

  # Events section sub-navigation
  attr(:current_path, :string, required: true)
  attr(:class, :any, default: nil)
  attr(:current_scope, :map, default: nil)

  def events_nav(assigns) do
    assigns = assign(assigns, :tabs, events_tabs(assigns.current_path, assigns[:current_scope]))

    ~H"""
    <div class={["flex flex-wrap items-center gap-2", @class]}>
      <.ui_tabs tabs={@tabs} class="flex-wrap" size="sm" />
    </div>
    """
  end

  def events_tabs(current_path, current_scope) do
    path = current_path || ""

    Enum.filter(
      [
        %{
          label: "Rules",
          navigate: ~p"/settings/rules",
          active: String.starts_with?(path, "/settings/rules"),
          show: can_rules_tab?(current_scope)
        },
        %{
          label: "Anomaly Detection",
          navigate: ~p"/settings/anomaly-detection",
          active: String.starts_with?(path, "/settings/anomaly-detection"),
          show: RBAC.can?(current_scope, "observability.alerts.manage")
        }
      ],
      &Map.get(&1, :show, true)
    )
  end

  defp can_rules_tab?(current_scope) do
    RBAC.can?(current_scope, "observability.rules.update") or
      RBAC.can?(current_scope, "observability.rules.create")
  end

  # Network section sub-navigation
  attr(:current_path, :string, required: true)
  attr(:class, :any, default: nil)
  attr(:current_scope, :map, default: nil)

  def network_nav(assigns) do
    path = assigns.current_path || ""

    assigns =
      assigns
      |> assign(
        :tabs,
        if(network_active?(path), do: network_tabs(path, assigns[:current_scope]), else: [])
      )
      |> assign(
        :discovery_tabs,
        discovery_tabs(path, assigns[:current_scope])
      )

    ~H"""
    <section class={["space-y-2 mb-4", @class]}>
      <div class="flex flex-wrap items-center gap-2">
        <.ui_tabs tabs={@tabs} class="flex-wrap" size="sm" />
      </div>
      <div :if={@discovery_tabs != []} class="flex flex-wrap items-center gap-2">
        <.ui_tabs tabs={@discovery_tabs} class="flex-wrap" size="sm" />
      </div>
    </section>
    """
  end

  def network_tabs(current_path, current_scope \\ nil) do
    path = current_path || ""

    path
    |> network_tabs_with_state()
    |> Enum.filter(&show_network_tab?(&1.label, current_scope))
  end

  defp network_tabs_with_state(path) do
    [
      %{
        label: "Network Flows",
        navigate: ~p"/settings/flows",
        active: String.starts_with?(path, "/settings/flows")
      },
      %{
        label: "BMP",
        navigate: ~p"/settings/networks/bmp",
        active: String.starts_with?(path, "/settings/networks/bmp")
      },
      %{
        label: "FieldSurvey",
        navigate: ~p"/settings/networks/field-survey",
        active: String.starts_with?(path, "/settings/networks/field-survey")
      },
      %{
        label: "MTR",
        navigate: ~p"/settings/networks/mtr",
        active: String.starts_with?(path, "/settings/networks/mtr")
      },
      %{
        label: "Integrations",
        navigate: ~p"/settings/networks/integrations",
        active: String.starts_with?(path, "/settings/networks/integrations")
      },
      %{
        label: "Threat Intel",
        navigate: ~p"/settings/networks/threat-intel",
        active: String.starts_with?(path, "/settings/networks/threat-intel")
      }
    ]
  end

  defp discovery_tabs(current_path, current_scope) do
    path = current_path

    tabs =
      if discovery_active?(path) do
        [
          %{
            label: "Sweep Profiles",
            navigate: ~p"/settings/networks",
            active: sweep_profiles_active?(path)
          },
          %{
            label: "Discovery Jobs",
            navigate: ~p"/settings/networks/discovery",
            active: String.starts_with?(path, "/settings/networks/discovery")
          },
          %{
            label: "Device Enrichment",
            navigate: ~p"/settings/networks/device-enrichment",
            active: String.starts_with?(path, "/settings/networks/device-enrichment")
          },
          %{
            label: "Device Hostnames",
            navigate: ~p"/settings/networks/hostname-rdns",
            active: String.starts_with?(path, "/settings/networks/hostname-rdns")
          },
          %{
            label: "Availability Sources",
            navigate: ~p"/settings/networks/availability-sources",
            active: String.starts_with?(path, "/settings/networks/availability-sources")
          },
          %{
            label: "Visibility Profiles",
            navigate: ~p"/settings/networks/visibility-profiles",
            active: String.starts_with?(path, "/settings/networks/visibility-profiles")
          },
          %{
            label: "Credentials and Rules",
            navigate: ~p"/settings/networks/credentials",
            active: String.starts_with?(path, "/settings/networks/credentials")
          },
          %{
            label: "Host Keys",
            navigate: ~p"/settings/networks/host-keys",
            active: String.starts_with?(path, "/settings/networks/host-keys"),
            requires_remote_access_ssh?: true
          },
          %{
            label: "Desktop Targets",
            navigate: ~p"/settings/networks/desktop-targets",
            active: String.starts_with?(path, "/settings/networks/desktop-targets"),
            requires_remote_access_rdp?: true
          },
          %{
            label: "Recordings",
            navigate: ~p"/settings/networks/recordings",
            active: String.starts_with?(path, "/settings/networks/recordings"),
            requires_remote_access_recordings?: true
          },
          %{
            label: "SNMP",
            navigate: ~p"/settings/snmp",
            active: String.starts_with?(path, "/settings/snmp")
          }
        ]
      else
        []
      end

    Enum.filter(tabs, &show_discovery_tab?(&1, current_scope))
  end

  defp network_active?(path) do
    String.starts_with?(path, "/settings/flows") or
      String.starts_with?(path, "/settings/networks/bmp") or
      String.starts_with?(path, "/settings/networks/field-survey") or
      String.starts_with?(path, "/settings/networks/mtr") or
      String.starts_with?(path, "/settings/networks/integrations") or
      String.starts_with?(path, "/settings/networks/threat-intel")
  end

  defp discovery_active?(path) do
    (String.starts_with?(path, "/settings/networks") or
       String.starts_with?(path, "/settings/snmp")) and
      not String.starts_with?(path, "/settings/networks/integrations") and
      not String.starts_with?(path, "/settings/networks/bmp") and
      not String.starts_with?(path, "/settings/networks/field-survey") and
      not String.starts_with?(path, "/settings/networks/mtr") and
      not String.starts_with?(path, "/settings/networks/threat-intel") and
      not String.starts_with?(path, "/settings/flows")
  end

  defp sweep_profiles_active?(path) do
    discovery_active?(path) and
      String.starts_with?(path, "/settings/networks") and
      not String.starts_with?(path, "/settings/networks/discovery") and
      not String.starts_with?(path, "/settings/networks/device-enrichment") and
      not String.starts_with?(path, "/settings/networks/hostname-rdns") and
      not String.starts_with?(path, "/settings/networks/availability-sources") and
      not String.starts_with?(path, "/settings/networks/visibility-profiles") and
      not String.starts_with?(path, "/settings/networks/credentials") and
      not String.starts_with?(path, "/settings/networks/host-keys") and
      not String.starts_with?(path, "/settings/networks/desktop-targets") and
      not String.starts_with?(path, "/settings/networks/recordings") and
      not String.starts_with?(path, "/settings/snmp")
  end

  defp show_network_tab?(_label, nil), do: true

  defp show_network_tab?(label, scope) do
    permission =
      case label do
        "Integrations" -> "settings.integrations.manage"
        "Network Flows" -> "settings.netflow.manage"
        "Threat Intel" -> "plugins.assign"
        _ -> "settings.networks.manage"
      end

    RBAC.can?(scope, permission)
  end

  defp show_discovery_tab?(%{requires_remote_access_ssh?: true} = tab, scope) do
    FeatureFlags.remote_access_ssh_enabled?() and
      show_discovery_tab?(Map.delete(tab, :requires_remote_access_ssh?), scope)
  end

  defp show_discovery_tab?(%{requires_remote_access_rdp?: true} = tab, scope) do
    FeatureFlags.remote_access_desktop_rdp_enabled?() and
      show_discovery_tab?(Map.delete(tab, :requires_remote_access_rdp?), scope)
  end

  defp show_discovery_tab?(%{requires_remote_access_recordings?: true} = tab, scope) do
    remote_access_recordings_enabled?() and
      show_discovery_tab?(Map.delete(tab, :requires_remote_access_recordings?), scope)
  end

  defp show_discovery_tab?(%{label: label}, scope), do: show_discovery_tab?(label, scope)

  defp show_discovery_tab?(_label, nil), do: true

  defp show_discovery_tab?(label, scope) do
    permission =
      case label do
        "SNMP" -> "settings.snmp_profiles.manage"
        "Visibility Profiles" -> "visibility_profiles:read"
        "Credentials and Rules" -> "settings.credentials.manage"
        "Host Keys" -> "settings.remote_access_host_keys.manage"
        "Desktop Targets" -> "settings.edge.manage"
        "Recordings" -> remote_access_recording_permissions()
        _ -> "settings.networks.manage"
      end

    case permission do
      permissions when is_list(permissions) -> RBAC.can_any?(scope, permissions)
      permission -> RBAC.can?(scope, permission)
    end
  end

  defp remote_access_discovery_tab_visible?(current_scope) do
    (FeatureFlags.remote_access_ssh_enabled?() and
       (RBAC.can?(current_scope, "settings.remote_access_host_keys.manage") or
          RBAC.can?(current_scope, "devices.remote_access.ssh.open"))) or
      (FeatureFlags.remote_access_desktop_rdp_enabled?() and
         (RBAC.can?(current_scope, "settings.edge.manage") or
            RBAC.can?(current_scope, "devices.remote_access.rdp.open")))
  end

  defp remote_access_recordings_enabled? do
    FeatureFlags.remote_access_ssh_enabled?() or FeatureFlags.remote_access_desktop_rdp_enabled?()
  end

  defp remote_access_recording_permissions do
    ["devices.remote_access.ssh.open", "devices.remote_access.rdp.open"]
  end
end
