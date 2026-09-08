defmodule ServiceRadarWebNGWeb.DeviceLive.FlowComponents.Table do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DeviceLive.FlowComponents.Formatters
  import ServiceRadarWebNGWeb.DeviceLive.FlowComponents.Widgets

  attr(:flows, :list, required: true)
  attr(:error, :string, default: nil)
  attr(:pagination, :map, default: %{})
  attr(:pagination_page, :integer, default: 1)
  attr(:rdns_map, :map, default: %{})
  attr(:geo_iso2_map, :map, default: %{})
  attr(:device_uid, :string, required: true)
  attr(:query, :string, required: true)
  attr(:limit, :integer, required: true)
  attr(:max_bytes, :any, required: true)
  attr(:max_packets, :any, required: true)
  attr(:timezone, :string, required: true)

  def flow_table(assigns) do
    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line flex items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <.icon name="hero-arrows-right-left" class="size-4 text-sr-brand" />
          <span class="text-sm font-semibold">Recent Flows</span>
          <span class="text-xs text-sr-muted">({length(@flows)} rows)</span>
        </div>
        <.link
          navigate={~p"/observability/netflows?#{%{"view" => "explorer", "q" => @query}}"}
          class="text-xs text-sr-brand hover:underline"
        >
          Open full flows view
        </.link>
      </div>

      <div class="p-4">
        <div :if={is_binary(@error)} class="mb-3 flex items-center gap-2 text-xs text-error">
          <span>{@error}</span>
          <.ui_button
            type="button"
            phx-click="switch_tab"
            phx-value-tab="flows"
            size="xs"
            variant="outline"
          >
            Retry
          </.ui_button>
        </div>

        <%= if @flows == [] and is_nil(@error) do %>
          <div class="text-sm text-sr-muted">No flows found for this device.</div>
        <% else %>
          <div class="sr-ui-table-shell">
            <table class={ui_table_class(size: "xs", class: "w-full")}>
              <thead>
                <tr>
                  <th>Time</th>
                  <th>Source</th>
                  <th>Destination</th>
                  <th class="text-right">Proto</th>
                  <th>Interface Path</th>
                  <th class="text-right">Packets</th>
                  <th class="text-right">Bytes</th>
                  <th class="text-right"></th>
                </tr>
              </thead>
              <tbody>
                <%= for {flow, idx} <- Enum.with_index(@flows) do %>
                  <tr>
                    <td class="font-mono">
                      <.user_time
                        id={"device-flow-row-time-#{idx}"}
                        value={flow_time(flow)}
                        timezone={@timezone}
                        style={:compact}
                      />
                    </td>
                    <td class="font-mono">
                      <% src_ip = flow_endpoint(flow, :src) %>
                      <% src_cc = Map.get(@geo_iso2_map, src_ip) %>
                      <% src_host = Map.get(@rdns_map, src_ip) %>
                      <div>
                        <span :if={src_cc}>{iso2_flag_emoji(src_cc)} </span>{src_ip}{flow_port(
                          flow,
                          :src
                        )}
                      </div>
                      <div
                        :if={src_host}
                        class="text-[10px] text-sr-muted truncate max-w-[180px]"
                        title={src_host}
                      >
                        {src_host}
                      </div>
                      <div
                        :if={!src_host && flow_exporter_name(flow)}
                        class="text-[10px] text-sr-muted truncate max-w-[140px]"
                      >
                        {flow_exporter_name(flow)}
                      </div>
                    </td>
                    <td class="font-mono">
                      <% dst_ip = flow_endpoint(flow, :dst) %>
                      <% dst_cc = Map.get(@geo_iso2_map, dst_ip) %>
                      <% dst_host = Map.get(@rdns_map, dst_ip) %>
                      <div>
                        <span :if={dst_cc}>{iso2_flag_emoji(dst_cc)} </span>{dst_ip}{flow_port(
                          flow,
                          :dst
                        )}
                      </div>
                      <div
                        :if={dst_host}
                        class="text-[10px] text-sr-muted truncate max-w-[180px]"
                        title={dst_host}
                      >
                        {dst_host}
                      </div>
                      <div
                        :if={!dst_host && flow_service_label(flow)}
                        class="text-[10px] text-sr-muted truncate max-w-[140px]"
                      >
                        {flow_service_label(flow)}
                      </div>
                    </td>
                    <td class="text-right font-mono">
                      {flow_protocol(flow)}
                    </td>
                    <td class="font-mono text-xs">
                      <.flow_interface_path flow={flow} />
                    </td>
                    <td class="text-right font-mono">
                      <.data_bar
                        value={to_safe_number(Map.get(flow, "packets_total"))}
                        max={@max_packets}
                        label={flow_format_number(Map.get(flow, "packets_total"))}
                      />
                    </td>
                    <td class="text-right font-mono">
                      <.data_bar
                        value={to_safe_number(Map.get(flow, "bytes_total"))}
                        max={@max_bytes}
                        label={format_bytes(Map.get(flow, "bytes_total"))}
                      />
                    </td>
                    <td class="text-right">
                      <.ui_button
                        navigate={
                          ~p"/observability/flows?#{%{"open" => "first", "q" => flow_drilldown_query(flow)}}"
                        }
                        size="xs"
                        variant="ghost"
                      >
                        Details
                      </.ui_button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <div class="pt-3 border-t border-sr-line mt-3">
            <.ui_pagination
              prev_cursor={Map.get(@pagination, "prev_cursor")}
              next_cursor={Map.get(@pagination, "next_cursor")}
              limit={@limit}
              current_page={@pagination_page}
              result_count={length(@flows)}
            />
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
