defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrTrace do
  use ServiceRadarWebNGWeb, :live_view

  import Ash.Expr
  import ServiceRadarWebNGWeb.SRQLComponents, only: [srql_sparkline: 1]

  alias ServiceRadar.Observability.{MtrHop, MtrTrace}

  require Ash.Query

  @sparkline_points 20

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "MTR Trace")
     |> assign(:page_path, "/diagnostics/mtr")
     |> assign(:trace, nil)
     |> assign(:hops, [])
     |> assign(:hop_sparklines, %{})
     |> assign(:error, nil)}
  end

  @impl true
  def handle_params(%{"trace_id" => trace_id}, _uri, socket) do
    socket =
      socket
      |> assign(:page_path, "/diagnostics/mtr/#{trace_id}")
      |> load_trace(trace_id)

    {:noreply, socket}
  end

  defp load_trace(socket, trace_id) do
    scope = socket.assigns.current_scope

    with {:ok, trace_uuid} <- Ecto.UUID.cast(trace_id),
         {:ok, trace} <- read_trace(trace_uuid, scope),
         {:ok, hops} <- read_trace_hops(trace_uuid, scope) do
      trace_map = trace_to_map(trace)
      hop_maps = Enum.map(hops, &hop_to_map/1)
      sparklines = load_hop_sparklines(hop_maps, scope)

      socket
      |> assign(:trace, trace_map)
      |> assign(:hops, hop_maps)
      |> assign(:hop_sparklines, sparklines)
      |> assign(:page_title, "MTR Trace: #{trace_map["target"]}")
      |> assign(:error, nil)
    else
      :error ->
        assign(socket, :error, "Invalid trace id")

      {:error, :not_found} ->
        assign(socket, :error, "Trace not found")

      {:error, reason} ->
        assign(socket, :error, "Failed to load trace: #{inspect(reason)}")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      srql={%{enabled: false, page_path: @page_path}}
    >
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
                <span class={status_class(@trace)}>{status_label(@trace)}</span>
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
                  <th>Endpoint</th>
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
                  <td class="text-xs">
                    <div class="font-mono text-sm">
                      {hop["addr"] || "???"}
                      <span
                        :if={hop["ecmp_addrs"] && hop["ecmp_addrs"] != []}
                        class="badge badge-xs badge-info ml-1"
                        title={Enum.join(hop["ecmp_addrs"], ", ")}
                      >
                        +{length(hop["ecmp_addrs"])} ECMP
                      </span>
                    </div>
                    <div
                      class="text-sm text-base-content/80 max-w-[220px] truncate"
                      title={hop["hostname"]}
                    >
                      {hop["hostname"] || "-"}
                    </div>
                    <div class="text-[11px]">
                      <span :if={hop["asn"]} class="badge badge-ghost badge-sm mr-1">
                        AS{hop["asn"]}
                      </span>
                      <span
                        :if={hop["asn_org"]}
                        class="text-base-content/50 truncate inline-block max-w-[180px] align-middle"
                        title={hop["asn_org"]}
                      >
                        {hop["asn_org"]}
                      </span>
                    </div>
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
                  <td colspan="11" class="text-center py-4 text-base-content/50">
                    No hop data available
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Layouts.app>
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

  defp format_mpls(%{"labels" => labels}), do: format_mpls(labels)
  defp format_mpls(%{labels: labels}), do: format_mpls(labels)

  defp format_mpls(labels) when is_list(labels) and labels != [] do
    Enum.map_join(labels, ", ", &format_mpls_label/1)
  end

  defp format_mpls(%{} = labels) when map_size(labels) > 0, do: inspect(labels)
  defp format_mpls(_), do: "-"

  defp format_mpls_label(label) when is_map(label) do
    mpls_label = map_value(label, "label")
    exp = map_value(label, "exp")
    bos = map_value(label, "s")
    ttl = map_value(label, "ttl")

    base =
      case mpls_label do
        nil -> "L:?"
        v -> "L:#{v}"
      end

    suffix =
      []
      |> maybe_append_mpls_part("exp", exp)
      |> maybe_append_mpls_part("s", bos)
      |> maybe_append_mpls_part("ttl", ttl)
      |> Enum.join(" ")

    if suffix == "", do: base, else: "#{base} (#{suffix})"
  end

  defp format_mpls_label(_), do: "L:?"

  defp maybe_append_mpls_part(parts, _key, nil), do: parts
  defp maybe_append_mpls_part(parts, key, value), do: parts ++ ["#{key}=#{value}"]

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || map_get_existing_atom_key(map, key)
  end

  defp map_value(_map, _key), do: nil

  defp map_get_existing_atom_key(map, key) when is_map(map) and is_binary(key) do
    atom_key = String.to_existing_atom(key)
    Map.get(map, atom_key)
  rescue
    _ -> nil
  end

  defp map_get_existing_atom_key(_map, _key), do: nil

  defp hop_row_class(hop) do
    cond do
      is_nil(hop["addr"]) or hop["addr"] == "" -> "opacity-50"
      hop["loss_pct"] && hop["loss_pct"] > 50 -> "bg-error/10"
      hop["loss_pct"] && hop["loss_pct"] > 10 -> "bg-warning/10"
      true -> ""
    end
  end

  defp status_label(trace) when is_map(trace) do
    reached? = trace["target_reached"] == true
    protocol = trace["protocol"] |> to_string() |> String.downcase()
    total_hops = trace["total_hops"] || 0

    cond do
      reached? ->
        "Reached"

      protocol == "tcp" and is_integer(total_hops) and total_hops > 0 ->
        "No Terminal Reply"

      true ->
        "Unreachable"
    end
  end

  defp status_label(_), do: "Unreachable"

  defp status_class(trace) when is_map(trace) do
    case status_label(trace) do
      "Reached" -> "text-success"
      "No Terminal Reply" -> "text-warning"
      _ -> "text-error"
    end
  end

  defp status_class(_), do: "text-error"

  defp loss_class(nil), do: ""
  defp loss_class(pct) when pct > 50, do: "text-error font-bold"
  defp loss_class(pct) when pct > 10, do: "text-warning"
  defp loss_class(pct) when pct > 0, do: "text-warning/70"
  defp loss_class(_), do: "text-success"

  # ---------------------------------------------------------------------------
  # Sparklines
  # ---------------------------------------------------------------------------

  defp load_hop_sparklines(hops, scope) do
    addrs =
      hops
      |> Enum.map(& &1["addr"])
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    if addrs == [] do
      %{}
    else
      # Read recent valid latency points and cap per-address in Elixir.
      limit = max(length(addrs) * @sparkline_points * 4, 200)

      query =
        MtrHop
        |> Ash.Query.for_read(:read, %{})
        |> Ash.Query.filter(expr(addr in ^addrs and not is_nil(avg_us) and avg_us > 0))
        |> Ash.Query.sort(time: :desc)
        |> Ash.Query.limit(limit)

      case Ash.read(query, scope: scope) do
        {:ok, %Ash.Page.Keyset{results: results}} ->
          results
          |> build_sparklines_from_hops()

        {:ok, results} when is_list(results) ->
          results
          |> build_sparklines_from_hops()

        {:error, _reason} ->
          %{}
      end
    end
  end

  defp read_trace(trace_uuid, scope) do
    query =
      MtrTrace
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(expr(id == ^trace_uuid))
      |> Ash.Query.limit(1)

    case Ash.read(query, scope: scope) do
      {:ok, %Ash.Page.Keyset{results: [trace | _]}} -> {:ok, trace}
      {:ok, [trace | _]} -> {:ok, trace}
      {:ok, %Ash.Page.Keyset{results: []}} -> {:error, :not_found}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_trace_hops(trace_uuid, scope) do
    query =
      MtrHop
      |> Ash.Query.for_read(:by_trace, %{trace_id: trace_uuid})
      |> Ash.Query.sort(hop_number: :asc)
      |> Ash.Query.limit(256)

    case Ash.read(query, scope: scope) do
      {:ok, %Ash.Page.Keyset{results: results}} -> {:ok, results}
      {:ok, results} when is_list(results) -> {:ok, results}
      {:error, reason} -> {:error, reason}
    end
  end

  defp trace_to_map(trace) do
    %{
      "id" => trace.id && to_string(trace.id),
      "time" => trace.time,
      "agent_id" => trace.agent_id,
      "gateway_id" => trace.gateway_id,
      "check_id" => trace.check_id,
      "check_name" => trace.check_name,
      "device_id" => trace.device_id,
      "target" => trace.target,
      "target_ip" => trace.target_ip,
      "target_reached" => trace.target_reached,
      "total_hops" => trace.total_hops,
      "protocol" => trace.protocol,
      "ip_version" => trace.ip_version,
      "packet_size" => trace.packet_size,
      "partition" => trace.partition,
      "error" => trace.error
    }
  end

  defp hop_to_map(hop) do
    %{
      "hop_number" => hop.hop_number,
      "addr" => hop.addr,
      "hostname" => hop.hostname,
      "ecmp_addrs" => hop.ecmp_addrs,
      "asn" => hop.asn,
      "asn_org" => hop.asn_org,
      "mpls_labels" => hop.mpls_labels,
      "sent" => hop.sent,
      "received" => hop.received,
      "loss_pct" => hop.loss_pct,
      "last_us" => hop.last_us,
      "avg_us" => hop.avg_us,
      "min_us" => hop.min_us,
      "max_us" => hop.max_us,
      "stddev_us" => hop.stddev_us,
      "jitter_us" => hop.jitter_us,
      "jitter_worst_us" => hop.jitter_worst_us,
      "jitter_interarrival_us" => hop.jitter_interarrival_us
    }
  end

  defp build_sparklines_from_hops(hops) do
    hops
    |> Enum.group_by(& &1.addr)
    |> Enum.reduce(%{}, fn
      {nil, _}, acc ->
        acc

      {"", _}, acc ->
        acc

      {addr, rows}, acc ->
        points =
          rows
          |> Enum.take(@sparkline_points)
          |> Enum.reverse()
          |> Enum.map(fn row -> {row.time, row.avg_us} end)

        Map.put(acc, addr, points)
    end)
  end
end
