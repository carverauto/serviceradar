defmodule ServiceRadarWebNGWeb.ServiceLive.Index do
  @moduledoc """
  The `/services` catalog.

  The page renders its shell at once and reads nothing in `mount/3` or
  `handle_params/3`. Each load round starts two reads concurrently, outside the
  LiveView process: the active plugin service state (the cards' primary source)
  and the SRQL service status list (their fallback when there is no plugin
  state). Cards appear as soon as the source they come from arrives, and each
  source reports its own failure.

  Viewing the page writes nothing. Plugin assignment service state is
  reconciled where assignments change and by
  `ServiceRadar.Observability.PluginServiceStateReconcileWorker`.
  """
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStatePubSub
  alias ServiceRadar.Observability.ServiceStatusPubSub
  alias ServiceRadarWebNGWeb.ServiceLive.Index.Data
  alias ServiceRadarWebNGWeb.ServiceLive.Index.View
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  require Logger

  @default_limit 50
  @max_limit 200
  @list_opts [default_limit: @default_limit, max_limit: @max_limit]
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
     |> assign(:refresh_queued, false)
     |> assign(:list_request, nil)
     |> assign(:plugin_source, :loading)
     |> assign(:list_source, :loading)
     |> assign(:tab_loading, true)
     |> SRQLPage.init("services", default_limit: @default_limit)
     |> stream(:service_cards, [])}
  end

  @impl true
  def handle_params(params, uri, socket) do
    params = Data.ensure_default_query(params, @default_query)

    socket =
      socket
      |> assign(:params, params)
      |> assign(:current_uri, uri)
      |> SRQLPage.sync_from_params(params, uri, @list_opts)

    if connected?(socket) do
      {:noreply, socket |> assign(:tab_loading, true) |> start_load()}
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
    socket = assign(socket, :refresh_pending, false)

    # A refresh never overlaps a running round: it waits for that round to
    # finish, because the running round may have read before this change.
    if loading?(socket) do
      {:noreply, assign(socket, :refresh_queued, true)}
    else
      {:noreply, start_load(socket)}
    end
  end

  @impl true
  def handle_async(:plugin_view, {:ok, {:ok, :empty}}, socket) do
    {:noreply, socket |> assign(:plugin_source, :empty) |> present() |> finish_round()}
  end

  def handle_async(:plugin_view, {:ok, {:ok, view}}, socket) do
    {:noreply, socket |> assign(:plugin_source, {:ok, view}) |> present() |> finish_round()}
  end

  def handle_async(:plugin_view, {:ok, {:error, reason}}, socket) do
    {:noreply, plugin_view_failed(socket, reason)}
  end

  def handle_async(:plugin_view, {:exit, reason}, socket) do
    {:noreply, plugin_view_failed(socket, reason)}
  end

  def handle_async(:services_list, {:ok, {result, view}}, socket) do
    source =
      case result do
        {_results, nil, _viz, _pagination} -> {:ok, view}
        {_results, error, _viz, _pagination} -> {:error, error}
      end

    {:noreply,
     socket
     |> SRQLPage.apply_list_result(socket.assigns.list_request, result)
     |> assign(:list_source, source)
     |> present_list()
     |> finish_round()}
  end

  def handle_async(:services_list, {:exit, reason}, socket) do
    Logger.warning("Service status list load failed: #{inspect(reason)}")
    error = "Recent service status could not be loaded."

    {:noreply,
     socket
     |> SRQLPage.apply_list_result(socket.assigns.list_request, {[], error, nil, %{}})
     |> assign(:list_source, {:error, error})
     |> present_list()
     |> finish_round()}
  end

  @impl true
  def render(assigns), do: View.render(assigns)

  # Starts one load round. A round already running is cancelled: its results
  # describe a query or a moment the page no longer shows.
  defp start_load(socket) do
    request = SRQLPage.list_request(socket, socket.assigns.params, :services, @list_opts)
    scope = socket.assigns.current_scope

    socket
    |> cancel_async(:plugin_view)
    |> cancel_async(:services_list)
    |> assign(:list_request, request)
    |> assign(:plugin_source, :loading)
    |> assign(:list_source, :loading)
    |> assign(:refresh_queued, false)
    |> start_async(:plugin_view, fn -> Data.load_plugin_view(scope) end)
    |> start_async(:services_list, fn ->
      {services, _error, _viz, _pagination} = result = SRQLPage.fetch_list(request)
      {result, Data.fallback_view(services, scope)}
    end)
  end

  defp plugin_view_failed(socket, reason) do
    Logger.warning("Active plugin service state load failed: #{inspect(reason)}")

    socket
    |> assign(:plugin_source, {:error, "Plugin service state could not be loaded."})
    |> present()
    |> finish_round()
  end

  # Plugin state is the primary source, so a list result only changes what is
  # shown when there is no plugin state to show.
  defp present_list(%{assigns: %{plugin_source: {:ok, _view}}} = socket), do: socket
  defp present_list(socket), do: present(socket)

  defp present(%{assigns: %{plugin_source: {:ok, view}}} = socket), do: show_view(socket, view)

  defp present(%{assigns: %{plugin_source: :loading}} = socket), do: socket

  defp present(%{assigns: %{list_source: {:ok, view}}} = socket), do: show_view(socket, view)

  defp present(%{assigns: %{list_source: {:error, _error}}} = socket) do
    show_view(socket, %{summary: empty_summary(), cards: []})
  end

  defp present(socket), do: socket

  defp show_view(socket, %{summary: summary, cards: cards}) do
    socket
    |> assign(:summary, summary)
    |> assign(:tab_loading, false)
    |> stream(:service_cards, cards, reset: true)
  end

  defp finish_round(socket) do
    if socket.assigns.refresh_queued and not loading?(socket) do
      start_load(socket)
    else
      socket
    end
  end

  defp loading?(socket) do
    socket.assigns.plugin_source == :loading or socket.assigns.list_source == :loading
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
