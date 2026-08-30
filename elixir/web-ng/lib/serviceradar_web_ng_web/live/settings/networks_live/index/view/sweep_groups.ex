defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View.SweepGroups do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.Settings.NetworksLive.ActiveScansComponents,
    only: [format_last_run: 1, group_last_run_at: 1, persisted_sweep_command_status: 1]

  import ServiceRadarWebNGWeb.Settings.NetworksLive.FormComponents
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.CommandStatus

  attr :groups, :list, required: true
  attr :sweep_command_statuses, :map, default: %{}
  attr :can_manage_networks, :boolean, default: false

  def render(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div>
            <div class="text-sm font-semibold">Sweep Groups</div>
            <p class="text-xs text-sr-muted">
              {length(@groups)} group(s) configured
            </p>
          </div>
          <.link navigate={~p"/settings/networks/groups/new"}>
            <.ui_button variant="primary" size="sm">
              <.icon name="hero-plus" class="size-4" /> New Group
            </.ui_button>
          </.link>
        </div>
      </:header>

      <div class="sr-ui-table-shell">
        <table class={ui_table_class(size: "sm")}>
          <thead>
            <tr class="text-xs uppercase tracking-wide text-sr-muted">
              <th>Status</th>
              <th>Name</th>
              <th>Schedule</th>
              <th>Partition</th>
              <th>Agent</th>
              <th>Last Run</th>
              <th>Run Status</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@groups == []}>
              <td colspan="8" class="text-center text-sr-muted py-8">
                No sweep groups configured. Create one to start scanning your network.
              </td>
            </tr>
            <%= for group <- @groups do %>
              <tr class="hover:bg-sr-subtle/40">
                <td>
                  <button
                    phx-click="toggle_group"
                    phx-value-id={group.id}
                    class="flex items-center gap-1.5 cursor-pointer"
                  >
                    <span class={"size-2 rounded-full #{if group.enabled, do: "bg-success", else: "bg-sr-muted/30"}"}></span>
                    <span class="text-xs">{if group.enabled, do: "Enabled", else: "Disabled"}</span>
                  </button>
                </td>
                <td>
                  <.link
                    navigate={~p"/settings/networks/groups/#{group.id}"}
                    class="font-medium hover:text-sr-brand"
                  >
                    {group.name}
                  </.link>
                  <p :if={group.description} class="text-xs text-sr-muted truncate max-w-xs">
                    {group.description}
                  </p>
                </td>
                <td class="font-mono text-xs">
                  {format_schedule(group)}
                </td>
                <td class="text-xs">
                  {group.partition}
                </td>
                <td class="text-xs text-sr-muted">
                  {agent_assignment_summary(group.agent_ids)}
                </td>
                <td class="text-xs text-sr-muted">
                  {format_last_run(group_last_run_at(group))}
                </td>
                <td class="text-xs">
                  <%= if status =
                           Map.get(@sweep_command_statuses, group.id) ||
                             persisted_sweep_command_status(group) do %>
                    <.ui_badge variant={command_status_variant(status)} size="xs">
                      {command_status_label(status)}
                    </.ui_badge>
                  <% else %>
                    <span class="text-xs text-sr-muted">—</span>
                  <% end %>
                </td>
                <td>
                  <div class="flex items-center gap-1">
                    <.ui_button
                      :if={@can_manage_networks}
                      id={"run-sweep-group-#{group.id}"}
                      variant="ghost"
                      size="xs"
                      phx-click="run_sweep_group"
                      phx-value-id={group.id}
                    >
                      <.icon name="hero-play" class="size-3" />
                    </.ui_button>
                    <.link navigate={~p"/settings/networks/groups/#{group.id}/edit"}>
                      <.ui_button variant="ghost" size="xs">
                        <.icon name="hero-pencil" class="size-3" />
                      </.ui_button>
                    </.link>
                    <.ui_button
                      variant="ghost"
                      size="xs"
                      phx-click="delete_group"
                      phx-value-id={group.id}
                      data-confirm="Are you sure you want to delete this sweep group?"
                    >
                      <.icon name="hero-trash" class="size-3" />
                    </.ui_button>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </.ui_panel>
    """
  end
end
