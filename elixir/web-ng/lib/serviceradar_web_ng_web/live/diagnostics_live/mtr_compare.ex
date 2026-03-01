defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrCompare do
  use ServiceRadarWebNGWeb, :live_view

  import Ash.Expr

  alias ServiceRadar.Observability.{MtrHop, MtrTrace}

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "MTR Path Comparison")
     |> assign(:page_path, "/diagnostics/mtr/compare")
     |> assign(:recent_traces, [])
     |> assign(:trace_a, nil)
     |> assign(:trace_b, nil)
     |> assign(:hops_a, [])
     |> assign(:hops_b, [])
     |> assign(:diff, [])
     |> assign(:error, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = load_recent_traces(socket)

    socket =
      case {Map.get(params, "a"), Map.get(params, "b")} do
        {a, b} when is_binary(a) and is_binary(b) and a != "" and b != "" ->
          load_comparison(socket, a, b)

        _ ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("compare", %{"a" => a, "b" => b}, socket) do
    if a != "" and b != "" and a != b do
      {:noreply, push_patch(socket, to: ~p"/diagnostics/mtr/compare?a=#{a}&b=#{b}")}
    else
      {:noreply,
       socket
       |> assign(:error, "Select two different traces to compare")
       |> assign(:trace_a, nil)
       |> assign(:trace_b, nil)
       |> assign(:hops_a, [])
       |> assign(:hops_b, [])
       |> assign(:diff, [])}
    end
  end

  defp load_recent_traces(socket) do
    query =
      MtrTrace
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.sort(time: :desc)
      |> Ash.Query.limit(50)

    case Ash.read(query, scope: socket.assigns.current_scope) do
      {:ok, %Ash.Page.Keyset{results: results}} ->
        assign(socket, :recent_traces, Enum.map(results, &trace_to_compare_map/1))

      {:ok, results} when is_list(results) ->
        assign(socket, :recent_traces, Enum.map(results, &trace_to_compare_map/1))

      {:error, _reason} ->
        assign(socket, :recent_traces, [])
    end
  end

  defp load_comparison(socket, trace_id_a, trace_id_b) do
    scope = socket.assigns.current_scope

    with {:ok, trace_a, hops_a} <- load_trace_with_hops(trace_id_a, scope),
         {:ok, trace_b, hops_b} <- load_trace_with_hops(trace_id_b, scope) do
      diff = compute_diff(hops_a, hops_b)

      socket
      |> assign(:trace_a, trace_a)
      |> assign(:trace_b, trace_b)
      |> assign(:hops_a, hops_a)
      |> assign(:hops_b, hops_b)
      |> assign(:diff, diff)
      |> assign(:error, nil)
    else
      {:error, reason} ->
        assign(socket, :error, "Failed to load traces: #{inspect(reason)}")
    end
  end

  defp load_trace_with_hops(trace_id, scope) do
    with {:ok, trace_uuid} <- Ecto.UUID.cast(trace_id),
         {:ok, trace} <- read_trace(trace_uuid, scope),
         {:ok, hops} <- read_trace_hops(trace_uuid, scope) do
      {:ok, trace_to_compare_map(trace), Enum.map(hops, &hop_to_compare_map/1)}
    else
      :error -> {:error, "Invalid trace id"}
      {:error, :not_found} -> {:error, "Trace not found"}
      {:error, reason} -> {:error, reason}
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

  defp trace_to_compare_map(trace) do
    %{
      "id" => trace.id && to_string(trace.id),
      "time" => trace.time,
      "agent_id" => trace.agent_id,
      "target" => trace.target,
      "target_ip" => trace.target_ip,
      "target_reached" => trace.target_reached,
      "total_hops" => trace.total_hops,
      "protocol" => trace.protocol,
      "ip_version" => trace.ip_version
    }
  end

  defp hop_to_compare_map(hop) do
    %{
      "hop_number" => hop.hop_number,
      "addr" => hop.addr,
      "hostname" => hop.hostname,
      "asn" => hop.asn,
      "asn_org" => hop.asn_org,
      "loss_pct" => hop.loss_pct,
      "avg_us" => hop.avg_us,
      "min_us" => hop.min_us,
      "max_us" => hop.max_us
    }
  end

  # Build a unified diff list: [{hop_number, hop_a, hop_b, status}]
  # status: :same, :changed, :added, :removed
  defp compute_diff(hops_a, hops_b) do
    map_a = Map.new(hops_a, fn h -> {h["hop_number"], h} end)
    map_b = Map.new(hops_b, fn h -> {h["hop_number"], h} end)

    all_hops =
      (Map.keys(map_a) ++ Map.keys(map_b))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(all_hops, fn hop_num ->
      a = Map.get(map_a, hop_num)
      b = Map.get(map_b, hop_num)

      status =
        cond do
          is_nil(a) -> :added
          is_nil(b) -> :removed
          (a["addr"] || "") != (b["addr"] || "") -> :changed
          true -> :same
        end

      {hop_num, a, b, status}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={%{enabled: false, page_path: @page_path}}>
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
        <h1 class="text-2xl font-bold">Path Comparison</h1>
      </div>

      <div :if={@error} class="alert alert-error">
        <span>{@error}</span>
      </div>

      <form phx-submit="compare" class="flex items-end gap-3">
        <div class="form-control">
          <label class="label"><span class="label-text">Trace A</span></label>
          <select name="a" class="select select-bordered select-sm w-72">
            <option value="">Select trace...</option>
            <%= for t <- @recent_traces do %>
              <option
                value={t["id"]}
                selected={@trace_a && @trace_a["id"] == t["id"]}
              >
                {trace_option_label(t)}
              </option>
            <% end %>
          </select>
        </div>
        <div class="form-control">
          <label class="label"><span class="label-text">Trace B</span></label>
          <select name="b" class="select select-bordered select-sm w-72">
            <option value="">Select trace...</option>
            <%= for t <- @recent_traces do %>
              <option
                value={t["id"]}
                selected={@trace_b && @trace_b["id"] == t["id"]}
              >
                {trace_option_label(t)}
              </option>
            <% end %>
          </select>
        </div>
        <button type="submit" class="btn btn-sm btn-primary">Compare</button>
      </form>

      <div :if={@trace_a && @trace_b} class="space-y-4">
        <div class="grid grid-cols-2 gap-4">
          <div class="card bg-base-200 p-3">
            <div class="text-xs text-base-content/60">Trace A</div>
            <div class="font-mono text-sm">{@trace_a["target"]}</div>
            <div class="text-xs">
              {format_time(@trace_a["time"])} &mdash; {@trace_a["agent_id"]}
              &mdash; {String.upcase(@trace_a["protocol"] || "icmp")}
            </div>
          </div>
          <div class="card bg-base-200 p-3">
            <div class="text-xs text-base-content/60">Trace B</div>
            <div class="font-mono text-sm">{@trace_b["target"]}</div>
            <div class="text-xs">
              {format_time(@trace_b["time"])} &mdash; {@trace_b["agent_id"]}
              &mdash; {String.upcase(@trace_b["protocol"] || "icmp")}
            </div>
          </div>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th class="w-12">Hop</th>
                <th class="w-8"></th>
                <th>Address A</th>
                <th class="text-right">Avg A</th>
                <th class="text-right">Loss A</th>
                <th>Address B</th>
                <th class="text-right">Avg B</th>
                <th class="text-right">Loss B</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{hop_num, a, b, status} <- @diff} class={diff_row_class(status)}>
                <td class="font-mono text-center">{hop_num}</td>
                <td>{diff_icon(status)}</td>
                <td class="font-mono text-sm">{hop_addr(a)}</td>
                <td class="text-right font-mono text-sm">{hop_val(a, "avg_us")}</td>
                <td class="text-right font-mono text-sm">{hop_pct(a, "loss_pct")}</td>
                <td class="font-mono text-sm">{hop_addr(b)}</td>
                <td class="text-right font-mono text-sm">{hop_val(b, "avg_us")}</td>
                <td class="text-right font-mono text-sm">{hop_pct(b, "loss_pct")}</td>
              </tr>
              <tr :if={@diff == []}>
                <td colspan="8" class="text-center py-4 text-base-content/50">
                  No hop data to compare
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

  defp trace_option_label(t) do
    time =
      case t["time"] do
        %DateTime{} = dt -> Calendar.strftime(dt, "%m/%d %H:%M")
        %NaiveDateTime{} = ndt -> Calendar.strftime(ndt, "%m/%d %H:%M")
        _ -> "?"
      end

    "#{time} #{t["target"]} (#{t["agent_id"]})"
  end

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_time(%NaiveDateTime{} = ndt), do: Calendar.strftime(ndt, "%Y-%m-%d %H:%M:%S")
  defp format_time(_), do: "-"

  defp hop_addr(nil), do: "-"
  defp hop_addr(hop), do: hop["addr"] || "???"

  defp hop_val(nil, _key), do: "-"

  defp hop_val(hop, key) do
    case hop[key] do
      nil -> "-"
      0 -> "-"
      us when is_integer(us) and us >= 1000 -> "#{Float.round(us / 1000, 1)}ms"
      us when is_integer(us) -> "#{us}us"
      _ -> "-"
    end
  end

  defp hop_pct(nil, _key), do: "-"

  defp hop_pct(hop, key) do
    case hop[key] do
      nil -> "-"
      pct when is_float(pct) -> "#{Float.round(pct, 1)}%"
      pct when is_integer(pct) -> "#{pct}%"
      _ -> "-"
    end
  end

  defp diff_row_class(:changed), do: "bg-warning/10"
  defp diff_row_class(:added), do: "bg-info/10"
  defp diff_row_class(:removed), do: "bg-error/10"
  defp diff_row_class(_), do: ""

  defp diff_icon(:changed), do: Phoenix.HTML.raw("<span class=\"text-warning\" title=\"Changed\">~</span>")
  defp diff_icon(:added), do: Phoenix.HTML.raw("<span class=\"text-info\" title=\"New hop\">+</span>")
  defp diff_icon(:removed), do: Phoenix.HTML.raw("<span class=\"text-error\" title=\"Missing hop\">-</span>")
  defp diff_icon(_), do: ""
end
