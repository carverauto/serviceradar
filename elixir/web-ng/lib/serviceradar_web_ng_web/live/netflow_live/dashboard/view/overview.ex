defmodule ServiceRadarWebNGWeb.NetflowLive.Dashboard.View.Overview do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.FlowStatComponents
  import ServiceRadarWebNGWeb.NetflowLive.Dashboard.Helpers

  attr(:dashboard, :map, required: true)

  def render(%{dashboard: dashboard} = assigns) do
    assigns = Map.merge(assigns, dashboard)

    ~H"""
    <%!-- Overview section --%>
    <div :if={section_visible?(@section, "overview")} class="space-y-4">
      <div class="grid grid-cols-2 lg:grid-cols-4 gap-3">
        <.stat_card
          title={if @unit_mode == "pps", do: "Total Packets", else: "Total Bandwidth"}
          value={
            primary_metric(
              @total_bytes,
              @total_packets,
              @unit_mode,
              @covered_span_seconds
            )
          }
          unit={unit_suffix(@unit_mode)}
          loading={@loading}
        />
        <.stat_card
          title="Total Packets"
          value={@total_packets}
          unit="pps"
          loading={@loading}
        />
        <.stat_card
          title="Active Flows"
          value={@active_flows}
          loading={@loading}
        />
        <.stat_card
          title="Unique Talkers"
          value={@unique_talkers}
          loading={@loading}
        />
      </div>

      <%!-- Traffic over time sparkline --%>
      <div class="rounded-xl border border-sr-line bg-sr-surface p-4">
        <h3 class="text-sm font-semibold text-sr-ink mb-2">Traffic Over Time</h3>
        <div :if={@loading} class="flex items-center justify-center py-8">
          <.ui_spinner size="md" />
        </div>
        <.traffic_sparkline
          :if={not @loading}
          id="dashboard-traffic-sparkline"
          data_json={@sparkline_json}
          height={80}
        />
      </div>
    </div>
    """
  end
end
