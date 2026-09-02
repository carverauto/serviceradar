defmodule ServiceRadarWebNGWeb.ServiceLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Observability.ServiceStatusPubSub
  alias ServiceRadarWebNGWeb.ServiceLive.Display
  alias ServiceRadarWebNGWeb.ServiceLive.Service
  alias ServiceRadarWebNGWeb.ServiceLive.Show.History
  alias ServiceRadarWebNGWeb.ServiceLive.Show.Query
  alias ServiceRadarWebNGWeb.ServiceLive.Show.View
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 200
  @history_per_page 20
  @refresh_debounce_ms 750

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ServiceStatusPubSub.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, "Service Check")
     |> assign(:service, nil)
     |> assign(:details, %{})
     |> assign(:display, [])
     |> assign(:display_contract, %{})
     |> assign(:schema_version, nil)
     |> assign(:query, "")
     |> assign(:history, [])
     |> assign(:history_page, 1)
     |> assign(:history_per_page, @history_per_page)
     |> assign(:history_params, %{})
     |> assign(:limit, @default_limit)
     |> assign(:refresh_pending, false)
     |> SRQLPage.init("services", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    query = params |> Map.get("q") |> Query.normalize() || Query.build(params, @default_limit)

    socket =
      socket
      |> assign(:query, query)
      |> assign(:history_page, 1)
      |> assign(:history_params, params)
      |> History.load(query, uri, params, @default_limit)
      |> assign_selected_service(params)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:service_status_updated, status}, socket) do
    {:noreply, apply_service_status(socket, status)}
  end

  def handle_info({:service_statuses_updated, statuses}, socket) when is_list(statuses) do
    {:noreply, Enum.reduce(statuses, socket, &apply_service_status(&2, &1))}
  end

  def handle_info(:refresh_service_details, socket) do
    {:noreply, refresh_service_details(socket)}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/services/check")}
  end

  def handle_event("srql_reset", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_reset", params, fallback_path: "/services/check")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "services")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: "/services/check")}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "services")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "services")}
  end

  def handle_event("history_page", %{"page" => page}, socket) do
    page =
      case Integer.parse(page) do
        {number, _remainder} -> number
        _ -> 1
      end

    {:noreply, assign(socket, :history_page, page)}
  end

  @impl true
  def render(assigns), do: View.render(assigns)

  defp assign_selected_service(socket, params) do
    service = Query.pick_service(socket.assigns.history, params)
    {details, display, contract, schema_version} = Display.for_service(service, socket.assigns.current_scope)

    socket
    |> assign(:service, service)
    |> assign(:details, details)
    |> assign(:display, display)
    |> assign(:display_contract, contract)
    |> assign(:schema_version, schema_version)
  end

  defp refresh_service_details(socket) do
    query = socket.assigns.query || Query.build(%{}, @default_limit)
    uri = socket.assigns.srql[:page_path] || "/services/check"
    params = history_params(socket)

    lookup_params =
      case socket.assigns.service do
        %{} = service -> Service.details_params(service)
        _ -> %{}
      end

    socket
    |> History.load(query, uri, params, @default_limit)
    |> assign_selected_service(lookup_params)
    |> assign(:refresh_pending, false)
  end

  defp history_params(socket) do
    case socket.assigns.history_params do
      %{} = stored when map_size(stored) > 0 ->
        stored

      _ ->
        case socket.assigns.service do
          %{} = service -> Service.details_params(service)
          _ -> %{}
        end
    end
  end

  defp apply_service_status(socket, status) do
    case History.apply_status(socket, status, @default_limit) do
      {:matched, socket} -> schedule_refresh(socket)
      {:ignored, socket} -> socket
    end
  end

  defp schedule_refresh(socket) do
    if socket.assigns.refresh_pending do
      socket
    else
      Process.send_after(self(), :refresh_service_details, @refresh_debounce_ms)
      assign(socket, :refresh_pending, true)
    end
  end
end
