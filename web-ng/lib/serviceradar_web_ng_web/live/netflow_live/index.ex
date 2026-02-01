defmodule ServiceRadarWebNGWeb.NetflowLive.Index do
  @moduledoc """
  NetFlow list page with basic pagination.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents
  alias ServiceRadarWebNG.Repo

  @default_limit 50

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "NetFlow")
     |> assign(:flows, [])
     |> assign(:summary, %{
       total: 0,
       tcp: 0,
       udp: 0,
       other: 0,
       total_bytes: 0,
       v5: 0,
       v9: 0,
       ipfix: 0
     })
     |> assign(:limit, @default_limit)
     |> assign(:offset, 0)
     |> assign(:srql, %{enabled: false})}
  end

  def handle_params(params, _uri, socket) do
    limit = min(String.to_integer(params["limit"] || "#{@default_limit}"), 200)
    offset = String.to_integer(params["offset"] || "0")

    # Query directly from the database
    query = """
    SELECT
      to_char(time, 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as timestamp,
      src_endpoint_ip as src_addr,
      dst_endpoint_ip as dst_addr,
      src_endpoint_port as src_port,
      dst_endpoint_port as dst_port,
      protocol_num as protocol,
      packets_total as packets,
      bytes_total as octets,
      COALESCE(ocsf_payload->'unmapped'->>'flow_type', ocsf_payload->>'flow_type') as flow_type
    FROM ocsf_network_activity
    ORDER BY time DESC
    LIMIT #{limit}
    OFFSET #{offset}
    """

    flows =
      case query_db(query) do
        {:ok, results} -> results
        {:error, _} -> []
      end

    summary = compute_summary(flows)

    {:noreply,
     socket
     |> assign(:flows, flows)
     |> assign(:summary, summary)
     |> assign(:limit, limit)
     |> assign(:offset, offset)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6 space-y-6">
        <.header>
          NetFlow
          <:subtitle>Network flow data from NetFlow collectors</:subtitle>
        </.header>

        <.flow_summary summary={@summary} />

        <.ui_panel>
          <:header>Network Flows</:header>
          <.flows_table flows={@flows} />

          <div class="flex items-center justify-between px-4 py-3 border-t">
            <div class="text-sm text-muted-foreground">
              Showing {@offset + 1}-{@offset + length(@flows)} (Limit: {@limit})
            </div>
            <div class="flex gap-2">
              <%= if @offset > 0 do %>
                <.link
                  navigate={~p"/netflows?limit=#{@limit}&offset=#{max(0, @offset - @limit)}"}
                  class="px-3 py-1 text-sm border rounded hover:bg-muted"
                >
                  Previous
                </.link>
              <% end %>
              <%= if length(@flows) >= @limit do %>
                <.link
                  navigate={~p"/netflows?limit=#{@limit}&offset=#{@offset + @limit}"}
                  class="px-3 py-1 text-sm border rounded hover:bg-muted"
                >
                  Next
                </.link>
              <% end %>
            </div>
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  defp flow_summary(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-5">
        <.ui_panel class="p-4">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-muted-foreground">Total Flows</p>
              <p class="text-2xl font-bold">{@summary.total}</p>
            </div>
            <.icon name="hero-arrow-trending-up" class="h-8 w-8 text-muted-foreground" />
          </div>
        </.ui_panel>

        <.ui_panel class="p-4">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-muted-foreground">TCP Flows</p>
              <p class="text-2xl font-bold">{@summary.tcp}</p>
            </div>
            <.ui_badge variant="success">TCP</.ui_badge>
          </div>
        </.ui_panel>

        <.ui_panel class="p-4">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-muted-foreground">UDP Flows</p>
              <p class="text-2xl font-bold">{@summary.udp}</p>
            </div>
            <.ui_badge variant="info">UDP</.ui_badge>
          </div>
        </.ui_panel>

        <.ui_panel class="p-4">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-muted-foreground">Other</p>
              <p class="text-2xl font-bold">{@summary.other}</p>
            </div>
            <.ui_badge variant="ghost">Other</.ui_badge>
          </div>
        </.ui_panel>

        <.ui_panel class="p-4">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-muted-foreground">Total Bytes</p>
              <p class="text-2xl font-bold">{format_bytes(@summary.total_bytes)}</p>
            </div>
            <.icon name="hero-server-stack" class="h-8 w-8 text-muted-foreground" />
          </div>
        </.ui_panel>
      </div>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <.ui_panel class="p-4">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-muted-foreground">NetFlow v5</p>
              <p class="text-2xl font-bold">{@summary.v5}</p>
            </div>
            <.ui_badge variant="warning">v5</.ui_badge>
          </div>
        </.ui_panel>

        <.ui_panel class="p-4">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-muted-foreground">NetFlow v9</p>
              <p class="text-2xl font-bold">{@summary.v9}</p>
            </div>
            <.ui_badge variant="info">v9</.ui_badge>
          </div>
        </.ui_panel>

        <.ui_panel class="p-4">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-muted-foreground">IPFIX</p>
              <p class="text-2xl font-bold">{@summary.ipfix}</p>
            </div>
            <.ui_badge variant="success">IPFIX</.ui_badge>
          </div>
        </.ui_panel>
      </div>
    </div>
    """
  end

  defp flows_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="w-full text-sm">
        <thead class="border-b">
          <tr class="text-left">
            <th class="p-2 font-medium">Time</th>
            <th class="p-2 font-medium">Source</th>
            <th class="p-2 font-medium">Destination</th>
            <th class="p-2 font-medium">Protocol</th>
            <th class="p-2 font-medium">Version</th>
            <th class="p-2 font-medium text-right">Packets</th>
            <th class="p-2 font-medium text-right">Bytes</th>
          </tr>
        </thead>
        <tbody class="divide-y">
          <%= for flow <- @flows do %>
            <tr class="hover:bg-muted/50">
              <td class="p-2 text-muted-foreground text-xs">
                {format_timestamp(flow["timestamp"])}
              </td>
              <td class="p-2 font-mono text-sm">
                {flow["src_addr"]}{if flow["src_port"] && flow["src_port"] != 0,
                  do: ":#{flow["src_port"]}",
                  else: ""}
              </td>
              <td class="p-2 font-mono text-sm">
                {flow["dst_addr"]}{if flow["dst_port"] && flow["dst_port"] != 0,
                  do: ":#{flow["dst_port"]}",
                  else: ""}
              </td>
              <td class="p-2">
                <.protocol_badge protocol={flow["protocol"]} />
              </td>
              <td class="p-2">
                <.flow_type_badge flow_type={flow["flow_type"]} />
              </td>
              <td class="p-2 text-right font-mono">
                {format_number(flow["packets"])}
              </td>
              <td class="p-2 text-right font-mono">
                {format_bytes(flow["octets"])}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>

      <div :if={@flows == []} class="py-12 text-center text-muted-foreground">
        No network flows found. Generate some NetFlow data to see it here!
      </div>
    </div>
    """
  end

  defp protocol_badge(assigns) do
    protocol = assigns.protocol

    {label, variant} =
      case protocol do
        6 -> {"TCP", "success"}
        17 -> {"UDP", "info"}
        1 -> {"ICMP", "ghost"}
        nil -> {"Unknown", "ghost"}
        other -> {to_string(other), "ghost"}
      end

    assigns = assign(assigns, label: label, variant: variant)

    ~H"""
    <.ui_badge variant={@variant}>{@label}</.ui_badge>
    """
  end

  defp flow_type_badge(assigns) do
    flow_type = assigns.flow_type

    {label, variant} =
      case flow_type do
        "NETFLOW_V5" -> {"v5", "warning"}
        "NETFLOW_V9" -> {"v9", "info"}
        "IPFIX" -> {"IPFIX", "success"}
        nil -> {"Unknown", "ghost"}
        other -> {other, "ghost"}
      end

    assigns = assign(assigns, label: label, variant: variant)

    ~H"""
    <.ui_badge variant={@variant}>{@label}</.ui_badge>
    """
  end

  defp compute_summary(flows) when is_list(flows) do
    Enum.reduce(
      flows,
      %{total: 0, tcp: 0, udp: 0, other: 0, total_bytes: 0, v5: 0, v9: 0, ipfix: 0},
      fn flow, acc ->
        protocol = flow["protocol"]
        bytes = flow["octets"] || 0
        flow_type = flow["flow_type"]

        updated =
          case protocol do
            6 -> Map.update!(acc, :tcp, &(&1 + 1))
            17 -> Map.update!(acc, :udp, &(&1 + 1))
            _ -> Map.update!(acc, :other, &(&1 + 1))
          end

        updated =
          case flow_type do
            "NETFLOW_V5" -> Map.update!(updated, :v5, &(&1 + 1))
            "NETFLOW_V9" -> Map.update!(updated, :v9, &(&1 + 1))
            "IPFIX" -> Map.update!(updated, :ipfix, &(&1 + 1))
            _ -> updated
          end

        updated
        |> Map.update!(:total, &(&1 + 1))
        |> Map.update!(:total_bytes, &(&1 + bytes))
      end
    )
  end

  defp query_db(sql) do
    case Repo.query(sql, []) do
      {:ok, %{columns: columns, rows: rows}} ->
        results =
          Enum.map(rows, fn row ->
            columns
            |> Enum.zip(row)
            |> Map.new()
          end)

        {:ok, results}

      {:error, error} ->
        {:error, error}
    end
  end

  defp format_timestamp(nil), do: "—"
  defp format_timestamp(ts) when is_binary(ts), do: String.slice(ts, 0..18)
  defp format_timestamp(_), do: "—"

  defp format_bytes(nil), do: "0 B"
  defp format_bytes(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"

  defp format_bytes(bytes) when is_integer(bytes) and bytes < 1_048_576,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_bytes(bytes) when is_integer(bytes) and bytes < 1_073_741_824,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_bytes(bytes) when is_integer(bytes),
    do: "#{Float.round(bytes / 1_073_741_824, 2)} GB"

  defp format_bytes(_), do: "—"

  defp format_number(nil), do: "0"
  defp format_number(num) when is_integer(num), do: Integer.to_string(num)
  defp format_number(_), do: "—"
end
