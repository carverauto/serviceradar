defmodule ServiceRadarWebNGWeb.DashboardLive.Index.ObservabilityPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.DashboardLive.Index.Common
  alias ServiceRadarWebNGWeb.DashboardLive.Index.EventsPanel
  alias ServiceRadarWebNGWeb.DashboardLive.Index.MetricsPanel
  alias ServiceRadarWebNGWeb.DashboardLive.Window

  attr(:dashboard, :map, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  def render(assigns) do
    dashboard = assigns.dashboard

    assigns =
      assigns
      |> assign(:events_window, Map.get(dashboard, :events_window, "last_24h"))
      |> assign(:window_errors, Map.get(dashboard, :window_errors, %{}))

    ~H"""
    <Common.panel title="Events Over Time" class="sr-ops-observability-panel">
      <:actions>
        <select
          id="dashboard-events-window"
          phx-hook="DashboardWindowSelect"
          data-window-kind="events"
          data-window={@events_window}
          class="sr-ops-select"
          aria-label="Events time window"
        >
          <option
            :for={{value, label} <- Window.options()}
            value={value}
            selected={value == @events_window}
          >
            {label}
          </option>
        </select>
      </:actions>
      <p :if={@window_errors["events"]} role="alert" class="p-3 text-sm text-sr-muted">
        {@window_errors["events"]}
      </p>
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
