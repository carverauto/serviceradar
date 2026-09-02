defmodule ServiceRadarWebNGWeb.NetflowLive.Dashboard.View.Traffic do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.FlowStatComponents
  import ServiceRadarWebNGWeb.NetflowLive.Dashboard.Helpers

  attr(:dashboard, :map, required: true)

  def render(%{dashboard: dashboard} = assigns) do
    assigns = Map.merge(assigns, dashboard)

    ~H"""
    <%!-- Per-interface ingress/egress chart --%>
    <div
      :if={section_visible?(@section, "traffic") and @top_interfaces != []}
      class="rounded-xl border border-sr-line bg-sr-surface p-4"
    >
      <div class="flex items-center justify-between mb-3">
        <div class="flex items-center gap-2">
          <.icon name="hero-arrows-right-left" class="size-4 text-sr-brand" />
          <span class="text-sm font-semibold">Interface Traffic (Ingress vs Egress)</span>
        </div>
        <form phx-change="select_interface">
          <select name="interface" class={ui_field_class(size: "xs")}>
            <option value="">Select interface...</option>
            <option
              :for={iface <- @top_interfaces}
              value={iface.key}
              selected={iface.key == @selected_interface}
            >
              {iface.label} ({iface.sampler} if{iface.if_index})
            </option>
          </select>
        </form>
      </div>
      <%= if @selected_interface && @iface_chart_points_json != "[]" do %>
        <div
          id={"iface-ingress-egress-#{@selected_interface}"}
          class="w-full"
          style="height: 220px"
          phx-hook="NetflowStackedAreaChart"
          data-units={@unit_mode}
          data-keys={@iface_chart_keys_json}
          data-points={@iface_chart_points_json}
          data-timezone={@timezone}
          data-colors={Jason.encode!(%{"ingress" => "#3b82f6", "egress" => "#f59e0b"})}
          data-overlays="[]"
        >
          <svg class="w-full h-full"></svg>
        </div>
      <% else %>
        <div class="flex items-center justify-center py-8 text-sm text-sr-muted">
          <%= if @selected_interface do %>
            No traffic data for this interface.
          <% else %>
            Select an interface to view ingress/egress traffic.
          <% end %>
        </div>
      <% end %>
    </div>

    <div
      :if={section_visible?(@section, "traffic")}
      class="grid grid-cols-1 lg:grid-cols-2 gap-4"
    >
      <div
        :if={section_visible?(@section, "traffic")}
        class="rounded-xl border border-sr-line bg-sr-surface p-4"
      >
        <h3 class="text-sm font-semibold text-sr-ink mb-2">Protocol Distribution</h3>
        <div :if={@loading} class="flex items-center justify-center py-8">
          <.ui_spinner size="md" />
        </div>
        <.protocol_breakdown
          :if={not @loading}
          id="dashboard-proto-breakdown"
          data_json={@proto_breakdown_json}
          height={180}
        />
      </div>

      <div
        :if={section_visible?(@section, "traffic")}
        class="rounded-xl border border-sr-line bg-sr-surface p-4"
      >
        <h3 class="text-sm font-semibold text-sr-ink mb-2">TCP Flag Distribution</h3>
        <div :if={@loading} class="flex items-center justify-center py-8">
          <.ui_spinner size="md" />
        </div>
        <.protocol_breakdown
          :if={not @loading}
          id="dashboard-tcp-flags"
          data_json={@tcp_flags_json}
          height={180}
        />
      </div>

      <div
        :if={section_visible?(@section, "traffic")}
        class="rounded-xl border border-sr-line bg-sr-surface p-4"
      >
        <h3 class="text-sm font-semibold text-sr-ink mb-2">Flow Rate (flows/sec)</h3>
        <div :if={@loading} class="flex items-center justify-center py-8">
          <.ui_spinner size="md" />
        </div>
        <div
          :if={not @loading}
          id="flow-rate-chart"
          phx-hook="FlowRateChart"
          data-points={@flow_rate_points_json}
          data-timezone={@timezone}
          data-color="oklch(0.65 0.24 150)"
          role="img"
          aria-label={"Flow rate chart; display zone #{@timezone}"}
          class="h-[180px] w-full"
        >
          <canvas></canvas>
        </div>
      </div>

      <div
        :if={section_visible?(@section, "traffic")}
        class="rounded-xl border border-sr-line bg-sr-surface p-4"
      >
        <h3 class="text-sm font-semibold text-sr-ink mb-2">Flow Duration Distribution</h3>
        <div :if={@loading} class="flex items-center justify-center py-8">
          <.ui_spinner size="md" />
        </div>
        <.protocol_breakdown
          :if={not @loading}
          id="dashboard-duration-dist"
          data_json={@duration_dist_json}
          height={180}
        />
      </div>
    </div>
    """
  end
end
