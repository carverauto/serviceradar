defmodule ServiceRadarWebNGWeb.NetflowLive.Dashboard.View.Controls do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  attr(:dashboard, :map, required: true)

  def render(%{dashboard: dashboard} = assigns) do
    assigns = Map.merge(assigns, dashboard)

    ~H"""
    <%!-- Header with controls --%>
    <div class="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-3">
      <div>
        <h1 class="text-lg font-bold text-base-content">Flow Statistics</h1>
        <p class="text-xs text-base-content/60">Network traffic overview</p>
      </div>

      <div class="flex items-center gap-2">
        <%!-- Time window selector --%>
        <div class="join">
          <button
            :for={{tw, label} <- @time_windows}
            class={["join-item btn btn-xs", tw == @time_window && "btn-active btn-primary"]}
            phx-click="change_time_window"
            phx-value-tw={tw}
          >
            {label}
          </button>
        </div>

        <%!-- Units selector --%>
        <form phx-change="change_unit_mode">
          <select
            class="select select-xs select-bordered"
            name="unit"
          >
            <option
              :for={{mode, label} <- @unit_modes}
              value={mode}
              selected={mode == @unit_mode}
            >
              {label}
            </option>
          </select>
        </form>

        <%!-- Metric mode selector --%>
        <form phx-change="change_metric_mode">
          <select
            class="select select-xs select-bordered"
            name="metric"
          >
            <option
              :for={{mode, label} <- @metric_modes}
              value={mode}
              selected={mode == @metric_mode}
            >
              {label}
            </option>
          </select>
        </form>
      </div>
    </div>

    <div :if={@query} class="alert alert-info py-2 px-3 text-xs">
      <.icon name="hero-funnel-mini" class="w-4 h-4 shrink-0" />
      <span class="truncate">
        Active flow filter: <code class="font-mono">{@query}</code>
      </span>
      <button class="btn btn-ghost btn-xs" phx-click="clear_query">Clear</button>
    </div>

    <div class="flex flex-wrap gap-2">
      <button
        :for={{section_key, section_label} <- @sections}
        class={[
          "btn btn-xs",
          if(@section == section_key, do: "btn-primary", else: "btn-outline")
        ]}
        phx-click="change_section"
        phx-value-section={section_key}
      >
        {section_label}
      </button>
    </div>
    """
  end
end
