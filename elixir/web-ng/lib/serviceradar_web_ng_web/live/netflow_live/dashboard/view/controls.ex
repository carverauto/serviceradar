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
        <h1 class="text-lg font-bold text-sr-ink">Flow Statistics</h1>
        <p class="text-xs text-sr-muted">Network traffic overview</p>
      </div>

      <div class="flex items-center gap-2">
        <%!-- Time window selector --%>
        <div class="flex flex-wrap gap-1">
          <.ui_button
            :for={{tw, label} <- @time_windows}
            type="button"
            size="xs"
            variant={if(tw == @time_window, do: "primary", else: "ghost")}
            active={tw == @time_window}
            phx-click="change_time_window"
            phx-value-tw={tw}
          >
            {label}
          </.ui_button>
        </div>

        <%!-- Units selector --%>
        <form phx-change="change_unit_mode">
          <select
            class={ui_field_class(size: "xs")}
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
            class={ui_field_class(size: "xs")}
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

    <div :if={@query} class={ui_alert_class(variant: "info", class: "py-2 px-3 text-xs")}>
      <.icon name="hero-funnel-mini" class="w-4 h-4 shrink-0" />
      <span class="truncate">
        Active flow filter: <code class="font-mono">{@query}</code>
      </span>
      <.ui_button phx-click="clear_query" size="xs" variant="ghost">Clear</.ui_button>
    </div>

    <div class="flex flex-wrap gap-2">
      <.ui_button
        :for={{section_key, section_label} <- @sections}
        type="button"
        size="xs"
        variant={if(@section == section_key, do: "primary", else: "outline")}
        active={@section == section_key}
        phx-click="change_section"
        phx-value-section={section_key}
      >
        {section_label}
      </.ui_button>
    </div>
    """
  end
end
