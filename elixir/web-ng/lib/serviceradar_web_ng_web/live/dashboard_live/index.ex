defmodule ServiceRadarWebNGWeb.DashboardLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.CameraMultiview
  alias ServiceRadarWebNGWeb.DashboardLive.Data
  alias ServiceRadarWebNGWeb.DashboardLive.Index.Common
  alias ServiceRadarWebNGWeb.DashboardLive.Index.Page

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
        scope = socket.assigns.current_scope

        socket
        |> start_async(:dashboard_load, fn -> Data.load(scope) end)
        |> start_async(:fieldsurvey_summary_load, fn -> Data.load_survey_summary(scope) end)
        |> start_async(:dashboard_packages_load, fn -> dashboard_package_instances(scope) end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_async(:dashboard_load, {:ok, dashboard_assigns}, socket) do
    dashboard_assigns = preserve_loaded_survey_summary(socket, dashboard_assigns)

    socket =
      socket
      |> assign_dashboard(dashboard_assigns)
      |> maybe_start_camera_previews_async()

    {:noreply, socket}
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
    {:noreply, assign_survey_summary(socket, survey_summary)}
  end

  def handle_async(:dashboard_packages_load, {:ok, instances}, socket) do
    {:noreply, assign_dashboard_package_instances(socket, instances)}
  end

  def handle_async(_name, {:exit, _reason}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns), do: Page.render(assigns)

  @impl true
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

  defp assign_survey_summary(socket, survey_summary) do
    survey_sparkline =
      socket.assigns.kpi_cards
      |> Enum.find(%{}, &(&1.title == "Wi-Fi Coverage"))
      |> Map.get(:sparkline, [])

    survey_card = Data.survey_kpi_card(survey_summary, survey_sparkline)

    kpi_cards =
      Enum.map(socket.assigns.kpi_cards, fn
        %{title: "Wi-Fi Coverage"} -> survey_card
        card -> card
      end)

    socket
    |> assign(:survey_summary, survey_summary)
    |> assign(:kpi_cards, kpi_cards)
  end

  defp preserve_loaded_survey_summary(socket, dashboard_assigns) do
    current = socket.assigns.survey_summary
    incoming = Map.get(dashboard_assigns, :survey_summary)

    if Common.survey_raster_cell_count(current) > Common.survey_raster_cell_count(incoming) do
      survey_card = Data.survey_kpi_card(current, survey_sparkline_from(dashboard_assigns))

      dashboard_assigns
      |> Map.put(:survey_summary, current)
      |> Map.put(
        :kpi_cards,
        replace_survey_kpi_card(Map.get(dashboard_assigns, :kpi_cards, []), survey_card)
      )
    else
      dashboard_assigns
    end
  end

  defp survey_sparkline_from(%{kpi_cards: kpi_cards}) when is_list(kpi_cards) do
    kpi_cards
    |> Enum.find(%{}, &(&1.title == "Wi-Fi Coverage"))
    |> Map.get(:sparkline, [])
  end

  defp survey_sparkline_from(_assigns), do: []

  defp replace_survey_kpi_card(kpi_cards, survey_card) when is_list(kpi_cards) do
    Enum.map(kpi_cards, fn
      %{title: "Wi-Fi Coverage"} -> survey_card
      card -> card
    end)
  end

  defp replace_survey_kpi_card(_kpi_cards, _survey_card), do: []

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
