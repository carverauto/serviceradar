defmodule ServiceRadarWebNGWeb.NetflowLive.Dashboard.View.Capacity do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.FlowStatComponents
  import ServiceRadarWebNGWeb.NetflowLive.Dashboard.Helpers

  attr(:dashboard, :map, required: true)

  def render(%{dashboard: dashboard} = assigns) do
    assigns = Map.merge(assigns, dashboard)

    ~H"""
    <%!-- Interface utilization section --%>
    <div
      :if={
        section_visible?(@section, "capacity") and
          (@top_interfaces != [] or @subnet_distribution != [])
      }
      class="space-y-4"
    >
      <h2 class="text-sm font-bold text-sr-ink uppercase tracking-wide">
        Interface Utilization
      </h2>

      <%!-- Interface bandwidth gauges --%>
      <div :if={@top_interfaces != []} class="grid grid-cols-2 lg:grid-cols-5 gap-3">
        <.bandwidth_gauge
          :for={{iface, idx} <- Enum.with_index(@top_interfaces)}
          :if={iface.capacity_bps > 0}
          id={"iface-gauge-#{idx}"}
          current_bps={iface.bytes / @covered_span_seconds * 8}
          capacity_bps={iface.capacity_bps * 1.0}
          label={iface.label}
          rate_kind="avg"
        />
      </div>

      <%!-- Top interfaces table (always shown) --%>
      <.top_n_table
        title="Top Interfaces by Traffic"
        rows={@top_interfaces}
        columns={[
          %{key: :label, label: "Interface"},
          %{key: :sampler, label: "Exporter"},
          %{
            key: :bytes,
            label: unit_suffix(@unit_mode),
            format: &format_bytes_cell(&1, @unit_mode, @covered_span_seconds)
          },
          %{
            key: :p95_bps,
            label: "95th %-ile (#{time_window_label(@time_window)})",
            format: &format_p95_cell/1
          },
          %{key: :capacity_bps, label: "Capacity", format: &format_capacity_cell/1}
        ]}
        loading={@loading}
      />

      <%!-- Subnet / VLAN distribution --%>
      <.top_n_table
        :if={@subnet_distribution != []}
        title="Subnet Traffic Distribution"
        rows={@subnet_distribution}
        columns={[
          %{key: :label, label: "Subnet"},
          %{key: :cidr, label: "CIDR"},
          %{
            key: :bytes,
            label: unit_suffix(@unit_mode),
            format: &format_bytes_cell(&1, @unit_mode, @covered_span_seconds)
          }
        ]}
        loading={@loading}
      />
    </div>
    """
  end
end
