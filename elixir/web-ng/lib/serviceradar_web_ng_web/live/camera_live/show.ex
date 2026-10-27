defmodule ServiceRadarWebNGWeb.CameraLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.CameraMultiview
  alias ServiceRadarWebNGWeb.CameraRelayComponents

  require Logger

  @impl true
  def mount(%{"camera_source_id" => camera_source_id}, _session, socket) do
    socket =
      socket
      |> assign(:camera_source_id, camera_source_id)
      |> assign(:page_title, "Camera Feed")
      |> assign(:current_path, "/cameras/#{camera_source_id}")
      |> assign(:srql, %{enabled: false, page_path: "/cameras/#{camera_source_id}"})
      |> assign(:camera_tile, nil)
      |> assign(:camera_relay_subscriptions, MapSet.new())

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
          <.link
            :if={
              RBAC.can?(@current_scope, "devices.view") &&
                RBAC.can?(@current_scope, "devices.cameras.recordings.view")
            }
            navigate={~p"/cameras/#{@camera_source_id}/recordings"}
            class="sr-ops-button"
          >Recordings</.link>
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
  # Fallback timer: re-read the session and re-arm.
  def handle_info({:refresh_camera_detail_relay_session, relay_session_id}, socket) do
    {:noreply, refresh_camera_tile(socket, relay_session_id, rearm: true)}
  end

  # The relay published a state change for this page's session.
  def handle_info({:camera_relay_state, %{relay_session_id: relay_session_id}}, socket)
      when is_binary(relay_session_id) do
    {:noreply, refresh_camera_tile(socket, relay_session_id, rearm: false)}
  end

  def handle_info({:camera_relay_state, _payload}, socket), do: {:noreply, socket}

  # Player channels consume these events from the shared relay topic.
  def handle_info({:camera_relay_webrtc_closed, _payload}, socket), do: {:noreply, socket}
  def handle_info({:camera_relay_chunk, _payload}, socket), do: {:noreply, socket}
  def handle_info({:camera_relay_viewer_chunk, _payload}, socket), do: {:noreply, socket}

  def handle_info(message, socket) do
    Logger.debug("Ignoring unexpected camera detail message: #{inspect(message, limit: 20, printable_limit: 200)}")
    {:noreply, socket}
  end

  @impl true
  def handle_async(:camera_source_open, {:ok, tile}, socket) do
    schedule_camera_refresh(tile)
    {:noreply, socket |> assign(:camera_tile, tile) |> subscribe_camera_tile(tile)}
  end

  def handle_async(:camera_source_open, {:exit, reason}, socket) do
    Logger.warning("Camera relay open failed: #{inspect(reason, limit: 20, printable_limit: 200)}")

    {:noreply,
     assign(socket, :camera_tile, %{
       label: "Camera",
       detail: "Primary stream",
       session: nil,
       error: "Camera relay session could not be opened"
     })}
  end

  # Opening the relay session runs in a task, as on the multiview, so the page
  # renders before the session is requested from the agent.
  defp open_camera_source(socket, camera_source_id) do
    if RBAC.can?(socket.assigns.current_scope, "devices.cameras.view") do
      scope = socket.assigns.current_scope

      socket
      |> assign(:camera_tile, %{
        label: "Camera Feed",
        detail: "Opening live camera relay.",
        session: nil,
        error: "Opening camera relay"
      })
      |> start_async(:camera_source_open, fn ->
        CameraMultiview.open_source_preview(scope, camera_source_id)
      end)
    else
      assign(socket, :camera_tile, %{label: "Camera", detail: "Primary stream", session: nil, error: "Not authorized"})
    end
  end

  # The page follows relay state broadcasts. The timer is only a fallback for
  # a missed broadcast and for a session stuck opening; it used to re-read the
  # session from the database every second.
  defp refresh_camera_tile(socket, relay_session_id, rearm: rearm?) do
    tile = socket.assigns.camera_tile

    if CameraMultiview.session_id(tile) == relay_session_id do
      refreshed = CameraMultiview.refresh_tile_session(socket.assigns.current_scope, tile)

      if rearm? or CameraMultiview.session_id(refreshed) != relay_session_id,
        do: schedule_camera_refresh(refreshed)

      socket
      |> assign(:camera_tile, refreshed)
      |> subscribe_camera_tile(refreshed)
    else
      socket
    end
  end

  defp subscribe_camera_tile(socket, tile) do
    subscribed = CameraMultiview.subscribe_relay_state(socket.assigns.camera_relay_subscriptions, tile)
    assign(socket, :camera_relay_subscriptions, subscribed)
  end

  defp schedule_camera_refresh(tile) do
    case CameraMultiview.session_id(tile) do
      session_id when is_binary(session_id) ->
        Process.send_after(
          self(),
          {:refresh_camera_detail_relay_session, session_id},
          CameraMultiview.fallback_refresh_ms()
        )

      _ ->
        :ok
    end
  end
end
