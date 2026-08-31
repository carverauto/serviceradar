defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View.ActiveScans do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.Settings.NetworksLive.ActiveScansComponents

  attr :running, :list, required: true
  attr :recent, :list, required: true
  attr :groups, :list, required: true
  attr :execution_progress, :map, default: %{}
  attr :timezone, :string, required: true

  def render(assigns) do
    # Build a map of group_id -> group for quick lookup
    groups_map = Map.new(assigns.groups, &{&1.id, &1})
    assigns = assign(assigns, :groups_map, groups_map)

    ~H"""
    <div class="space-y-4">
      <!-- Statistics Cards -->
      <.scan_statistics
        running={@running}
        recent={@recent}
        groups={@groups}
        timezone={@timezone}
      />

      <.ui_panel>
        <:header>
          <div class="flex items-center gap-2">
            <.icon name="hero-play-circle" class="size-5 text-success" />
            <div class="text-sm font-semibold">Running Scans</div>
            <span
              :if={length(@running) > 0}
              class="ml-1 inline-flex items-center justify-center size-5 text-xs font-semibold rounded-full bg-success/20 text-success"
            >
              {length(@running)}
            </span>
          </div>
        </:header>

        <div :if={@running == []} class="py-8 text-center text-sr-muted">
          <.icon name="hero-clock" class="size-8 mx-auto mb-2 opacity-50" />
          <p>No scans currently running</p>
        </div>

        <div :if={@running != []} class="space-y-3">
          <%= for execution <- @running do %>
            <.running_scan_card
              execution={execution}
              group={Map.get(@groups_map, execution.sweep_group_id)}
              progress={
                Map.get(@execution_progress, Map.get(execution, :execution_id) || execution.id)
              }
              timezone={@timezone}
            />
          <% end %>
        </div>
      </.ui_panel>

      <.ui_panel>
        <:header>
          <div class="flex items-center gap-2">
            <.icon name="hero-clock" class="size-5 text-sr-muted" />
            <div class="text-sm font-semibold">Recent Completions</div>
          </div>
        </:header>

        <div :if={@recent == []} class="py-8 text-center text-sr-muted">
          <.icon name="hero-document-text" class="size-8 mx-auto mb-2 opacity-50" />
          <p>No recent scan executions</p>
        </div>

        <div :if={@recent != []} class="overflow-x-auto">
          <table class={ui_table_class(size: "sm")}>
            <thead>
              <tr class="text-xs uppercase tracking-wide text-sr-muted">
                <th>Status</th>
                <th>Sweep Group</th>
                <th>Started</th>
                <th>Duration</th>
                <th>Hosts</th>
                <th>Success Rate</th>
                <th>Metrics</th>
              </tr>
            </thead>
            <tbody>
              <%= for execution <- @recent do %>
                <.recent_execution_row
                  execution={execution}
                  group={Map.get(@groups_map, execution.sweep_group_id)}
                  timezone={@timezone}
                />
              <% end %>
            </tbody>
          </table>
        </div>
      </.ui_panel>
    </div>
    """
  end
end
