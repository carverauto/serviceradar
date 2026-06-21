defmodule ServiceRadarWebNGWeb.DeviceLive.FlowComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.FlowStatComponents
  # ---------------------------------------------------------------------------
  # Flows Tab Content
  # ---------------------------------------------------------------------------

  attr(:flows, :list, required: true)
  attr(:error, :string, default: nil)
  attr(:pagination, :map, default: %{})
  attr(:rdns_map, :map, default: %{})
  attr(:geo_iso2_map, :map, default: %{})
  attr(:device_uid, :string, required: true)
  attr(:query, :string, required: true)
  attr(:limit, :integer, required: true)
  attr(:flow_stats, :map, default: %{})
  attr(:flow_stats_loading, :boolean, default: true)
  attr(:sparkline_json, :string, default: "[]")
  attr(:proto_json, :string, default: "[]")
  attr(:flow_chart_keys_json, :string, default: "[]")
  attr(:flow_chart_points_json, :string, default: "[]")
  attr(:top_talkers_json, :string, default: "[]")
  attr(:top_destinations_json, :string, default: "[]")
  # §37.3: canonical per-peer ranking (device's peers merged across both
  # directions). Renders as "Top Peers", replacing the direction-split widgets.
  attr(:top_peers_json, :string, default: "[]")
  attr(:top_ports_json, :string, default: "[]")
  attr(:top_protocols_json, :string, default: "[]")
  attr(:facets, :map, default: %{protocols: [], directions: [], services: []})
  attr(:active_facets, :map, default: %{})
  attr(:active_topn, :map, default: nil)
  attr(:zoom_range, :map, default: nil)

  def flows_tab_content(assigns) do
    max_bytes =
      assigns.flows
      |> Enum.map(&to_safe_number(Map.get(&1, "bytes_total")))
      |> Enum.max(fn -> 1 end)
      |> max(1)

    max_packets =
      assigns.flows
      |> Enum.map(&to_safe_number(Map.get(&1, "packets_total")))
      |> Enum.max(fn -> 1 end)
      |> max(1)

    assigns =
      assigns
      |> assign(:max_bytes, max_bytes)
      |> assign(:max_packets, max_packets)
      |> assign_new(:total_bw, fn ->
        bytes = Map.get(assigns.flow_stats, :total_bytes, 0)
        format_si(bytes * 8, unit: "bps")
      end)
      |> assign_new(:total_packets, fn ->
        format_si(Map.get(assigns.flow_stats, :total_packets, 0), unit: "pps")
      end)

    ~H"""
    <div class="space-y-4">
      <%!-- Stats overview row --%>
      <div class="grid grid-cols-2 lg:grid-cols-4 gap-3">
        <.stat_card
          title="Total Bandwidth"
          value={@total_bw}
          loading={@flow_stats_loading}
        >
          <:sparkline>
            <.traffic_sparkline
              id="device-flow-sparkline"
              data_json={@sparkline_json}
              height={28}
            />
          </:sparkline>
        </.stat_card>
        <.stat_card
          title="Total Packets"
          value={@total_packets}
          loading={@flow_stats_loading}
        />
        <.stat_card
          title="Active Flows"
          value={format_si(Map.get(@flow_stats, :flow_count, 0))}
          loading={@flow_stats_loading}
        />
        <.stat_card
          title="Unique Sources"
          value={format_si(Map.get(@flow_stats, :unique_talkers, 0))}
          loading={@flow_stats_loading}
        />
      </div>

      <%!-- Traffic Profile chart --%>
      <div
        :if={@flow_chart_points_json != "[]"}
        class="rounded-xl border border-base-200 bg-base-100 p-4"
      >
        <div class="flex items-center gap-2 mb-3">
          <.icon name="hero-chart-bar" class="size-4 text-primary" />
          <span class="text-sm font-semibold">Traffic Profile</span>
          <span class="text-xs text-base-content/50">(last 24h · drag to zoom)</span>
        </div>
        <div
          id="device-flow-traffic-profile"
          class="w-full"
          style="height: 220px"
          phx-hook="NetflowStackedAreaChart"
          data-units="bytes"
          data-keys={@flow_chart_keys_json}
          data-points={@flow_chart_points_json}
          data-colors={Jason.encode!(%{})}
          data-overlays="[]"
          data-zoomable="true"
        >
          <svg class="w-full h-full"></svg>
        </div>
      </div>

      <%!-- Top-N widgets --%>
      <div
        :if={
          @top_peers_json != "[]" or @top_ports_json != "[]" or
            @top_protocols_json != "[]"
        }
        class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-3"
      >
        <.top_n_widget
          :if={@top_peers_json != "[]"}
          title="Top Peers"
          icon="hero-user-group"
          items_json={@top_peers_json}
          filter_field="src_endpoint_ip"
        />
        <.top_n_widget
          :if={@top_ports_json != "[]"}
          title="Top Ports"
          icon="hero-hashtag"
          items_json={@top_ports_json}
          filter_field="dst_endpoint_port"
        />
        <.top_n_widget
          :if={@top_protocols_json != "[]"}
          title="Top Protocols"
          icon="hero-signal"
          items_json={@top_protocols_json}
          filter_field="proto"
        />
      </div>

      <%!-- Protocol breakdown --%>
      <div
        :if={@proto_json != "[]"}
        class="rounded-xl border border-base-200 bg-base-100 p-4"
      >
        <div class="flex items-center gap-2 mb-3">
          <.icon name="hero-chart-pie" class="size-4 text-primary" />
          <span class="text-sm font-semibold">Protocol Breakdown</span>
          <span class="text-xs text-base-content/50">(last 24h)</span>
        </div>
        <.protocol_breakdown id="device-proto-donut" data_json={@proto_json} height={180} />
      </div>

      <%!-- Quick filters / faceting --%>
      <div
        :if={@facets.protocols != [] or @facets.directions != [] or @facets.services != []}
        class="rounded-xl border border-base-200 bg-base-100 p-4"
      >
        <div class="flex items-center gap-2 mb-3">
          <.icon name="hero-funnel" class="size-4 text-primary" />
          <span class="text-sm font-semibold">Quick Filters</span>
          <button
            :if={@active_facets != %{}}
            phx-click="facet_clear"
            class="ml-auto text-xs text-error hover:underline"
          >
            Clear all
          </button>
        </div>
        <div class="flex flex-wrap gap-4">
          <.facet_group
            :if={@facets.protocols != []}
            label="Protocol"
            field="proto"
            items={@facets.protocols}
            active_facets={@active_facets}
          />
          <.facet_group
            :if={@facets.directions != []}
            label="Direction"
            field="direction_label"
            items={@facets.directions}
            active_facets={@active_facets}
          />
          <.facet_group
            :if={@facets.services != []}
            label="Service"
            field="dst_service_label"
            items={@facets.services}
            active_facets={@active_facets}
          />
        </div>
      </div>

      <%!-- Active filter indicators --%>
      <div
        :if={@zoom_range}
        class="flex items-center gap-2 px-3 py-2 rounded-lg bg-info/10 border border-info/20 text-sm"
      >
        <.icon name="hero-magnifying-glass-plus-solid" class="size-4 text-info" />
        <span class="text-base-content/70">Zoomed to</span>
        <span class="badge badge-info badge-sm font-mono">
          {String.slice(@zoom_range.start, 0, 19)}
        </span>
        <span class="text-base-content/50">&rarr;</span>
        <span class="badge badge-info badge-sm font-mono">
          {String.slice(@zoom_range.end, 0, 19)}
        </span>
        <button phx-click="clear_zoom" class="ml-auto btn btn-ghost btn-xs text-error">
          <.icon name="hero-x-mark-mini" class="size-3.5" /> Reset
        </button>
      </div>
      <div
        :if={@active_topn}
        class="flex items-center gap-2 px-3 py-2 rounded-lg bg-primary/10 border border-primary/20 text-sm"
      >
        <.icon name="hero-funnel-solid" class="size-4 text-primary" />
        <span class="text-base-content/70">Filtered by</span>
        <span class="font-semibold">{@active_topn.field}:</span>
        <span class="badge badge-primary badge-sm">{@active_topn.value}</span>
        <button phx-click="clear_topn_filter" class="ml-auto btn btn-ghost btn-xs text-error">
          <.icon name="hero-x-mark-mini" class="size-3.5" /> Clear
        </button>
      </div>

      <%!-- Flow table --%>
      <div class="rounded-xl border border-base-200 bg-base-100">
        <div class="px-4 py-3 border-b border-base-200 flex items-center justify-between gap-3">
          <div class="flex items-center gap-2">
            <.icon name="hero-arrows-right-left" class="size-4 text-primary" />
            <span class="text-sm font-semibold">Recent Flows</span>
            <span class="text-xs text-base-content/50">({length(@flows)} rows)</span>
          </div>
          <.link
            navigate={
              ~p"/observability?#{%{"tab" => "netflows", "view" => "explorer", "q" => @query}}"
            }
            class="text-xs text-primary hover:underline"
          >
            Open full flows view
          </.link>
        </div>

        <div class="p-4">
          <div :if={is_binary(@error)} class="mb-3 text-xs text-error">{@error}</div>

          <%= if @flows == [] and is_nil(@error) do %>
            <div class="text-sm text-base-content/60">No flows found for this device.</div>
          <% else %>
            <div class="overflow-x-auto">
              <table class="table table-xs w-full">
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
                  <%= for flow <- @flows do %>
                    <tr>
                      <td class="font-mono">{format_timestamp(flow_time(flow))}</td>
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
                          class="text-[10px] text-base-content/50 truncate max-w-[180px]"
                          title={src_host}
                        >
                          {src_host}
                        </div>
                        <div
                          :if={!src_host && flow_exporter_name(flow)}
                          class="text-[10px] text-base-content/50 truncate max-w-[140px]"
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
                          class="text-[10px] text-base-content/50 truncate max-w-[180px]"
                          title={dst_host}
                        >
                          {dst_host}
                        </div>
                        <div
                          :if={!dst_host && flow_service_label(flow)}
                          class="text-[10px] text-base-content/50 truncate max-w-[140px]"
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
                        <.link
                          navigate={
                            ~p"/observability/flows?#{%{"open" => "first", "q" => flow_drilldown_query(flow)}}"
                          }
                          class="btn btn-ghost btn-xs"
                        >
                          Details
                        </.link>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>

            <div class="pt-3 border-t border-base-200 mt-3">
              <.ui_pagination
                prev_cursor={Map.get(@pagination, "prev_cursor")}
                next_cursor={Map.get(@pagination, "next_cursor")}
                base_path={"/devices/#{@device_uid}"}
                query={@query}
                limit={@limit}
                result_count={length(@flows)}
                extra_params={%{"tab" => "flows"}}
              />
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Top-N Widget
  # ---------------------------------------------------------------------------

  attr(:title, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:items_json, :string, required: true)
  attr(:filter_field, :string, required: true)

  defp top_n_widget(assigns) do
    items =
      case Jason.decode(assigns.items_json) do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    max_value = items |> Enum.map(&Map.get(&1, "value", 0)) |> Enum.max(fn -> 1 end)

    items =
      Enum.map(items, fn item ->
        pct = min(100, round(Map.get(item, "value", 0) / max(1, max_value) * 100))
        Map.put(item, "pct", pct)
      end)

    assigns = assign(assigns, items: items)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 p-4">
      <div class="flex items-center gap-2 mb-3">
        <.icon name={@icon} class="size-4 text-primary" />
        <span class="text-sm font-semibold">{@title}</span>
        <span class="text-xs text-base-content/50">(last 24h)</span>
      </div>
      <div class="space-y-1.5">
        <button
          :for={item <- @items}
          type="button"
          class="w-full text-left group"
          phx-click="topn_filter"
          phx-value-field={@filter_field}
          phx-value-value={item["filter_value"] || item["label"]}
        >
          <div class="flex items-center justify-between text-xs">
            <span class="font-mono truncate max-w-[60%] group-hover:text-primary transition-colors">
              {item["label"]}
            </span>
            <span class="text-base-content/60">{format_bytes(item["value"])}</span>
          </div>
          <div class="w-full bg-base-200 rounded-full h-1 mt-0.5">
            <div
              class="bg-primary/40 group-hover:bg-primary/60 h-1 rounded-full transition-colors"
              style={"width: #{item["pct"]}%"}
            >
            </div>
          </div>
        </button>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Facet Group (clickable filter chips)
  # ---------------------------------------------------------------------------

  attr(:label, :string, required: true)
  attr(:field, :string, required: true)
  attr(:items, :list, required: true)
  attr(:active_facets, :map, required: true)

  defp facet_group(assigns) do
    active_value = Map.get(assigns.active_facets, assigns.field)
    assigns = assign(assigns, :active_value, active_value)

    ~H"""
    <div class="flex items-center gap-1.5">
      <span class="text-xs text-base-content/50 font-medium">{@label}:</span>
      <button
        :for={item <- @items}
        type="button"
        phx-click="facet_toggle"
        phx-value-field={@field}
        phx-value-value={Map.get(item, :filter_value) || item.label}
        class={[
          "badge badge-sm cursor-pointer transition-colors",
          if(@active_value == item.label,
            do: "badge-primary",
            else: "badge-ghost hover:badge-primary/20"
          )
        ]}
      >
        {item.label}
      </button>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Data Bar (relative bar behind numeric values)
  # ---------------------------------------------------------------------------

  attr(:value, :any, required: true)
  attr(:max, :any, required: true)
  attr(:label, :string, required: true)

  defp data_bar(assigns) do
    case_result =
      case assigns.value do
        n when is_number(n) -> n
        s when is_binary(s) -> flow_stat_number(%{"n" => s}, "n")
        _ -> 0
      end

    value = max(case_result, 0)

    case_result =
      case assigns.max do
        n when is_number(n) -> n
        s when is_binary(s) -> flow_stat_number(%{"n" => s}, "n")
        _ -> 0
      end

    maxv = max(case_result, 0)

    pct = if maxv > 0, do: min(100, round(value / maxv * 100)), else: 0
    assigns = assign(assigns, value: value, max: maxv, pct: pct)

    ~H"""
    <div class="relative inline-flex items-center justify-end w-full min-w-[60px]">
      <div
        class="absolute inset-y-0 right-0 bg-primary/10 rounded-sm"
        style={"width: #{@pct}%"}
      >
      </div>
      <span class="relative z-10">{@label}</span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Flow Interface Path (in_if → out_if)
  # ---------------------------------------------------------------------------

  attr(:flow, :map, required: true)

  defp flow_interface_path(assigns) do
    conn_info = get_in(assigns.flow, ["ocsf_payload", "connection_info"]) || %{}
    in_snmp = conn_info["input_snmp"]
    out_snmp = conn_info["output_snmp"]

    in_if = Map.get(assigns.flow, "in_if_name") || snmp_id_label(in_snmp)
    out_if = Map.get(assigns.flow, "out_if_name") || snmp_id_label(out_snmp)
    assigns = assign(assigns, in_if: in_if, out_if: out_if)

    ~H"""
    <span :if={@in_if || @out_if} class="inline-flex items-center gap-1 text-base-content/70">
      <span :if={@in_if} class="truncate max-w-[70px]" title={@in_if}>{@in_if}</span>
      <span :if={@in_if && @out_if} class="text-base-content/40">&rarr;</span>
      <span :if={@out_if} class="truncate max-w-[70px]" title={@out_if}>{@out_if}</span>
    </span>
    <span :if={!@in_if && !@out_if} class="text-base-content/30">—</span>
    """
  end

  defp snmp_id_label(nil), do: nil
  defp snmp_id_label(id) when is_integer(id), do: "if#{id}"
  defp snmp_id_label(id) when is_binary(id) and id != "", do: "if#{id}"
  defp snmp_id_label(_), do: nil

  defp flow_endpoint(flow, :src), do: Map.get(flow, "src_endpoint_ip") || "—"
  defp flow_endpoint(flow, :dst), do: Map.get(flow, "dst_endpoint_ip") || "—"

  defp iso2_flag_emoji(nil), do: nil

  defp iso2_flag_emoji(iso2) when is_binary(iso2) do
    iso2 = iso2 |> String.trim() |> String.upcase()

    if String.length(iso2) == 2 do
      <<a::utf8, b::utf8>> = iso2
      if a in ?A..?Z and b in ?A..?Z, do: <<0x1F1E6 + (a - ?A)::utf8, 0x1F1E6 + (b - ?A)::utf8>>
    end
  end

  defp iso2_flag_emoji(_), do: nil

  defp flow_protocol(flow) do
    protocol_label(Map.get(flow, "protocol_num"), Map.get(flow, "protocol_name"))
  end

  defp flow_service_label(flow) when is_map(flow) do
    case Map.get(flow, "dst_service_label") do
      service when is_binary(service) and service != "" -> service
      _ -> nil
    end
  end

  defp flow_exporter_name(flow) when is_map(flow) do
    case Map.get(flow, "exporter_name") do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp flow_format_number(nil), do: "—"
  defp flow_format_number(n) when is_number(n), do: format_si(n)
  defp flow_format_number(_), do: "—"

  defp flow_port(flow, :src) do
    case Map.get(flow, "src_endpoint_port") do
      port when is_integer(port) -> ":#{port}"
      _ -> ""
    end
  end

  defp flow_port(flow, :dst) do
    case Map.get(flow, "dst_endpoint_port") do
      port when is_integer(port) -> ":#{port}"
      _ -> ""
    end
  end

  defp flow_time(flow) do
    Map.get(flow, "time") || Map.get(flow, "timestamp")
  end

  defp flow_drilldown_query(flow) when is_map(flow) do
    tokens =
      ["in:flows", "time:last_24h"]
      |> maybe_add_flow_token("src_ip", Map.get(flow, "src_endpoint_ip"))
      |> maybe_add_flow_token("dst_ip", Map.get(flow, "dst_endpoint_ip"))
      |> maybe_add_flow_token("src_port", Map.get(flow, "src_endpoint_port"))
      |> maybe_add_flow_token("dst_port", Map.get(flow, "dst_endpoint_port"))
      |> maybe_add_flow_token("proto", Map.get(flow, "protocol_num"))
      |> Kernel.++(["sort:time:desc"])

    Enum.join(tokens, " ")
  end

  defp maybe_add_flow_token(tokens, _field, nil), do: tokens
  defp maybe_add_flow_token(tokens, _field, ""), do: tokens

  defp maybe_add_flow_token(tokens, field, value) do
    value = value |> to_string() |> String.trim()

    if value == "" do
      tokens
    else
      tokens ++ ["#{field}:#{flow_query_value(value)}"]
    end
  end

  defp flow_query_value(value) when is_binary(value) do
    if String.contains?(value, [" ", ":", "\""]) do
      ~s|"#{String.replace(value, "\"", "\\\"")}"|
    else
      value
    end
  end

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(value) do
    case parse_datetime(value) do
      {:ok, %DateTime{} = dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> "—"
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp parse_datetime(%NaiveDateTime{} = ndt) do
    DateTime.from_naive(ndt, "Etc/UTC")
  end

  defp parse_datetime(value) when is_binary(value), do: DateTime.from_iso8601(value)
  defp parse_datetime(_), do: {:error, :invalid_datetime}

  defp format_bytes(bytes) when is_number(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776 * 1.0, 1)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824 * 1.0, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576 * 1.0, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024 * 1.0, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "—"

  defp protocol_label(protocol_num, protocol_name) do
    case parse_protocol_num(protocol_num) do
      1 -> "ICMP"
      6 -> "TCP"
      17 -> "UDP"
      47 -> "GRE"
      50 -> "ESP"
      51 -> "AH"
      58 -> "ICMPv6"
      89 -> "OSPF"
      132 -> "SCTP"
      n when is_integer(n) -> normalized_protocol_name(protocol_name) || "proto #{n}"
      nil -> normalized_protocol_name(protocol_name) || "unknown"
    end
  end

  defp parse_protocol_num(n) when is_integer(n), do: n

  defp parse_protocol_num(n) when is_binary(n) do
    case Integer.parse(String.trim(n)) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp parse_protocol_num(_), do: nil

  defp normalized_protocol_name(name) when is_binary(name) do
    name = String.trim(name)
    if name == "", do: nil, else: String.upcase(name)
  end

  defp normalized_protocol_name(_), do: nil

  defp flow_stat_field(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(payload, key)
  end

  defp flow_stat_number(payload, key) do
    case flow_stat_field(payload, key) do
      n when is_number(n) ->
        n

      s when is_binary(s) ->
        case Float.parse(s) do
          {f, _} -> f
          :error -> 0
        end

      _ ->
        0
    end
  end

  defp to_safe_number(n) when is_number(n), do: n
  defp to_safe_number(nil), do: 0

  defp to_safe_number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0
    end
  end

  defp to_safe_number(_), do: 0
end
