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
      class="mb-4 p-3 bg-primary/10 border border-primary/20 rounded-lg flex flex-wrap items-center justify-between gap-3"
    >
      <div class="flex flex-wrap items-center gap-3">
        <span class="text-sm font-medium text-primary">
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
          class="text-xs text-primary hover:text-primary-focus underline"
        >
          Select all matching filter
        </button>

        <button
          phx-click="clear_selection"
          class="text-xs text-base-content/60 hover:text-base-content"
        >
          Clear selection
        </button>
      </div>
      <div class="flex items-center gap-2">
        <.ui_button
          :if={can_launch_northbound_actions?(@current_scope)}
          variant="primary"
          size="sm"
          phx-click="run_task_for_selection"
          disabled={@run_task_disabled?}
          title={@run_task_title}
        >
          <.icon name="hero-play" class="size-4" />
          {if @northbound_device_actions_loading, do: "Checking jobs...", else: "Run Task"}
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
    RBAC.can?(scope, "northbound.actions.launch") or RBAC.can?(scope, "ansible.runs.launch")
  end
end
