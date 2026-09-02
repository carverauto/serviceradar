defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowsTable do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.Filters, only: [flows_filter_patch: 6]
  import ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowAccess
  import ServiceRadarWebNGWeb.NetflowLive.Visualize.Format

  alias ServiceRadarWebNGWeb.Components.PrefixTagChips

  attr(:flows, :list, default: [])
  attr(:rdns_map, :map, default: %{})
  attr(:geo_iso2_map, :map, default: %{})
  attr(:base_path, :string, required: true)
  attr(:query, :string, required: true)
  attr(:limit, :integer, required: true)
  attr(:nf_param, :string, default: nil)
  attr(:unit_mode, :string, default: "Bps")
  attr(:timezone, :string, default: "Etc/UTC")

  def render(assigns) do
    ~H"""
    <div class="w-full">
      <table class={ui_table_class(size: "sm", zebra: true, fixed: true, class: "w-full")}>
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-32">
              Time
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Source
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Destination
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-20 text-right">
              Proto
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-16 text-right">
              Source
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-28 text-right">
              Attribution
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-28 text-right">
              {flows_table_traffic_header(@unit_mode)}
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-10 text-right">
            </th>
          </tr>
        </thead>
        <tbody>
          <%= for {flow, idx} <- Enum.with_index(@flows) do %>
            <% src_ip = flow_get(flow, ["src_endpoint_ip", "src_ip"]) %>
            <% dst_ip = flow_get(flow, ["dst_endpoint_ip", "dst_ip"]) %>
            <% src_port = flow_get(flow, ["src_endpoint_port"]) %>
            <% dst_port = flow_get(flow, ["dst_endpoint_port", "dst_port"]) %>
            <% src_cc = flow_get(flow, ["src_country_iso2"]) || Map.get(@geo_iso2_map, src_ip) %>
            <% dst_cc = flow_get(flow, ["dst_country_iso2"]) || Map.get(@geo_iso2_map, dst_ip) %>
            <% row_time_id = flow_row_time_id(flow, idx) %>

            <tr class="hover:bg-sr-subtle/40">
              <% t_raw = flow_get(flow, ["time", "timestamp"]) %>
              <td class="whitespace-nowrap text-xs font-mono truncate overflow-hidden">
                <.user_time
                  id={row_time_id}
                  value={t_raw}
                  timezone={@timezone}
                  style={:time}
                  fallback={t_raw || "—"}
                />
              </td>
              <td class="text-xs font-mono min-w-0">
                <div class="min-w-0">
                  <div class="flex items-baseline gap-1 min-w-0">
                    <span
                      :if={is_binary(src_cc) and String.length(src_cc) == 2}
                      class="inline-block align-middle text-sm leading-none shrink-0"
                      title={src_cc}
                    >
                      {iso2_flag_emoji(src_cc)}
                    </span>
                    <.link
                      :if={is_binary(src_ip) and String.trim(src_ip) != ""}
                      patch={
                        flows_filter_patch(@base_path, @query, @limit, @nf_param, "src_ip", src_ip)
                      }
                      class="hover:underline min-w-0 truncate"
                      title={src_ip}
                    >
                      {src_ip}
                    </.link>
                    <span
                      :if={not (is_binary(src_ip) and String.trim(src_ip) != "")}
                      class="min-w-0 truncate"
                    >
                      {src_ip || "—"}
                    </span>
                    <span class="shrink-0 text-sr-muted">
                      {if src_port, do: ":#{src_port}", else: ""}
                    </span>
                  </div>
                  <div
                    :if={hostname = Map.get(@rdns_map, src_ip)}
                    class="mt-0.5 text-[11px] text-sr-muted truncate font-mono"
                    title={hostname}
                  >
                    {hostname}
                  </div>
                  <PrefixTagChips.linked items={
                    linked_prefix_tag_items(
                      flow_prefix_tags(flow, :src),
                      @base_path,
                      @query,
                      @limit,
                      @nf_param
                    )
                  } />
                </div>
              </td>
              <td class="text-xs font-mono min-w-0">
                <div class="min-w-0">
                  <div class="flex items-baseline gap-1 min-w-0">
                    <span
                      :if={is_binary(dst_cc) and String.length(dst_cc) == 2}
                      class="inline-block align-middle text-sm leading-none shrink-0"
                      title={dst_cc}
                    >
                      {iso2_flag_emoji(dst_cc)}
                    </span>
                    <.link
                      :if={is_binary(dst_ip) and String.trim(dst_ip) != ""}
                      patch={
                        flows_filter_patch(@base_path, @query, @limit, @nf_param, "dst_ip", dst_ip)
                      }
                      class="hover:underline min-w-0 truncate"
                      title={dst_ip}
                    >
                      {dst_ip}
                    </.link>
                    <span
                      :if={not (is_binary(dst_ip) and String.trim(dst_ip) != "")}
                      class="min-w-0 truncate"
                    >
                      {dst_ip || "—"}
                    </span>
                    <span class="shrink-0 text-sr-muted">
                      {if dst_port, do: ":#{dst_port}", else: ""}
                    </span>
                  </div>
                  <div
                    :if={hostname = Map.get(@rdns_map, dst_ip)}
                    class="mt-0.5 text-[11px] text-sr-muted truncate font-mono"
                    title={hostname}
                  >
                    {hostname}
                  </div>
                  <PrefixTagChips.linked items={
                    linked_prefix_tag_items(
                      flow_prefix_tags(flow, :dst),
                      @base_path,
                      @query,
                      @limit,
                      @nf_param
                    )
                  } />
                </div>
              </td>
              <td class="whitespace-nowrap text-xs text-right font-mono align-top">
                <% proto = flow_get(flow, ["protocol_group", "protocol_name", "proto"]) || "—" %>
                <% app = flow_app_label(flow) %>
                <div class="flex flex-col items-end gap-0.5 leading-tight">
                  <.ui_badge variant="ghost" size="xs" class="font-mono">
                    {proto}
                  </.ui_badge>
                  <div
                    :if={is_binary(app) and String.trim(app) != "" and app != "unknown"}
                    class="text-[10px] text-sr-muted font-mono"
                  >
                    {app}
                  </div>
                </div>
              </td>
              <td class="whitespace-nowrap text-xs text-right font-mono align-top">
                <% flow_src = flow_get_in(flow, ["ocsf_payload", "flow_source"]) %>
                <.ui_badge
                  :if={is_binary(flow_src) and flow_src != "Unknown"}
                  variant={
                    cond do
                      String.starts_with?(flow_src, "sFlow") -> "info"
                      String.starts_with?(flow_src, "IPFIX") -> "warning"
                      true -> "success"
                    end
                  }
                  size="xs"
                  class="font-mono"
                >
                  {flow_src}
                </.ui_badge>
                <span
                  :if={!is_binary(flow_src) or flow_src == "Unknown"}
                  class="text-sr-muted"
                >
                  —
                </span>
              </td>
              <td class="whitespace-nowrap text-xs text-right font-mono align-top">
                <.flow_attribution_summary flow={flow} />
              </td>
              <td class="whitespace-nowrap text-xs text-right font-mono align-top">
                <% packets = flow_get(flow, ["packets_total", "packets"]) %>
                <% raw_bytes = flow_get(flow, ["bytes_total", "bytes"]) %>
                <%= case @unit_mode do %>
                  <% "pps" -> %>
                    <div class="flex flex-col items-end leading-tight">
                      <div>{packets || "—"}</div>
                    </div>
                  <% "bps" -> %>
                    <% {bits_val, bits_unit} = format_bits_parts(raw_bytes) %>
                    <div class="flex flex-col items-end leading-tight">
                      <div>{packets || "—"}</div>
                      <div class="flex items-baseline gap-1 text-[10px] text-sr-muted">
                        <span>{bits_val}</span>
                        <span :if={bits_unit != ""} class="uppercase">{bits_unit}</span>
                      </div>
                    </div>
                  <% _ -> %>
                    <% {bytes_val, bytes_unit} = format_bytes_parts(raw_bytes) %>
                    <div class="flex flex-col items-end leading-tight">
                      <div>{packets || "—"}</div>
                      <div class="flex items-baseline gap-1 text-[10px] text-sr-muted">
                        <span>{bytes_val}</span>
                        <span :if={bytes_unit != ""} class="uppercase">{bytes_unit}</span>
                      </div>
                    </div>
                <% end %>
              </td>
              <td class="whitespace-nowrap text-xs text-right">
                <.ui_dropdown align="end">
                  <:trigger>
                    <.ui_icon_button variant="ghost" size="xs" aria-label="Flow actions">
                      <.icon name="hero-ellipsis-vertical" class="size-4" />
                    </.ui_icon_button>
                  </:trigger>
                  <:item>
                    <.link phx-click="netflow_open" phx-value-idx={idx} class="text-xs">
                      Open details
                    </.link>
                  </:item>
                  <:item :if={is_binary(src_ip) and String.trim(src_ip) != ""}>
                    <.link
                      patch={
                        flows_filter_patch(@base_path, @query, @limit, @nf_param, "src_ip", src_ip)
                      }
                      class="text-xs"
                    >
                      Filter source
                    </.link>
                  </:item>
                  <:item :if={is_binary(dst_ip) and String.trim(dst_ip) != ""}>
                    <.link
                      patch={
                        flows_filter_patch(@base_path, @query, @limit, @nf_param, "dst_ip", dst_ip)
                      }
                      class="text-xs"
                    >
                      Filter destination
                    </.link>
                  </:item>
                  <:item :if={dst_port && to_string(dst_port) != ""}>
                    <.link
                      patch={
                        flows_filter_patch(
                          @base_path,
                          @query,
                          @limit,
                          @nf_param,
                          "dst_port",
                          to_string(dst_port)
                        )
                      }
                      class="text-xs"
                    >
                      Filter port
                    </.link>
                  </:item>
                </.ui_dropdown>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>

      <div :if={@flows == []} class="py-10 text-center text-sr-muted">
        No flows in this window.
      </div>
    </div>
    """
  end

  attr(:flow, :map, required: true)

  def flow_attribution_summary(assigns) do
    assigns = assign(assigns, :attribution, flow_attribution(assigns.flow))

    ~H"""
    <div class="flex flex-col items-end gap-0.5 leading-tight">
      <.ui_badge
        variant={if Map.get(@attribution, :attributed?), do: "success", else: "ghost"}
        size="xs"
        class="font-mono"
      >
        {if Map.get(@attribution, :attributed?), do: "Attributed", else: "—"}
      </.ui_badge>
      <div
        :if={Map.get(@attribution, :attributed?)}
        class="max-w-28 truncate text-[10px] text-sr-muted"
        title={Map.get(@attribution, :process_label)}
      >
        {Map.get(@attribution, :process_label)}
      </div>
    </div>
    """
  end

  # Kept as a thin wrapper for unit tests that still call the table module API.
  def prefix_tag_chips(assigns) do
    items =
      linked_prefix_tag_items(
        assigns[:tags] || [],
        assigns.base_path,
        assigns.query,
        assigns.limit,
        assigns[:nf_param]
      )

    PrefixTagChips.linked(%{items: items})
  end

  defp flow_prefix_tags(flow, side) when side in [:src, :dst] do
    prefix = to_string(side)

    tags =
      flow_get(flow, ["#{prefix}_prefix_tags"]) ||
        flow_get_in(flow, ["ocsf_payload", "enrichment", "#{prefix}_prefix_tags"])

    PrefixTagChips.normalize_tags(tags, 4)
  end

  defp linked_prefix_tag_items(tags, base_path, query, limit, nf_param) do
    Enum.map(tags, fn tag ->
      %{
        tag: tag,
        path: flows_filter_patch(base_path, query, limit, nf_param, "tag", tag)
      }
    end)
  end

  defp flow_row_time_id(flow, fallback_index) do
    suffix =
      flow
      |> flow_get(["id", "uid", "flow_id"])
      |> case do
        nil -> Integer.to_string(fallback_index)
        value -> to_string(value)
      end
      |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
      |> String.trim("-")

    "netflow-row-time-#{if suffix == "", do: fallback_index, else: suffix}"
  end
end
