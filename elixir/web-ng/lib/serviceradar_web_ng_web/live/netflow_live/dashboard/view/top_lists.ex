defmodule ServiceRadarWebNGWeb.NetflowLive.Dashboard.View.TopLists do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.FlowStatComponents
  import ServiceRadarWebNGWeb.NetflowLive.Dashboard.Helpers
  import ServiceRadarWebNGWeb.NetflowLive.Dashboard.IpFormat

  attr(:dashboard, :map, required: true)

  def render(%{dashboard: dashboard} = assigns) do
    assigns = Map.merge(assigns, dashboard)

    ~H"""
    <%!-- Top-N and chart panels --%>
    <div
      :if={section_visible?(@section, "topn") or section_visible?(@section, "traffic")}
      class="grid grid-cols-1 lg:grid-cols-2 gap-4"
    >
      <.top_n_table
        :if={section_visible?(@section, "topn")}
        title="Top Talkers (Source IPs)"
        rows={@top_talkers}
        columns={[
          %{
            key: :ip,
            label: "Source IP",
            format: &format_enriched_ip(&1.ip, @rdns_map, @geo_iso2_map)
          },
          %{
            key: :bytes,
            label: primary_metric_col_label(@unit_mode, @metric_mode),
            format:
              &format_primary_cell(
                &1,
                @unit_mode,
                @metric_mode,
                @covered_span_seconds
              )
          },
          %{key: :packets, label: "Packets"}
        ]}
        on_row_click="drill_down_talker"
        loading={@loading}
      />

      <.top_n_table
        :if={section_visible?(@section, "topn")}
        title="Top Listeners (Dest IPs)"
        rows={@top_listeners}
        columns={[
          %{
            key: :ip,
            label: "Dest IP",
            format: &format_enriched_ip(&1.ip, @rdns_map, @geo_iso2_map)
          },
          %{
            key: :bytes,
            label: primary_metric_col_label(@unit_mode, @metric_mode),
            format:
              &format_primary_cell(
                &1,
                @unit_mode,
                @metric_mode,
                @covered_span_seconds
              )
          },
          %{key: :packets, label: "Packets"}
        ]}
        on_row_click="drill_down_listener"
        loading={@loading}
      />

      <.top_n_table
        :if={section_visible?(@section, "topn")}
        title="Top Conversations"
        rows={@top_conversations}
        columns={[
          %{
            key: :src_ip,
            label: "Source",
            format: &format_enriched_ip(&1.src_ip, @rdns_map, @geo_iso2_map)
          },
          %{
            key: :dst_ip,
            label: "Dest",
            format: &format_enriched_ip(&1.dst_ip, @rdns_map, @geo_iso2_map)
          },
          %{
            key: :bytes,
            label: primary_metric_col_label(@unit_mode, @metric_mode),
            format:
              &format_primary_cell(
                &1,
                @unit_mode,
                @metric_mode,
                @covered_span_seconds
              )
          }
        ]}
        on_row_click="drill_down_conversation"
        loading={@loading}
      />

      <.top_n_table
        :if={section_visible?(@section, "topn")}
        title="Top Applications"
        rows={@top_apps}
        columns={[
          %{key: :app, label: "Application"},
          %{
            key: :bytes,
            label: primary_metric_col_label(@unit_mode, @metric_mode),
            format:
              &format_primary_cell(
                &1,
                @unit_mode,
                @metric_mode,
                @covered_span_seconds
              )
          },
          %{key: :packets, label: "Packets"}
        ]}
        on_row_click="drill_down_app"
        loading={@loading}
      />

      <.top_n_table
        :if={section_visible?(@section, "topn")}
        title="Top Protocols"
        rows={@top_protocols}
        columns={[
          %{key: :protocol, label: "Protocol"},
          %{
            key: :bytes,
            label: primary_metric_col_label(@unit_mode, @metric_mode),
            format:
              &format_primary_cell(
                &1,
                @unit_mode,
                @metric_mode,
                @covered_span_seconds
              )
          },
          %{key: :packets, label: "Packets"}
        ]}
        on_row_click="drill_down_protocol"
        loading={@loading}
      />

      <.top_n_table
        :if={section_visible?(@section, "topn")}
        title="Top Ports (Destination)"
        rows={@top_ports}
        columns={[
          %{key: :port, label: "Port", format: &format_port_cell/1},
          %{
            key: :bytes,
            label: primary_metric_col_label(@unit_mode, @metric_mode),
            format:
              &format_primary_cell(
                &1,
                @unit_mode,
                @metric_mode,
                @covered_span_seconds
              )
          },
          %{key: :packets, label: "Packets"}
        ]}
        on_row_click="drill_down_port"
        loading={@loading}
      />
    </div>
    """
  end
end
