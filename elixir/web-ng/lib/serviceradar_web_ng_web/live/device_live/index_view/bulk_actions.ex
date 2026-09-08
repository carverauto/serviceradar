defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.BulkActions do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DeviceLive.IndexView.Rows, only: [has_any_filter?: 1]
  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNG.RBAC

  def render(assigns) do
    ~H"""
    <!-- Bulk Actions Bar -->
    <div
      :if={@selected_count > 0 or @select_all_matching}
      class="mb-4 p-3 bg-sr-brand/10 border border-sr-brand/20 rounded-lg flex flex-wrap items-center justify-between gap-3"
    >
      <div class="flex flex-wrap items-center gap-3">
        <span class="text-sm font-medium text-sr-brand">
          <%= if @select_all_matching do %>
            <.icon name="hero-check-badge" class="size-4 inline" />
            All {@total_matching_count} matching device(s) selected
          <% else %>
            {String.pad_leading(Integer.to_string(@selected_count), 2, "0")} device(s) selected
          <% end %>
        </span>

        <!-- Select All Matching Toggle -->
        <button
          :if={!@select_all_matching and has_any_filter?(@srql)}
          phx-click="toggle_select_all_matching"
          class="text-xs text-sr-brand hover:text-sr-brand-focus underline"
        >
          Select all matching filter
        </button>

        <button
          phx-click="clear_selection"
          class="text-xs text-sr-muted hover:text-sr-ink"
        >
          Clear selection
        </button>
      </div>
      <div class="flex items-center gap-2">
        <.ui_button
          :if={RBAC.can?(@current_scope, "ansible.runs.launch")}
          variant="primary"
          size="sm"
          phx-click="launch_ansible_for_selection"
          disabled={@effective_count == 0 or @select_all_matching}
          title={ansible_launch_title(@effective_count, @select_all_matching)}
        >
          <.icon name="hero-play" class="size-4" /> Launch Playbook
        </.ui_button>
        <.ui_button
          :if={can_launch_northbound_actions?(@current_scope)}
          variant="outline"
          size="sm"
          phx-click="run_action_for_selection"
          disabled={@run_action_disabled?}
          title={@run_action_title}
        >
          <.icon name="hero-play" class="size-4" />
          {if @northbound_device_actions_loading, do: "Checking actions...", else: "Run Action"}
        </.ui_button>
        <.ui_button
          :if={RBAC.can?(@current_scope, "devices.bulk_edit")}
          variant="primary"
          size="sm"
          phx-click="open_bulk_edit_modal"
        >
          <.icon name="hero-tag" class="size-4" /> Bulk Edit
        </.ui_button>
        <.ui_button
          :if={RBAC.can?(@current_scope, "devices.bulk_edit")}
          variant="outline"
          size="sm"
          phx-click="open_bulk_availability_source_modal"
        >
          <.icon name="hero-signal" class="size-4" /> Set Source
        </.ui_button>
        <.ui_button
          :if={RBAC.can?(@current_scope, "devices.bulk_delete")}
          variant="danger"
          size="sm"
          phx-click="open_bulk_delete_modal"
        >
          <.icon name="hero-trash" class="size-4" /> Bulk Delete
        </.ui_button>
      </div>
    </div>
    """
  end

  defp can_launch_northbound_actions?(scope) do
    RBAC.can?(scope, "northbound.actions.launch")
  end

  defp ansible_launch_title(_effective_count, true), do: "Choose specific devices before launching a playbook"

  defp ansible_launch_title(0, false), do: "Select at least one device"

  defp ansible_launch_title(_effective_count, false), do: "Launch a reviewed playbook for selected devices"
end
