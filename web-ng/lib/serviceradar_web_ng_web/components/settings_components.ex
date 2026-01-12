defmodule ServiceRadarWebNGWeb.SettingsComponents do
  @moduledoc """
  Shared components for the Settings section layout and navigation.
  """

  use ServiceRadarWebNGWeb, :html

  attr :current_path, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def settings_shell(assigns) do
    ~H"""
    <div class={["mx-auto w-full max-w-7xl p-6 space-y-6", @class]}>
      <section class="space-y-6">
        {render_slot(@inner_block)}
      </section>
    </div>
    """
  end

  attr :current_path, :string, required: true
  attr :class, :any, default: nil

  def settings_nav(assigns) do
    assigns = assign(assigns, :tabs, settings_tabs(assigns.current_path))

    ~H"""
    <div class={["flex flex-wrap items-center gap-2", @class]}>
      <.ui_tabs tabs={@tabs} class="flex-wrap" />
    </div>
    """
  end

  def settings_tabs(current_path) do
    path = current_path || ""

    [
      %{
        label: "Cluster",
        navigate: ~p"/settings/cluster",
        active:
          String.starts_with?(path, "/settings/cluster") or
            String.starts_with?(path, "/admin/cluster")
      },
      %{
        label: "Networks",
        navigate: ~p"/settings/networks",
        active: String.starts_with?(path, "/settings/networks")
      },
      %{
        label: "Events",
        navigate: ~p"/settings/rules",
        active: String.starts_with?(path, "/settings/rules")
      },
      %{
        label: "Edge Ops",
        navigate: ~p"/admin/edge-sites",
        active:
          String.starts_with?(path, "/admin/collectors") or
            String.starts_with?(path, "/admin/edge-sites") or
            String.starts_with?(path, "/admin/nats") or
            String.starts_with?(path, "/admin/edge-packages")
      },
      %{
        label: "Integrations",
        navigate: ~p"/admin/integrations",
        active: String.starts_with?(path, "/admin/integrations")
      },
      %{
        label: "Jobs",
        navigate: ~p"/admin/jobs",
        active: String.starts_with?(path, "/admin/jobs")
      }
    ]
  end

  attr :current_path, :string, required: true
  attr :class, :any, default: nil

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
        label: "Collectors",
        navigate: ~p"/admin/collectors",
        active: String.starts_with?(path, "/admin/collectors")
      },
      %{
        label: "Sites & NATS",
        navigate: ~p"/admin/edge-sites",
        active:
          String.starts_with?(path, "/admin/edge-sites") or
            String.starts_with?(path, "/admin/nats")
      },
      %{
        label: "Onboarding",
        navigate: ~p"/admin/edge-packages",
        active: String.starts_with?(path, "/admin/edge-packages")
      }
    ]
  end
end
