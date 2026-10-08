defmodule ServiceRadarWebNGWeb.ServiceLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStatePubSub
  alias ServiceRadar.Observability.ServiceStatusPubSub
  alias ServiceRadarWebNGWeb.ServiceLive.Index.Data
  alias ServiceRadarWebNGWeb.ServiceLive.Index.View
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 50
  @max_limit 200
  @refresh_debounce_ms 5_000
  @default_query "in:services time:last_1h sort:timestamp:desc limit:500"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ServiceStatusPubSub.subscribe()
      ServiceStatePubSub.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, "Services")
     |> assign(:services, [])
     |> assign(:summary, empty_summary())
     |> assign(:limit, @default_limit)
     |> assign(:params, %{})
     |> assign(:refresh_pending, false)
     |> assign(:service_state_reconciled, false)
     |> assign(:tab_loading, true)
     |> SRQLPage.init("services", default_limit: @default_limit)
     |> stream(:service_cards, [])}
  end

  @impl true
  def handle_params(params, uri, socket) do
    # Defer reads and reconciliation until after the connected shell renders.
    params = Data.ensure_default_query(params, @default_query)

    socket =
      socket
      |> assign(:params, params)
      |> assign(:current_uri, uri)
      |> SRQLPage.sync_from_params(params, uri,
        default_limit: @default_limit,
        max_limit: @max_limit
      )

    if connected?(socket) do
      {:noreply,
       socket
       |> assign(:tab_loading, true)
       |> tap(fn _ -> send(self(), {:load_services_data, params}) end)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/services")}
  end

  def handle_event("srql_reset", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_reset", params, fallback_path: "/services")}
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
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: "/services")}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "services")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "services")}
  end

  @impl true
  def handle_info({:load_services_data, params}, socket) do
    if Map.get(socket.assigns, :params, %{}) == params do
      socket =
        socket
        |> maybe_reconcile_plugin_assignments()
        |> load_services(params, Map.get(socket.assigns, :current_uri))
        |> update_service_cards()

      {:noreply, assign(socket, :tab_loading, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:service_status_updated, _status}, socket) do
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info({:service_statuses_updated, _statuses}, socket) do
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info({:service_state_updated, %ServiceState{service_type: "plugin"}}, socket) do
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info({:service_state_updated, %{service_type: "plugin"}}, socket) do
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info({:service_state_updated, _state}, socket), do: {:noreply, socket}

  def handle_info(:refresh_services, socket) do
    params = Data.ensure_default_query(socket.assigns.params || %{}, @default_query)
    uri = socket.assigns |> Map.get(:srql, %{}) |> Map.get(:page_path) || "/services"

    {:noreply,
     socket
     |> load_services(params, uri)
     |> update_service_cards()
     |> assign(:refresh_pending, false)}
  end

  @impl true
  def render(assigns), do: View.render(assigns)

  defp load_services(socket, params, uri) do
    socket
    |> SRQLPage.load_list(params, uri, :services,
      default_limit: @default_limit,
      max_limit: @max_limit
    )
    |> assign(:params, params)
  end

  defp update_service_cards(socket) do
    states = Data.load_plugin_states(socket.assigns.current_scope)
    summary = Data.summary(states, socket.assigns.services)
    cards = Data.cards(states, socket.assigns.services, socket.assigns.current_scope)

    socket
    |> assign(:summary, summary)
    |> stream(:service_cards, cards, reset: true)
  end

  defp maybe_reconcile_plugin_assignments(socket) do
    if socket.assigns.service_state_reconciled do
      socket
    else
      _ = Data.reconcile_plugin_assignments()
      assign(socket, :service_state_reconciled, true)
    end
  end

  defp schedule_refresh(socket) do
    if socket.assigns.refresh_pending do
      socket
    else
      Process.send_after(self(), :refresh_services, @refresh_debounce_ms)
      assign(socket, :refresh_pending, true)
    end
  end

  defp empty_summary do
    %{total: 0, available: 0, unavailable: 0, by_check: %{}, check_count: 0, last_updated: nil}
  end
end
