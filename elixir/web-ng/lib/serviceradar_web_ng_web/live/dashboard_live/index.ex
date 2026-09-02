defmodule ServiceRadarWebNGWeb.DashboardLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.CameraMultiview
  alias ServiceRadarWebNGWeb.DashboardLive.Data
  alias ServiceRadarWebNGWeb.DashboardLive.EventRange
  alias ServiceRadarWebNGWeb.DashboardLive.Index.Page
  alias ServiceRadarWebNGWeb.ObservabilityPaths

  require Logger

  @camera_preview_limit 4
  @camera_relay_poll_interval_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Unified Operations Dashboard")
      |> assign(:current_path, "/dashboard")
      |> assign(:camera_preview_tiles, [])
      |> assign(:dashboard_package_instances, [])
      |> assign_dashboard(Data.empty())

    socket =
      if connected?(socket) do
        start_dashboard_slices(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_async(:inventory_load, {:ok, slice}, socket) do
    {:noreply, put_sources(socket, slice, loaded: [inventory: true], kpi_loading: [assets: false])}
  end

  def handle_async(:health_load, {:ok, slice}, socket) do
    {:noreply, put_sources(socket, slice, loaded: [health: true], kpi_loading: [network_health: false])}
  end

  def handle_async(:camera_summary_load, {:ok, slice}, socket) do
    {:noreply, put_sources(socket, slice, loaded: [camera: true], kpi_loading: [camera: false])}
  end

  def handle_async(:alerts_summary_load, {:ok, slice}, socket) do
    {:noreply, put_sources(socket, slice, loaded: [siem: true], kpi_loading: [alerts: false, threat: false])}
  end

  def handle_async(:events_summary_load, {:ok, slice}, socket) do
    {:noreply, put_sources(socket, slice, loaded: [security_events: true], kpi_loading: [events: false, threat: false])}
  end

  def handle_async(:netflow_load, {:ok, slice}, socket) do
    {:noreply, put_sources(socket, slice, loaded: [netflow: true])}
  end

  def handle_async(:mtr_load, {:ok, slice}, socket) do
    {:noreply, put_sources(socket, slice, loaded: [mtr: true])}
  end

  def handle_async(:traces_load, {:ok, slice}, socket) do
    {:noreply, put_sources(socket, slice)}
  end

  def handle_async(:security_trend_load, {:ok, slice}, socket) do
    {:noreply, put_sources(socket, slice)}
  end

  def handle_async(:sparklines_load, {:ok, slice}, socket) do
    {:noreply, put_sources(socket, slice)}
  end

  def handle_async(:alert_feed_load, {:ok, slice}, socket) do
    {:noreply, put_sources(socket, slice)}
  end

  def handle_async(:threat_intel_load, {:ok, slice}, socket) do
    {:noreply, put_sources(socket, slice)}
  end

  def handle_async(:vulnerable_assets_load, {:ok, slice}, socket) do
    {:noreply, put_sources(socket, slice, loaded: [vulnerable_assets: true])}
  end

  def handle_async(:virtualization_load, {:ok, slice}, socket) do
    {:noreply, put_sources(socket, slice)}
  end

  def handle_async(:camera_previews_open, {:ok, tiles}, socket) when is_list(tiles) do
    Enum.each(tiles, &schedule_camera_preview_refresh/1)

    {:noreply, assign(socket, :camera_preview_tiles, tiles)}
  end

  def handle_async(:camera_previews_open, {:ok, result}, socket) do
    Logger.warning("Ignoring invalid dashboard camera preview result: #{inspect(result)}")
    {:noreply, assign(socket, :camera_preview_tiles, [])}
  end

  def handle_async(:camera_previews_open, {:exit, reason}, socket) do
    Logger.warning("Dashboard camera preview startup failed: #{inspect(reason)}")
    {:noreply, assign(socket, :camera_preview_tiles, [])}
  end

  def handle_async(:fieldsurvey_summary_load, {:ok, survey_summary}, socket) do
    {:noreply,
     put_sources(socket, %{survey_summary: survey_summary},
       loaded: [fieldsurvey: true],
       kpi_loading: [survey: false]
     )}
  end

  def handle_async(:dashboard_packages_load, {:ok, instances}, socket) do
    {:noreply, assign_dashboard_package_instances(socket, instances)}
  end

  def handle_async(name, {:exit, reason}, socket) do
    Logger.warning("Dashboard slice #{inspect(name)} failed: #{inspect(reason)}")
    {:noreply, fail_dashboard_slice(socket, name)}
  end

  @impl true
  def render(assigns), do: Page.render(assigns)

  @impl true
  def handle_event("select_events_range", params, socket) do
    case EventRange.selection(socket.assigns.security_trend, params) do
      {:ok, {start_time, end_time}} ->
        target = ObservabilityPaths.events_range_path(start_time, end_time)
        {:noreply, push_navigate(socket, to: target)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("select_map_view", %{"map_view" => "dashboard:" <> route_slug}, socket) do
    if dashboard_package_route?(socket.assigns.dashboard_package_instances, route_slug) do
      {:noreply, push_navigate(socket, to: ~p"/dashboards/#{route_slug}")}
    else
      {:noreply, assign(socket, :map_view, "netflow")}
    end
  end

  def handle_event("select_map_view", %{"map_view" => map_view}, socket) do
    {:noreply, assign(socket, :map_view, normalize_map_view(map_view))}
  end

  def handle_event("select_map_view", %{"value" => map_view}, socket) do
    handle_event("select_map_view", %{"map_view" => map_view}, socket)
  end

  @impl true
  def handle_info({_ref, {:access_token_present, _field, _result}}, socket) do
    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    {:noreply, socket}
  end

  def handle_info({:refresh_dashboard_camera_relay_session, relay_session_id}, socket) do
    tiles =
      Enum.map(socket.assigns.camera_preview_tiles, fn tile ->
        if CameraMultiview.session_id(tile) == relay_session_id do
          refreshed = CameraMultiview.refresh_tile_session(socket.assigns.current_scope, tile)
          schedule_camera_preview_refresh(refreshed)
          refreshed
        else
          tile
        end
      end)

    {:noreply, assign(socket, :camera_preview_tiles, tiles)}
  end

  defp dashboard_package_instances(scope) do
    [scope: scope]
    |> Dashboards.enabled_instances()
    |> Enum.filter(&(&1.placement in [:dashboard, :map]))
    |> Enum.sort_by(fn instance ->
      {not instance.is_default, String.downcase(instance.name || instance.route_slug || "")}
    end)
  rescue
    _ -> []
  end

  defp assign_dashboard_package_instances(socket, instances) do
    socket =
      assign(socket, :dashboard_package_instances, instances)

    case Enum.find(instances, &(&1.placement == :map and &1.is_default)) do
      nil -> socket
      instance -> assign(socket, :map_view, "dashboard:#{instance.route_slug}")
    end
  end

  defp dashboard_package_route?(instances, route_slug) when is_binary(route_slug) do
    Enum.any?(instances, &(&1.route_slug == route_slug))
  end

  defp dashboard_package_route?(_instances, _route_slug), do: false

  defp assign_dashboard(socket, dashboard_assigns) when is_map(dashboard_assigns) do
    dashboard_assigns =
      case socket.assigns[:map_view] do
        "dashboard:" <> _route_slug = current_map_view ->
          Map.put(dashboard_assigns, :map_view, current_map_view)

        _other ->
          ensure_valid_map_view(dashboard_assigns)
      end

    Enum.reduce(dashboard_assigns, socket, fn {key, value}, acc ->
      assign(acc, key, value)
    end)
  end

  defp ensure_valid_map_view(assigns) when is_map(assigns) do
    map_view = Map.get(assigns, :map_view, "netflow")

    valid_view =
      if map_view == "netflow" do
        "netflow"
      else
        "netflow"
      end

    Map.put(assigns, :map_view, valid_view)
  end

  defp start_dashboard_slices(socket) do
    scope = socket.assigns.current_scope
    time_window = socket.assigns.time_window

    socket
    |> start_async(:inventory_load, fn -> Data.load_inventory(scope) end)
    |> start_async(:health_load, fn -> Data.load_health(scope, time_window) end)
    |> start_async(:camera_summary_load, fn -> Data.load_camera_summary(scope) end)
    |> start_async(:alerts_summary_load, fn -> Data.load_alerts_summary(scope) end)
    |> start_async(:events_summary_load, fn -> Data.load_events_summary(time_window) end)
    |> start_async(:netflow_load, fn -> Data.load_netflow_map(scope, time_window: time_window) end)
    |> start_async(:mtr_load, fn -> Data.load_mtr(time_window) end)
    |> start_async(:traces_load, fn -> Data.load_traces(scope, time_window) end)
    |> start_async(:security_trend_load, fn -> Data.load_security_trend(time_window) end)
    |> start_async(:sparklines_load, fn -> Data.load_sparklines(time_window) end)
    |> start_async(:alert_feed_load, fn -> Data.load_alert_feed(time_window) end)
    |> start_async(:threat_intel_load, fn -> Data.load_threat_intel() end)
    |> start_async(:vulnerable_assets_load, fn -> Data.load_vulnerable_assets() end)
    |> start_async(:virtualization_load, fn -> Data.load_virtualization(scope) end)
    |> start_async(:fieldsurvey_summary_load, fn -> Data.load_survey_summary(scope) end)
    |> start_async(:dashboard_packages_load, fn -> dashboard_package_instances(scope) end)
    |> maybe_start_camera_previews_async()
  end

  defp put_sources(socket, updates, opts \\ []) when is_map(updates) do
    loaded = Map.merge(socket.assigns.loaded, Map.new(Keyword.get(opts, :loaded, [])))
    kpi_loading = Map.merge(socket.assigns.kpi_loading, Map.new(Keyword.get(opts, :kpi_loading, [])))

    socket =
      updates
      |> Enum.reduce(socket, fn {key, value}, acc -> assign(acc, key, value) end)
      |> assign(:loaded, loaded)
      |> assign(:kpi_loading, kpi_loading)

    assign_dashboard(socket, Data.derive(socket.assigns))
  end

  defp fail_dashboard_slice(socket, name) do
    {loaded, kpi_loading} = slice_failure_flags(name)

    put_sources(socket, %{}, loaded: loaded, kpi_loading: kpi_loading)
  end

  defp slice_failure_flags(:inventory_load), do: {[inventory: true], [assets: false]}
  defp slice_failure_flags(:health_load), do: {[health: true], [network_health: false]}
  defp slice_failure_flags(:camera_summary_load), do: {[camera: true], [camera: false]}
  defp slice_failure_flags(:alerts_summary_load), do: {[siem: true], [alerts: false, threat: false]}
  defp slice_failure_flags(:events_summary_load), do: {[security_events: true], [events: false, threat: false]}
  defp slice_failure_flags(:netflow_load), do: {[netflow: true], []}
  defp slice_failure_flags(:mtr_load), do: {[mtr: true], []}
  defp slice_failure_flags(:vulnerable_assets_load), do: {[vulnerable_assets: true], []}
  defp slice_failure_flags(:fieldsurvey_summary_load), do: {[fieldsurvey: true], [survey: false]}
  defp slice_failure_flags(_name), do: {[], []}

  defp maybe_start_camera_previews_async(socket) do
    if RBAC.can?(socket.assigns.current_scope, "devices.view") do
      scope = socket.assigns.current_scope

      start_async(socket, :camera_previews_open, fn ->
        CameraMultiview.open_preview_tiles(scope, @camera_preview_limit)
      end)
    else
      socket
    end
  end

  defp schedule_camera_preview_refresh(tile) do
    case CameraMultiview.session_id(tile) do
      session_id when is_binary(session_id) ->
        Process.send_after(
          self(),
          {:refresh_dashboard_camera_relay_session, session_id},
          camera_relay_poll_interval_ms()
        )

      _ ->
        :ok
    end
  end

  defp camera_relay_poll_interval_ms do
    case Application.get_env(
           :serviceradar_web_ng,
           :camera_relay_poll_interval_ms,
           @camera_relay_poll_interval_ms
         ) do
      value when is_integer(value) and value > 0 -> value
      _other -> @camera_relay_poll_interval_ms
    end
  end

  defp normalize_map_view("dashboard:" <> route_slug) when route_slug != "", do: "dashboard:" <> route_slug

  defp normalize_map_view(_), do: "netflow"
end
