defmodule ServiceRadarWebNGWeb.DashboardLive.Index.ObservabilityPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.DashboardLive.Index.Common
  alias ServiceRadarWebNGWeb.DashboardLive.Index.EventsPanel
  alias ServiceRadarWebNGWeb.DashboardLive.Index.MetricsPanel

  attr(:dashboard, :map, required: true)

  def render(assigns) do
    ~H"""
    <Common.panel title="Observability" class="sr-ops-span-full lg:col-span-12">
      <div class="sr-ops-observability-split" data-testid="observability-split">
        <section class="sr-ops-observability-pane" aria-label="Observability metrics">
          <h3>Metrics</h3>
          <MetricsPanel.render dashboard={@dashboard} embedded />
        </section>
        <section class="sr-ops-observability-pane" aria-label="Events over time">
          <EventsPanel.render dashboard={@dashboard} embedded />
        </section>
      </div>
    </Common.panel>
    """
  end
end
