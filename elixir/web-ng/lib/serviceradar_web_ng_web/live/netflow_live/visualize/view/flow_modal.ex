defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowModal do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowAccess
  import ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowContext, only: [netflow_map_markers: 2]
  import ServiceRadarWebNGWeb.NetflowLive.Visualize.Format

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.BgpSection
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowModal.Endpoints
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowModal.SecurityPanel

  attr(:flow, :map, required: true)
  attr(:rdns_map, :map, default: %{})
  attr(:context, :map, default: %{})
  attr(:arin_lookup, :any, default: nil)
  attr(:timezone, :string, default: "Etc/UTC")

  def render(assigns) do
    ~H"""
    <dialog
      id="netflow-visualize-flow-details-modal"
      class="sr-ui-modal sr-ui-modal-open"
      phx-hook="DialogTopLayer"
      data-cancel="netflow_close"
      phx-window-keydown="netflow_close"
      phx-key="escape"
    >
      <div class="sr-ui-modal-box sr-ui-modal-box-xl">
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <div class="text-sm font-semibold">Flow details</div>
            <div class="mt-1 text-[11px] text-sr-muted font-mono truncate">
              <.user_time
                id="netflow-flow-detail-time"
                value={flow_get(@flow, ["time", "timestamp"])}
                timezone={@timezone}
                fallback="—"
              />
            </div>
          </div>
          <.ui_button type="button" phx-click="netflow_close" size="sm" variant="ghost">
            Close
          </.ui_button>
        </div>

        <% ocsf = flow_get(@flow, ["ocsf_payload"]) || %{} %>
        <% direction_label =
          flow_get(@flow, ["direction_label"]) || flow_get_in(ocsf, ["enrichment", "direction_label"]) %>
        <% service_label =
          flow_get(@flow, ["dst_service_label"]) ||
            flow_get_in(ocsf, ["enrichment", "dst_service_label"]) %>
        <% tcp_flags_labels =
          flow_get(@flow, ["tcp_flags_labels"]) ||
            flow_get_in(ocsf, ["enrichment", "tcp_flags_labels"]) %>
        <% tcp_flags_labels =
          if is_list(tcp_flags_labels),
            do: Enum.map(tcp_flags_labels, &to_string/1),
            else: [] %>
        <% protocol_num = flow_get(@flow, ["protocol_num"]) %>
        <% tcp_flags_raw = flow_get(@flow, ["tcp_flags"]) %>
        <% protocol_label =
          flow_get(@flow, ["protocol_name", "protocol_group", "proto"]) ||
            get_in(ocsf, ["connection_info", "protocol_name"]) %>
        <% sampler =
          flow_get(@flow, ["sampler_address"]) ||
            flow_get_in(ocsf, ["observables"])
            |> case do
              [%{} = first | _] -> flow_get(first, ["value"]) || flow_get(first, ["name"])
              _ -> nil
            end %>
        <% mapbox = Map.get(@context, :mapbox) %>
        <% map_markers = netflow_map_markers(@context, @flow) %>

        <div class="mt-4 grid grid-cols-1 gap-3 lg:grid-cols-3">
          <div class="space-y-3 lg:col-span-2">
            <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
              <Endpoints.render flow={@flow} context={@context} rdns_map={@rdns_map} />

              <div class="p-2 rounded-lg border border-sr-line bg-sr-subtle/30">
                <div class="text-xs uppercase tracking-wider text-sr-muted">Protocol</div>
                <% src_port = flow_get(@flow, ["src_endpoint_port", "src_port"]) %>
                <% dst_port = flow_get(@flow, ["dst_endpoint_port", "dst_port"]) %>
                <% flag_set = MapSet.new(Enum.map(tcp_flags_labels, &String.upcase(to_string(&1)))) %>
                <% is_tcp =
                  (is_binary(protocol_label) and String.upcase(protocol_label) == "TCP") or
                    protocol_num == 6 %>
                <div class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 font-mono text-xs">
                  <.ui_badge size="xs" variant="outline">{protocol_label || "Unknown"}</.ui_badge>
                  <span :if={not is_nil(protocol_num)} class="text-sr-muted">
                    proto {protocol_num}
                  </span>
                  <span class="text-sr-muted">{src_port || "—"} → {dst_port || "—"}</span>
                </div>
                <div :if={is_tcp} class="mt-1 rounded border border-sr-line bg-sr-surface/60 p-1.5">
                  <div class="text-[10px] uppercase tracking-wide text-sr-muted">
                    TCP Flags
                  </div>
                  <div class="mt-1 flex flex-wrap gap-1">
                    <%= for flag <- ["CWR", "ECE", "URG", "ACK", "PSH", "RST", "SYN", "FIN"] do %>
                      <% active = MapSet.member?(flag_set, flag) %>
                      <span class="sr-ui-tooltip sr-ui-tooltip-top" data-tip={tcp_flag_tooltip(flag)}>
                        <span class={[
                          "inline-flex h-5 min-w-6 items-center justify-center rounded border px-1 text-[10px] font-mono cursor-help",
                          if(active,
                            do: "border-sr-brand bg-sr-brand/15 text-sr-brand",
                            else: "border-sr-line text-sr-muted"
                          )
                        ]}>
                          {flag}
                        </span>
                      </span>
                    <% end %>
                  </div>
                  <div
                    :if={not is_nil(tcp_flags_raw) and tcp_flags_labels == []}
                    class="mt-1 text-[10px] text-sr-muted"
                  >
                    raw mask: <span class="font-mono">{tcp_flags_raw}</span>
                  </div>
                </div>
                <div class="mt-1 text-[10px] text-sr-muted space-y-0.5">
                  <div :if={is_binary(direction_label) and direction_label != ""}>
                    direction: <span class="font-mono">{direction_label}</span>
                  </div>
                  <div :if={is_binary(service_label) and service_label != ""}>
                    dst_service: <span class="font-mono">{service_label}</span>
                  </div>
                  <div :if={dir = get_in(ocsf, ["connection_info", "direction_id"])}>
                    direction_id: <span class="font-mono">{dir}</span>
                  </div>
                  <div :if={bid = get_in(ocsf, ["connection_info", "boundary_id"])}>
                    boundary_id: <span class="font-mono">{bid}</span>
                  </div>
                </div>
              </div>

              <div class="p-3 rounded-lg border border-sr-line bg-sr-subtle/30">
                <div class="text-xs uppercase tracking-wider text-sr-muted">Volume</div>
                <div class="mt-1 font-mono text-sm">
                  packets:{flow_get(@flow, ["packets_total", "packets"]) || "—"} bytes:{flow_get(
                    @flow,
                    [
                      "bytes_total",
                      "bytes"
                    ]
                  ) || "—"}
                </div>
                <div class="mt-1 text-[11px] text-sr-muted space-y-0.5">
                  <div :if={bytes_in = flow_get(@flow, ["bytes_in"])}>
                    bytes_in: <span class="font-mono">{bytes_in}</span>
                  </div>
                  <div :if={bytes_out = flow_get(@flow, ["bytes_out"])}>
                    bytes_out: <span class="font-mono">{bytes_out}</span>
                  </div>
                  <div :if={s = sampler}>sampler: <span class="font-mono">{s}</span></div>
                  <div :if={ft = get_in(ocsf, ["unmapped", "flow_type"])}>
                    flow_type: <span class="font-mono">{ft}</span>
                  </div>
                </div>
              </div>

              <!-- BGP Information Section -->
              <div class="p-3 rounded-lg border border-sr-line bg-sr-subtle/30 md:col-span-2">
                <BgpSection.render flow={@flow} />
              </div>

              <div class="p-3 rounded-lg border border-sr-line bg-sr-subtle/30 md:col-span-2">
                <div class="text-xs uppercase tracking-wider text-sr-muted">Map</div>

                <%= if mapbox && mapbox.enabled &&
                      is_binary(Map.get(mapbox, :access_token)) &&
                      String.trim(Map.get(mapbox, :access_token)) != "" do %>
                  <div class="mt-2 rounded-lg overflow-hidden border border-sr-line bg-sr-subtle/30">
                    <div
                      id="netflow-flow-map"
                      class="relative h-72 w-full"
                      style="min-height:18rem"
                      phx-hook="MapboxFlowMap"
                      phx-update="ignore"
                      data-enabled="true"
                      data-access-token={Map.get(mapbox, :access_token) || ""}
                      data-style-light={
                        Map.get(mapbox, :style_light) || "mapbox://styles/mapbox/light-v11"
                      }
                      data-style-dark={
                        Map.get(mapbox, :style_dark) || "mapbox://styles/mapbox/dark-v11"
                      }
                      data-markers={Jason.encode!(map_markers)}
                    >
                    </div>
                  </div>
                  <div class="mt-1 text-xs text-sr-muted">
                    <%= if map_markers != [] do %>
                      Tip: click markers for details.
                    <% else %>
                      No GeoIP coordinates or local-CIDR anchor for this flow yet (showing default map).
                    <% end %>
                  </div>
                <% else %>
                  <div class="mt-2 text-sm text-sr-muted">
                    Mapbox is disabled or no GeoIP coordinates are available for this flow.
                  </div>
                <% end %>
              </div>
            </div>

            <details class="mt-1">
              <summary class="cursor-pointer text-xs text-sr-muted">Raw fields</summary>
              <pre class="mt-2 text-[11px] leading-snug whitespace-pre-wrap bg-sr-subtle/30 border border-sr-line rounded-lg p-3 font-mono"><%= inspect(@flow, pretty: true, limit: :infinity) %></pre>
            </details>
          </div>

          <SecurityPanel.render context={@context} arin_lookup={@arin_lookup || %{}} />
        </div>
      </div>
      <form method="dialog" class="sr-ui-modal-backdrop">
        <button phx-click="netflow_close">close</button>
      </form>
    </dialog>
    """
  end
end
