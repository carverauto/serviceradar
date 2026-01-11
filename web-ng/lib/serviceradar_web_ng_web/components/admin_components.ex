defmodule ServiceRadarWebNGWeb.AdminComponents do
  @moduledoc """
  Shared UI components for admin pages.
  """
  use Phoenix.Component
  import ServiceRadarWebNGWeb.UIComponents

  @doc """
  Renders admin section navigation tabs.
  """
  attr :current_path, :string, required: true

  def admin_nav(assigns) do
    tabs = [
      %{
        label: "Job Scheduler",
        href: "/admin/jobs",
        active: assigns.current_path == "/admin/jobs"
      },
      %{
        label: "Edge Onboarding",
        href: "/admin/edge-packages",
        active: String.starts_with?(assigns.current_path || "", "/admin/edge-packages")
      },
      %{
        label: "Integrations",
        href: "/admin/integrations",
        active: String.starts_with?(assigns.current_path || "", "/admin/integrations")
      },
      %{
        label: "Collectors",
        href: "/admin/collectors",
        active: String.starts_with?(assigns.current_path || "", "/admin/collectors")
      },
      %{
        label: "Edge Sites",
        href: "/admin/edge-sites",
        active: String.starts_with?(assigns.current_path || "", "/admin/edge-sites")
      },
      %{
        label: "NATS",
        href: "/admin/nats",
        active: String.starts_with?(assigns.current_path || "", "/admin/nats")
      }
    ]

    assigns = assign(assigns, :tabs, tabs)

    ~H"""
    <nav class="mb-6">
      <.ui_tabs tabs={@tabs} size="sm" />
    </nav>
    """
  end
end
