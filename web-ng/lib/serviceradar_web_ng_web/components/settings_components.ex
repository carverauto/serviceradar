defmodule ServiceRadarWebNGWeb.SettingsComponents do
  @moduledoc """
  Shared components for the Settings section layout and navigation.
  """

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNG.RBAC

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

  def settings_tabs(current_path, current_scope \\ nil) do
    path = current_path || ""

    can_settings_view = RBAC.can?(current_scope, "settings.view")

    can_networks =
      RBAC.can?(current_scope, "settings.networks.manage") or
        RBAC.can?(current_scope, "settings.integrations.manage") or
        RBAC.can?(current_scope, "settings.snmp_profiles.manage")

    can_agents =
      RBAC.can?(current_scope, "settings.sysmon_profiles.manage") or
        RBAC.can?(current_scope, "settings.edge.manage") or
        RBAC.can?(current_scope, "plugins.view") or
        RBAC.can?(current_scope, "settings.plugins.manage")

    can_events =
      RBAC.can?(current_scope, "observability.rules.update") or
        RBAC.can?(current_scope, "observability.rules.create")

    can_edge_ops = RBAC.can?(current_scope, "settings.edge.manage")
    can_jobs = RBAC.can?(current_scope, "settings.jobs.manage")

    tabs =
      [
        %{
          label: "Cluster",
          navigate: ~p"/settings/cluster",
          active:
            String.starts_with?(path, "/settings/cluster") or
              String.starts_with?(path, "/admin/cluster"),
          show: can_settings_view
        },
        %{
          label: "Network",
          navigate: ~p"/settings/networks",
          active:
            String.starts_with?(path, "/settings/networks") or
              String.starts_with?(path, "/settings/snmp"),
          show: can_networks
        },
        %{
          label: "Agents",
          navigate: ~p"/settings/sysmon",
          active:
            String.starts_with?(path, "/settings/sysmon") or
              String.starts_with?(path, "/settings/agents") or
              String.starts_with?(path, "/admin/edge-packages") or
              String.starts_with?(path, "/admin/plugins"),
          show: can_agents
        },
        %{
          label: "Events",
          navigate: ~p"/settings/rules",
          active: String.starts_with?(path, "/settings/rules"),
          show: can_events
        },
        %{
          label: "Edge Ops",
          navigate: ~p"/admin/edge-sites",
          active:
            String.starts_with?(path, "/admin/collectors") or
              String.starts_with?(path, "/admin/edge-sites") or
              String.starts_with?(path, "/admin/nats"),
          show: can_edge_ops
        },
        %{
          label: "Jobs",
          navigate: ~p"/admin/jobs",
          active: String.starts_with?(path, "/admin/jobs"),
          show: can_jobs
        },
        %{
          label: "Auth",
          navigate: ~p"/settings/auth/users",
          active:
            String.starts_with?(path, "/settings/authentication") or
              String.starts_with?(path, "/settings/auth/"),
          show: show_auth_tab?(current_scope)
        }
      ]
      |> Enum.filter(&Map.get(&1, :show, true))

    tabs
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
          label: "Authentication",
          navigate: ~p"/settings/authentication",
          active: String.starts_with?(path, "/settings/authentication"),
          show: can_auth
        }
      ]
      |> Enum.filter(&Map.get(&1, :show, true))

    tabs
  end

  defp show_auth_tab?(%{user: user} = scope) when not is_nil(user) do
    RBAC.can?(scope, "settings.auth.manage") or RBAC.can?(scope, "settings.rbac.manage")
  end

  defp show_auth_tab?(_), do: false

  # Network section sub-navigation
  attr(:current_path, :string, required: true)
  attr(:class, :any, default: nil)
  attr(:current_scope, :map, default: nil)

  def network_nav(assigns) do
    assigns = assign(assigns, :tabs, network_tabs(assigns.current_path, assigns[:current_scope]))

    ~H"""
    <div class={["flex flex-wrap items-center gap-2 mb-4", @class]}>
      <.ui_tabs tabs={@tabs} class="flex-wrap" size="sm" />
    </div>
    """
  end

  def network_tabs(current_path, current_scope \\ nil) do
    path = current_path || ""

    can_networks = RBAC.can?(current_scope, "settings.networks.manage")
    can_integrations = RBAC.can?(current_scope, "settings.integrations.manage")
    can_snmp = RBAC.can?(current_scope, "settings.snmp_profiles.manage")

    [
      %{
        label: "Sweep Profiles",
        navigate: ~p"/settings/networks",
        active:
          String.starts_with?(path, "/settings/networks") and
            not String.starts_with?(path, "/settings/networks/discovery") and
            not String.starts_with?(path, "/settings/networks/integrations")
      },
      %{
        label: "Discovery",
        navigate: ~p"/settings/networks/discovery",
        active: String.starts_with?(path, "/settings/networks/discovery")
      },
      %{
        label: "SNMP",
        navigate: ~p"/settings/snmp",
        active: String.starts_with?(path, "/settings/snmp")
      },
      %{
        label: "Integrations",
        navigate: ~p"/settings/networks/integrations",
        active: String.starts_with?(path, "/settings/networks/integrations")
      }
    ]
    |> Enum.filter(fn tab ->
      case tab.label do
        "Integrations" -> can_integrations or is_nil(current_scope)
        "SNMP" -> can_snmp or is_nil(current_scope)
        _ -> can_networks or is_nil(current_scope)
      end
    end)
  end

  # Agents section sub-navigation
  attr(:current_path, :string, required: true)
  attr(:class, :any, default: nil)
  attr(:current_scope, :map, default: nil)

  def agents_nav(assigns) do
    assigns = assign(assigns, :tabs, agents_tabs(assigns.current_path, assigns[:current_scope]))

    ~H"""
    <div class={["flex flex-wrap items-center gap-2 mb-4", @class]}>
      <.ui_tabs tabs={@tabs} class="flex-wrap" size="sm" />
    </div>
    """
  end

  def agents_tabs(current_path, current_scope \\ nil) do
    path = current_path || ""

    can_sysmon = RBAC.can?(current_scope, "settings.sysmon_profiles.manage")
    can_edge = RBAC.can?(current_scope, "settings.edge.manage")
    can_plugins = RBAC.can?(current_scope, "plugins.view")

    tabs =
      [
        %{
          label: "Host Health",
          navigate: ~p"/settings/sysmon",
          active: String.starts_with?(path, "/settings/sysmon"),
          show: can_sysmon
        },
        %{
          label: "Deploy",
          navigate: ~p"/settings/agents/deploy",
          active:
            String.starts_with?(path, "/settings/agents/deploy") or
              String.starts_with?(path, "/admin/edge-packages"),
          show: can_edge
        },
        %{
          label: "Plugins",
          navigate: ~p"/settings/agents/plugins",
          active:
            String.starts_with?(path, "/settings/agents/plugins") or
              String.starts_with?(path, "/admin/plugins"),
          show: can_plugins
        }
      ]
      |> Enum.filter(&Map.get(&1, :show, true))

    tabs
  end

  # Edge Ops section sub-navigation
  attr(:current_path, :string, required: true)
  attr(:class, :any, default: nil)

  def edge_nav(assigns) do
    assigns = assign(assigns, :tabs, edge_tabs(assigns.current_path))

    ~H"""
    <div class={["flex flex-wrap items-center gap-2", @class]}>
      <.ui_tabs tabs={@tabs} class="flex-wrap" />
    </div>
    """
  end

  def edge_tabs(current_path) do
    path = current_path || ""

    [
      %{
        label: "Edge Sites",
        navigate: ~p"/admin/edge-sites",
        active: String.starts_with?(path, "/admin/edge-sites")
      },
      %{
        label: "Data Collectors",
        navigate: ~p"/admin/collectors",
        active: String.starts_with?(path, "/admin/collectors")
      }
    ]
  end
end
