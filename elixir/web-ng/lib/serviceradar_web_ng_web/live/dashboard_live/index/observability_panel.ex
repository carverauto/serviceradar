defmodule ServiceRadarWebNGWeb.DashboardLive.Index.ObservabilityPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.DashboardLive.Index.Common
  alias ServiceRadarWebNGWeb.DashboardLive.Index.EventsPanel
  alias ServiceRadarWebNGWeb.DashboardLive.Index.MetricsPanel

  attr(:dashboard, :map, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  def render(assigns) do
    dashboard = assigns.dashboard

    assigns =
      assign(
        assigns,
        :time_window_label,
        dashboard[:time_window_label] || dashboard["time_window_label"] || ""
      )

    ~H"""
    <Common.panel title="Events Over Time" class="sr-ops-observability-panel">
      <:actions>
        <span :if={@time_window_label != ""} class="sr-ops-select">{@time_window_label}</span>
      </:actions>
      <div class="sr-ops-observability-split" data-testid="observability-split">
        <section class="sr-ops-observability-pane" aria-label="Events over time">
          <EventsPanel.render dashboard={@dashboard} timezone={@timezone} embedded />
        </section>
        <section class="sr-ops-observability-pane" aria-label="Observability metrics">
          <h3>Metrics</h3>
          <MetricsPanel.render dashboard={@dashboard} embedded />
        </section>
      </div>
    </Common.panel>
    """
  end
end
