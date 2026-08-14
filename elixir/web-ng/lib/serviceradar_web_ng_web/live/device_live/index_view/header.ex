defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.Header do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNG.RBAC

  def render(assigns) do
    ~H"""
    <!-- Header with Action Buttons -->
    <div class="mb-6 flex flex-wrap items-center justify-between gap-4">
      <div>
        <h1 class="text-2xl font-semibold text-sr-ink">{@page_title}</h1>
        <p class="text-sm text-sr-muted">
          <%= if @live_action == :new_devices do %>
            Devices first seen in the last 30 days. Edit the SRQL query to refine the report.
          <% else %>
            Manage and monitor your network devices
          <% end %>
        </p>
      </div>
      <div class="flex flex-wrap items-center gap-2">
        <.ui_button
          :if={RBAC.can?(@current_scope, "devices.create")}
          phx-click="open_add_device_modal"
          variant="primary"
          size="sm"
        >
          <.icon name="hero-plus" class="size-4" /> Add Device
        </.ui_button>
        <.ui_button
          :if={RBAC.can?(@current_scope, "devices.import")}
          phx-click="open_import_modal"
          variant="outline"
          size="sm"
        >
          <.icon name="hero-arrow-up-tray" class="size-4" /> Import CSV
        </.ui_button>
        <.link
          :if={RBAC.can?(@current_scope, "settings.networks.manage")}
          navigate={~p"/settings/networks"}
        >
          <.ui_button variant="ghost" size="sm">
            <.icon name="hero-signal" class="size-4" /> Network Discovery
          </.ui_button>
        </.link>
      </div>
    </div>

    <div :if={@managed_device_limit_exceeded} class="mb-4">
      <div role="alert" class={ui_alert_class("warning")}>
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <div class="text-sm">
          <div class="font-semibold">Managed device advisory limit exceeded</div>
          <div>
            This deployment is using {@managed_device_count} managed devices, above the
            configured advisory limit of {@managed_device_limit}. Managed device count tracks
            active, non-deleted inventory devices marked managed.
          </div>
        </div>
      </div>
    </div>

    <!-- Device Stats Cards -->

    """
  end
end
