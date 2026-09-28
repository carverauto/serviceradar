defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View.ActiveScans do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.Settings.NetworksLive.ActiveScansComponents
  import ServiceRadarWebNGWeb.Settings.NetworksLive.MtrScanComponents

  attr :running, :list, required: true
  attr :recent, :list, required: true
  attr :groups, :list, required: true
  attr :execution_progress, :map, default: %{}
  attr :mtr_running, :list, default: []
  attr :mtr_recent, :list, default: []
  attr :can_view_mtr_jobs, :boolean, default: false
  attr :filter, :atom, default: :all
  attr :timezone, :string, required: true

  def render(assigns) do
    # Build a map of group_id -> group for quick lookup
    groups_map = Map.new(assigns.groups, &{&1.id, &1})
    show_sweeps? = assigns.filter in [:all, :sweeps] or not assigns.can_view_mtr_jobs
    show_mtr? = assigns.can_view_mtr_jobs and assigns.filter in [:all, :mtr]

    assigns =
      assigns
      |> assign(:groups_map, groups_map)
      |> assign(:show_sweeps?, show_sweeps?)
      |> assign(:show_mtr?, show_mtr?)
      |> assign(:running_sweeps, if(show_sweeps?, do: assigns.running, else: []))
      |> assign(:running_mtr, if(show_mtr?, do: assigns.mtr_running, else: []))

    ~H"""
    <div class="space-y-4">
      <div :if={@can_view_mtr_jobs} id="active-scans-filter" class="flex items-center gap-2">
        <span class="text-xs text-sr-muted">Show</span>
        <.ui_button
          :for={{label, value} <- [{"All", "all"}, {"Sweeps", "sweeps"}, {"MTR", "mtr"}]}
          type="button"
          size="xs"
          variant={if Atom.to_string(@filter) == value, do: "primary", else: "ghost"}
          phx-click="active_scans_filter"
          phx-value-filter={value}
        >
          {label}
        </.ui_button>
      </div>

      <!-- Statistics Cards -->
      <.scan_statistics
        :if={@show_sweeps?}
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
              :if={length(@running_sweeps) + length(@running_mtr) > 0}
              class="ml-1 inline-flex items-center justify-center size-5 text-xs font-semibold rounded-full bg-success/20 text-success"
            >
              {length(@running_sweeps) + length(@running_mtr)}
            </span>
          </div>
        </:header>

        <div :if={@running_sweeps == [] and @running_mtr == []} class="py-8 text-center text-sr-muted">
          <.icon name="hero-clock" class="size-8 mx-auto mb-2 opacity-50" />
          <p>No scans currently running</p>
        </div>

        <div :if={@running_sweeps != [] or @running_mtr != []} class="space-y-3">
          <.mtr_running_card :for={job <- @running_mtr} job={job} timezone={@timezone} />
          <%= for execution <- @running_sweeps do %>
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

      <.ui_panel :if={@show_sweeps?}>
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

      <.ui_panel :if={@show_mtr?} id="active-scans-recent-mtr">
        <:header>
          <div class="flex items-center gap-2">
            <.icon name="hero-arrows-right-left" class="size-5 text-sr-muted" />
            <div class="text-sm font-semibold">Recent MTR Jobs</div>
          </div>
        </:header>

        <div :if={@mtr_recent == []} class="py-8 text-center text-sr-muted">
          <p>No recent MTR bulk jobs</p>
        </div>

        <div :if={@mtr_recent != []} class="overflow-x-auto">
          <table class={ui_table_class(size: "sm")}>
            <thead>
              <tr class="text-xs uppercase tracking-wide text-sr-muted">
                <th>Status</th>
                <th>Profile</th>
                <th>Protocols</th>
                <th>Started</th>
                <th>Duration</th>
                <th>Traces</th>
                <th>Reached</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <.mtr_recent_row :for={job <- @mtr_recent} job={job} timezone={@timezone} />
            </tbody>
          </table>
        </div>
      </.ui_panel>
    </div>
    """
  end
end
