defmodule ServiceRadarWebNGWeb.DeviceLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.Inventory

  @default_limit 100
  @max_limit 500

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Devices")
     |> assign(:limit, @default_limit)
     |> stream(:devices, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    limit = parse_limit(params["limit"])
    devices = Inventory.list_devices(limit: limit)

    {:noreply,
     socket
     |> assign(:limit, limit)
     |> stream(:devices, devices, reset: true)}
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
          Devices
          <:subtitle>Showing up to {@limit} devices from `unified_devices`.</:subtitle>
          <:actions>
            <.link class="btn btn-ghost btn-sm" patch={~p"/devices?limit=#{@limit}"}>Refresh</.link>
          </:actions>
        </.header>

        <.table id="devices" rows={@streams.devices}>
          <:col :let={{_id, d}} label="ID">{d.id}</:col>
          <:col :let={{_id, d}} label="Hostname">{d.hostname}</:col>
          <:col :let={{_id, d}} label="IP">{d.ip}</:col>
          <:col :let={{_id, d}} label="Type">{d.device_type}</:col>
          <:col :let={{_id, d}} label="Available?">{d.is_available}</:col>
          <:col :let={{_id, d}} label="Last Seen">{format_datetime(d.last_seen)}</:col>
        </.table>
      </div>
    </Layouts.app>
    """
  end

  defp format_datetime(nil), do: ""
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
end
