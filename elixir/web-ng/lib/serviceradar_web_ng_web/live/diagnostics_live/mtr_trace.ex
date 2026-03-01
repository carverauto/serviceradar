defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrTrace do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SRQLComponents, only: [srql_sparkline: 1]

  alias ServiceRadar.Repo

  @sparkline_points 20

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "MTR Trace")
     |> assign(:trace, nil)
     |> assign(:hops, [])
     |> assign(:hop_sparklines, %{})
     |> assign(:error, nil)}
  end

  @impl true
  def handle_params(%{"trace_id" => trace_id}, _uri, socket) do
    {:noreply, load_trace(socket, trace_id)}
  end

  defp load_trace(socket, trace_id) do
    trace_query = """
    SELECT id, time, agent_id, gateway_id, check_id, check_name, device_id,
           target, target_ip, target_reached, total_hops, protocol,
           ip_version, packet_size, partition, error
    FROM mtr_traces
    WHERE id = $1
    LIMIT 1
    """

    hops_query = """
    SELECT hop_number, addr, hostname, ecmp_addrs, asn, asn_org,
           mpls_labels, sent, received, loss_pct,
           last_us, avg_us, min_us, max_us, stddev_us,
           jitter_us, jitter_worst_us, jitter_interarrival_us
    FROM mtr_hops
    WHERE trace_id = $1
    ORDER BY hop_number ASC
    """

    with {:ok, %{rows: [row], columns: cols}} <- Repo.query(trace_query, [trace_id]),
         trace <- Enum.zip(cols, row) |> Map.new(),
         {:ok, %{rows: hop_rows, columns: hop_cols}} <- Repo.query(hops_query, [trace_id]) do
      hops = Enum.map(hop_rows, fn row -> Enum.zip(hop_cols, row) |> Map.new() end)
      sparklines = load_hop_sparklines(hops)

      socket
      |> assign(:trace, trace)
      |> assign(:hops, hops)
      |> assign(:hop_sparklines, sparklines)
      |> assign(:page_title, "MTR Trace: #{trace["target"]}")
      |> assign(:error, nil)
    else
      {:ok, %{rows: []}} ->
        assign(socket, :error, "Trace not found")

      {:error, reason} ->
        assign(socket, :error, "Failed to load trace: #{inspect(reason)}")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <div class="flex items-center gap-3">
        <.link navigate={~p"/diagnostics/mtr"} class="btn btn-sm btn-ghost">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="h-4 w-4"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M15 19l-7-7 7-7"
            />
          </svg>
          Back
        </.link>
        <h1 class="text-2xl font-bold">MTR Trace Detail</h1>
      </div>

      <div :if={@error} class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={@trace} class="space-y-6">
        <div class="stats shadow bg-base-200">
          <div class="stat">
            <div class="stat-title">Target</div>
            <div class="stat-value text-lg font-mono">{@trace["target"]}</div>
            <div :if={@trace["target_ip"] != @trace["target"]} class="stat-desc">
              {@trace["target_ip"]}
            </div>
          </div>
          <div class="stat">
            <div class="stat-title">Status</div>
            <div class="stat-value text-lg">
              <span :if={@trace["target_reached"]} class="text-success">Reached</span>
              <span :if={!@trace["target_reached"]} class="text-error">Unreachable</span>
            </div>
          </div>
          <div class="stat">
            <div class="stat-title">Hops</div>
            <div class="stat-value text-lg">{@trace["total_hops"]}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Protocol</div>
            <div class="stat-value text-lg">
              {String.upcase(@trace["protocol"] || "icmp")}
              <span :if={@trace["ip_version"] == 6} class="text-sm text-info ml-1">IPv6</span>
            </div>
          </div>
          <div class="stat">
            <div class="stat-title">Time</div>
            <div class="stat-value text-sm">{format_time(@trace["time"])}</div>
            <div class="stat-desc">Agent: {@trace["agent_id"]}</div>
          </div>
        </div>

        <div :if={@trace["error"]} class="alert alert-warning">
          <span>Error: {@trace["error"]}</span>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th class="w-12">Hop</th>
                <th>Address</th>
                <th>Hostname</th>
                <th>ASN</th>
                <th class="text-right">Loss %</th>
                <th class="text-right">Last</th>
                <th class="text-right">Avg</th>
                <th class="text-right">Min</th>
                <th class="text-right">Max</th>
                <th class="text-right">StdDev</th>
                <th class="text-right">Jitter</th>
                <th class="w-24">Trend</th>
                <th>MPLS</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={hop <- @hops} class={hop_row_class(hop)}>
                <td class="font-mono text-center">{hop["hop_number"]}</td>
                <td class="font-mono text-sm">
                  {hop["addr"] || "???"}
                  <span
                    :if={hop["ecmp_addrs"] && hop["ecmp_addrs"] != []}
                    class="badge badge-xs badge-info ml-1"
                    title={Enum.join(hop["ecmp_addrs"], ", ")}
                  >
                    +{length(hop["ecmp_addrs"])} ECMP
                  </span>
                </td>
                <td class="text-sm max-w-[200px] truncate" title={hop["hostname"]}>
                  {hop["hostname"] || "-"}
                </td>
                <td class="text-xs">
                  <span :if={hop["asn"]} class="badge badge-ghost badge-sm">
                    AS{hop["asn"]}
                  </span>
                  <span
                    :if={hop["asn_org"]}
                    class="block text-base-content/50 truncate max-w-[120px]"
                    title={hop["asn_org"]}
                  >
                    {hop["asn_org"]}
                  </span>
                </td>
                <td class={["text-right font-mono text-sm", loss_class(hop["loss_pct"])]}>
                  {format_pct(hop["loss_pct"])}
                </td>
                <td class="text-right font-mono text-sm">{format_us(hop["last_us"])}</td>
                <td class="text-right font-mono text-sm">{format_us(hop["avg_us"])}</td>
                <td class="text-right font-mono text-sm">{format_us(hop["min_us"])}</td>
                <td class="text-right font-mono text-sm">{format_us(hop["max_us"])}</td>
                <td class="text-right font-mono text-sm">{format_us(hop["stddev_us"])}</td>
                <td class="text-right font-mono text-sm">{format_us(hop["jitter_us"])}</td>
                <td>
                  <.srql_sparkline points={Map.get(@hop_sparklines, hop["addr"], [])} />
                </td>
                <td class="text-xs">
                  {format_mpls(hop["mpls_labels"])}
                </td>
              </tr>
              <tr :if={@hops == []}>
                <td colspan="13" class="text-center py-4 text-base-content/50">
                  No hop data available
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp format_time(nil), do: "-"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_time(%NaiveDateTime{} = ndt) do
    Calendar.strftime(ndt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_time(_), do: "-"

  defp format_us(nil), do: "-"
  defp format_us(0), do: "-"

  defp format_us(us) when is_integer(us) do
    cond do
      us >= 1_000_000 -> "#{Float.round(us / 1_000_000, 1)}s"
      us >= 1_000 -> "#{Float.round(us / 1_000, 1)}ms"
      true -> "#{us}us"
    end
  end

  defp format_us(_), do: "-"

  defp format_pct(nil), do: "-"
  defp format_pct(pct) when is_float(pct), do: "#{Float.round(pct, 1)}%"
  defp format_pct(pct) when is_integer(pct), do: "#{pct}%"
  defp format_pct(_), do: "-"

  defp format_mpls(nil), do: "-"

  defp format_mpls(labels) when is_list(labels) and labels != [] do
    Enum.map_join(labels, ", ", fn label -> "L:#{label["label"]}" end)
  end

  defp format_mpls(%{} = labels) when map_size(labels) > 0, do: inspect(labels)
  defp format_mpls(_), do: "-"

  defp hop_row_class(hop) do
    cond do
      is_nil(hop["addr"]) or hop["addr"] == "" -> "opacity-50"
      hop["loss_pct"] && hop["loss_pct"] > 50 -> "bg-error/10"
      hop["loss_pct"] && hop["loss_pct"] > 10 -> "bg-warning/10"
      true -> ""
    end
  end

  defp loss_class(nil), do: ""
  defp loss_class(pct) when pct > 50, do: "text-error font-bold"
  defp loss_class(pct) when pct > 10, do: "text-warning"
  defp loss_class(pct) when pct > 0, do: "text-warning/70"
  defp loss_class(_), do: "text-success"

  # ---------------------------------------------------------------------------
  # Sparklines
  # ---------------------------------------------------------------------------

  defp load_hop_sparklines(hops) do
    addrs =
      hops
      |> Enum.map(& &1["addr"])
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    if addrs == [] do
      %{}
    else
      placeholders = Enum.map_join(1..length(addrs), ", ", fn i -> "$#{i}" end)

      query = """
      SELECT addr, time, avg_us
      FROM (
        SELECT addr, avg_us, time,
               ROW_NUMBER() OVER (PARTITION BY addr ORDER BY time DESC) AS rn
        FROM mtr_hops
        WHERE addr IN (#{placeholders})
          AND avg_us IS NOT NULL AND avg_us > 0
      ) sub
      WHERE rn <= #{@sparkline_points}
      ORDER BY addr, time ASC
      """

      case Repo.query(query, addrs) do
        {:ok, %{rows: rows}} ->
          group_hop_sparkline_rows(rows)

        {:error, _} ->
          %{}
      end
    end
  end

  defp group_hop_sparkline_rows(rows) do
    Enum.group_by(rows, &sparkline_group_key/1, &sparkline_group_value/1)
  end

  defp sparkline_group_key([addr, _time, _val]), do: addr
  defp sparkline_group_value([_addr, time, val]), do: {time, val}
end
