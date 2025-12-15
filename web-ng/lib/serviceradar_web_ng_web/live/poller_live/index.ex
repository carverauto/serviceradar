defmodule ServiceRadarWebNGWeb.PollerLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.Infrastructure

  @default_limit 200
  @max_limit 500

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Pollers")
     |> assign(:limit, @default_limit)
     |> stream(:pollers, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    limit = parse_limit(params["limit"])
    pollers = Infrastructure.list_pollers(limit: limit)

    {:noreply,
     socket
     |> assign(:limit, limit)
     |> stream(:pollers, pollers, reset: true)}
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
          <:subtitle>Showing up to {@limit} pollers from `pollers`.</:subtitle>
          <:actions>
            <.link class="btn btn-ghost btn-sm" patch={~p"/pollers?limit=#{@limit}"}>Refresh</.link>
          </:actions>
        </.header>

        <.table id="pollers" rows={@streams.pollers}>
          <:col :let={{_id, p}} label="ID">{p.id}</:col>
          <:col :let={{_id, p}} label="Status">{p.status}</:col>
          <:col :let={{_id, p}} label="Healthy?">{p.is_healthy}</:col>
          <:col :let={{_id, p}} label="Agents">{p.agent_count}</:col>
          <:col :let={{_id, p}} label="Checkers">{p.checker_count}</:col>
          <:col :let={{_id, p}} label="Last Seen">{format_datetime(p.last_seen)}</:col>
        </.table>
      </div>
    </Layouts.app>
    """
  end

  defp format_datetime(nil), do: ""
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
end
