defmodule ServiceRadarWebNGWeb.PollerLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.SRQL.Builder

  @default_limit 200
  @max_limit 500

  @impl true
  def mount(_params, _session, socket) do
    builder = Builder.default_state("pollers", @default_limit)
    query = Builder.build(builder)

    {:ok,
     socket
     |> assign(:page_title, "Pollers")
     |> assign(:pollers, [])
     |> assign(:limit, @default_limit)
     |> assign(:srql_enabled, true)
     |> assign(:srql_query, query)
     |> assign(:srql_query_draft, query)
     |> assign(:srql_error, nil)
     |> assign(:srql_page_path, nil)
     |> assign(:srql_builder_open, false)
     |> assign(:srql_builder_supported, true)
     |> assign(:srql_builder_sync, true)
     |> assign(:srql_builder, builder)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    limit = parse_limit(params["limit"])
    default_query = Builder.build(%{socket.assigns.srql_builder | "limit" => limit})
    query = Map.get(params, "q", default_query)

    srql = Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)

    {pollers, error} =
      case srql.query(query) do
        {:ok, %{"results" => results}} when is_list(results) -> {results, nil}
        {:ok, other} -> {[], "unexpected SRQL response: #{inspect(other)}"}
        {:error, reason} -> {[], "SRQL error: #{format_error(reason)}"}
      end

    display_limit = extract_limit_from_srql(query, limit)

    {:noreply,
     socket
     |> assign(:srql_page_path, URI.parse(uri).path)
     |> assign(:srql_query, query)
     |> assign(:srql_query_draft, query)
     |> assign(:srql_error, error)
     |> assign(:pollers, pollers)
     |> assign(:limit, display_limit)}
  end

  @impl true
  def handle_event("srql_change", %{"q" => query}, socket) do
    {:noreply, assign(socket, :srql_query_draft, query)}
  end

  def handle_event("srql_submit", %{"q" => raw_query}, socket) do
    query = raw_query |> to_string() |> String.trim()
    query = if query == "", do: socket.assigns.srql_query || "", else: query

    path = socket.assigns.srql_page_path || "/pollers"

    {:noreply,
     socket
     |> assign(:srql_builder_open, false)
     |> push_patch(to: path <> "?" <> URI.encode_query(%{"q" => query}))}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    if socket.assigns.srql_builder_open do
      {:noreply, assign(socket, :srql_builder_open, false)}
    else
      current = socket.assigns.srql_query_draft || socket.assigns.srql_query || ""

      {supported, sync, builder} =
        case Builder.parse(current) do
          {:ok, builder} ->
            {true, true, builder}

          {:error, _reason} ->
            {false, false, Builder.default_state("pollers", socket.assigns.limit)}
        end

      {:noreply,
       socket
       |> assign(:srql_builder_open, true)
       |> assign(:srql_builder_supported, supported)
       |> assign(:srql_builder_sync, sync)
       |> assign(:srql_builder, builder)}
    end
  end

  def handle_event("srql_builder_change", %{"builder" => params}, socket) do
    builder = Builder.update(socket.assigns.srql_builder, params)

    socket =
      socket
      |> assign(:srql_builder, builder)
      |> maybe_sync_builder_query()

    {:noreply, socket}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    query = Builder.build(socket.assigns.srql_builder)

    {:noreply,
     socket
     |> assign(:srql_builder_supported, true)
     |> assign(:srql_builder_sync, true)
     |> assign(:srql_query_draft, query)}
  end

  defp parse_limit(nil), do: @default_limit

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} -> parse_limit(value)
      _ -> @default_limit
    end
  end

  defp parse_limit(limit) when is_integer(limit) and limit > 0 do
    min(limit, @max_limit)
  end

  defp parse_limit(_), do: @default_limit

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-7xl p-6">
        <.header>
          Pollers
          <:subtitle>Showing up to {@limit} pollers.</:subtitle>
          <:actions>
            <.link class="btn btn-ghost btn-sm" patch={~p"/pollers?limit=#{@limit}"}>
              Reset
            </.link>
          </:actions>
        </.header>

        <.table id="pollers" rows={@pollers} row_id={&("poller-" <> to_string(&1["poller_id"]))}>
          <:col :let={p} label="ID">{p["poller_id"]}</:col>
          <:col :let={p} label="Status">{p["status"]}</:col>
          <:col :let={p} label="Healthy?">{p["is_healthy"]}</:col>
          <:col :let={p} label="Agents">{p["agent_count"]}</:col>
          <:col :let={p} label="Checkers">{p["checker_count"]}</:col>
          <:col :let={p} label="Last Seen">{format_datetime(p["last_seen"])}</:col>
        </.table>
      </div>
    </Layouts.app>
    """
  end

  defp format_datetime(nil), do: ""
  defp format_datetime(value) when is_binary(value), do: value
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

  defp maybe_sync_builder_query(socket) do
    if socket.assigns.srql_builder_supported and socket.assigns.srql_builder_sync do
      assign(socket, :srql_query_draft, Builder.build(socket.assigns.srql_builder))
    else
      socket
    end
  end

  defp extract_limit_from_srql(query, fallback) when is_binary(query) do
    case Regex.run(~r/(?:^|\s)limit:(\d+)(?:\s|$)/, query) do
      [_, raw] -> parse_limit(raw)
      _ -> fallback
    end
  end

  defp extract_limit_from_srql(_query, fallback), do: fallback

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
