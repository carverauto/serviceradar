defmodule ServiceRadarWebNGWeb.Flows.AttributedLive do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.Repo

  @refresh_interval_ms 5_000
  @row_limit 200

  # Attributed flows are netflow/sflow records the control plane joined with
  # netprobe process attribution; the joiner tags them event_type=attributed_flow
  # and stashes the process context under ocsf_payload->'attribution'.
  @attributed_flows_sql """
  SELECT
    time,
    src_endpoint_ip,
    src_endpoint_port,
    dst_endpoint_ip,
    dst_endpoint_port,
    protocol_name,
    COALESCE(bytes_total, 0)::bigint,
    COALESCE(packets_total, 0)::bigint,
    ocsf_payload -> 'attribution' ->> 'pid',
    ocsf_payload -> 'attribution' ->> 'comm',
    ocsf_payload -> 'attribution' ->> 'redacted_cmdline',
    ocsf_payload -> 'attribution' ->> 'uid',
    ocsf_payload -> 'attribution' ->> 'container_id'
  FROM platform.ocsf_network_activity
  WHERE ocsf_payload ->> 'event_type' = 'attributed_flow'
    AND time > now() - interval '24 hours'
  ORDER BY time DESC
  LIMIT #{@row_limit}
  """

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval_ms)
    rows = fetch_attributed_flows()

    {:ok,
     socket
     |> assign(:page_title, "Attributed Flows")
     |> assign(:summary, summarize(rows))
     |> stream(:attributed_flows, rows, dom_id: &flow_dom_id/1)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
    rows = fetch_attributed_flows()

    {:noreply,
     socket
     |> assign(:summary, summarize(rows))
     |> stream(:attributed_flows, rows, reset: true, dom_id: &flow_dom_id/1)}
  end

  defp fetch_attributed_flows do
    case Repo.query(@attributed_flows_sql, []) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &row_from_db/1)
      {:error, _} -> []
    end
  rescue
    _ -> []
  end

  defp row_from_db([time, src, src_port, dst, dst_port, protocol, bytes, packets, pid, comm, cmdline, uid, container_id]) do
    %{
      id: "#{iso(time)}-#{src}:#{src_port}-#{dst}:#{dst_port}",
      timestamp: format_ts(time),
      source: to_string(src || "-"),
      source_port: src_port,
      destination: to_string(dst || "-"),
      destination_port: dst_port,
      bytes: bytes || 0,
      packets: packets || 0,
      protocol: protocol || "-",
      pid: parse_int(pid),
      comm: comm,
      cmdline: cmdline,
      uid: parse_int(uid),
      container_id: container_id
    }
  end

  defp iso(%DateTime{} = t), do: DateTime.to_iso8601(t)
  defp iso(%NaiveDateTime{} = t), do: NaiveDateTime.to_iso8601(t)
  defp iso(other), do: to_string(other)

  defp format_ts(%DateTime{} = t), do: t |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp format_ts(%NaiveDateTime{} = t), do: t |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()

  defp format_ts(other), do: to_string(other)

  defp parse_int(nil), do: nil
  defp parse_int(v) when is_integer(v), do: v

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-7xl p-6 space-y-5">
        <.observability_chrome
          active_pane="attributed-flows"
          title="Attributed Flows"
          subtitle="Network flow records joined with host process context."
        >
          <:actions>
            <.ui_button
              href={~p"/observability?#{%{tab: "netflows", view: "explorer"}}"}
              variant="ghost"
              size="sm"
            >
              Raw Flows
            </.ui_button>
          </:actions>
        </.observability_chrome>

        <div class="grid grid-cols-2 gap-3 md:grid-cols-4">
          <.summary_tile label="Rows" value={@summary.total} icon="hero-table-cells" tone="neutral" />
          <.summary_tile
            label="Attributed"
            value={@summary.attributed}
            icon="hero-cpu-chip"
            tone="success"
          />
          <.summary_tile
            label="Unmatched"
            value={@summary.unattributed}
            icon="hero-link-slash"
            tone="warning"
          />
          <.summary_tile
            label="Bytes"
            value={format_number(@summary.bytes)}
            icon="hero-arrow-path"
            tone="info"
          />
        </div>

        <.ui_panel class="p-0" body_class="p-0">
          <:header>
            <div class="flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <div class="text-sm font-semibold">Recent Attributed Flow Records</div>
                <div class="text-xs text-base-content/60">
                  NetFlow tuples with local process context.
                </div>
              </div>
            </div>
          </:header>

          <div class="overflow-x-auto">
            <table class="table table-zebra table-sm">
              <thead>
                <tr>
                  <th>Timestamp</th>
                  <th>Source</th>
                  <th>Destination</th>
                  <th>Protocol</th>
                  <th class="text-right">Bytes</th>
                  <th class="text-right">Packets</th>
                  <th>PID</th>
                  <th>Process</th>
                  <th>Cmdline</th>
                  <th>UID</th>
                  <th>Container</th>
                </tr>
              </thead>
              <tbody id="attributed-flows" phx-update="stream">
                <%= for {dom_id, row} <- @streams.attributed_flows do %>
                  <tr id={dom_id}>
                    <td class="whitespace-nowrap text-xs">{row.timestamp}</td>
                    <td class="font-mono text-xs">{endpoint(row.source, row.source_port)}</td>
                    <td class="font-mono text-xs">
                      {endpoint(row.destination, row.destination_port)}
                    </td>
                    <td>
                      <span class="badge badge-ghost badge-sm">{row.protocol}</span>
                    </td>
                    <td class="text-right tabular-nums">{format_number(row.bytes)}</td>
                    <td class="text-right tabular-nums">{format_number(row.packets)}</td>
                    <td class="tabular-nums">{display(row.pid)}</td>
                    <td>{display(row.comm)}</td>
                    <td class="max-w-md truncate font-mono text-xs">{display(row.cmdline)}</td>
                    <td class="tabular-nums">{display(row.uid)}</td>
                    <td class="max-w-xs truncate font-mono text-xs">{display(row.container_id)}</td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true
  attr :tone, :string, default: "neutral"

  defp summary_tile(assigns) do
    ~H"""
    <div class={["rounded-lg border bg-base-100 p-3", tile_tone_class(@tone)]}>
      <div class="flex items-center justify-between gap-3">
        <div>
          <div class="text-xs uppercase text-base-content/60">{@label}</div>
          <div class="mt-1 text-2xl font-semibold tabular-nums">{@value}</div>
        </div>
        <.icon name={@icon} class="size-5 opacity-70" />
      </div>
    </div>
    """
  end

  defp summarize(rows) do
    Enum.reduce(rows, %{total: 0, attributed: 0, unattributed: 0, bytes: 0}, fn row, acc ->
      attributed? = not is_nil(row.pid)

      acc
      |> Map.update!(:total, &(&1 + 1))
      |> Map.update!(:bytes, &(&1 + row.bytes))
      |> Map.update!(if(attributed?, do: :attributed, else: :unattributed), &(&1 + 1))
    end)
  end

  defp flow_dom_id(row), do: "attributed-flow-#{row.id}"

  defp endpoint(ip, port), do: "#{ip}:#{port}"

  defp display(nil), do: "-"
  defp display(""), do: "-"
  defp display(value), do: value

  defp format_number(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(value), do: display(value)

  defp tile_tone_class("success"), do: "border-success/30"
  defp tile_tone_class("warning"), do: "border-warning/30"
  defp tile_tone_class("info"), do: "border-info/30"
  defp tile_tone_class(_), do: "border-base-200"
end
