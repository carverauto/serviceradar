defmodule ServiceRadarWebNGWeb.CameraLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.CameraMultiview
  alias ServiceRadarWebNGWeb.CameraRelayComponents

  @camera_relay_poll_interval_ms 1_000

  @impl true
  def mount(%{"camera_source_id" => camera_source_id}, _session, socket) do
    socket =
      socket
      |> assign(:camera_source_id, camera_source_id)
      |> assign(:page_title, "Camera Feed")
      |> assign(:current_path, "/cameras/#{camera_source_id}")
      |> assign(:srql, %{enabled: false, page_path: "/cameras/#{camera_source_id}"})
      |> assign(:camera_tile, nil)

    socket =
      if connected?(socket) do
        open_camera_source(socket, camera_source_id)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <div class="sr-camera-page sr-camera-detail-page">
        <header class="sr-camera-toolbar">
          <div>
            <h2>{(@camera_tile && @camera_tile.label) || "Camera Feed"}</h2>
            <p>{(@camera_tile && @camera_tile.detail) || "Opening live camera relay."}</p>
          </div>
          <.link href={~p"/cameras"} class="sr-ops-button">Back to Multiview</.link>
        </header>

        <section class="sr-camera-detail">
          <CameraRelayComponents.relay_player
            :if={@camera_tile && @camera_tile.session}
            session={@camera_tile.session}
            id_prefix="camera-detail-relay"
          />
          <div :if={!@camera_tile || !@camera_tile.session} class="sr-camera-cell-empty">
            <.icon name="hero-video-camera-slash" class="size-10" />
            <span>{(@camera_tile && @camera_tile.error) || "No live relay available"}</span>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_info({:refresh_camera_detail_relay_session, relay_session_id}, socket) do
    tile = socket.assigns.camera_tile

    tile =
      if CameraMultiview.session_id(tile) == relay_session_id do
        refreshed = CameraMultiview.refresh_tile_session(socket.assigns.current_scope, tile)
        schedule_camera_refresh(refreshed)
        refreshed
      else
        tile
      end

    {:noreply, assign(socket, :camera_tile, tile)}
  end

  defp open_camera_source(socket, camera_source_id) do
    if RBAC.can?(socket.assigns.current_scope, "devices.view") do
      tile = CameraMultiview.open_source_preview(socket.assigns.current_scope, camera_source_id)
      schedule_camera_refresh(tile)
      assign(socket, :camera_tile, tile)
    else
      assign(socket, :camera_tile, %{label: "Camera", detail: "Primary stream", session: nil, error: "Not authorized"})
    end
  end

  defp schedule_camera_refresh(tile) do
    case CameraMultiview.session_id(tile) do
      session_id when is_binary(session_id) ->
        Process.send_after(
          self(),
          {:refresh_camera_detail_relay_session, session_id},
          camera_relay_poll_interval_ms()
        )

      _ ->
        :ok
    end
  end

  defp camera_relay_poll_interval_ms do
    case Application.get_env(:serviceradar_web_ng, :camera_relay_poll_interval_ms, @camera_relay_poll_interval_ms) do
      value when is_integer(value) and value > 0 -> value
      _other -> @camera_relay_poll_interval_ms
    end
  end
end
