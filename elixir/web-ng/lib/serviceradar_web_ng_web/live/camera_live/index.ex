defmodule ServiceRadarWebNGWeb.CameraLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.CameraMultiview
  alias ServiceRadarWebNGWeb.CameraRelayComponents

  require Logger

  @layout_options [2, 4, 8, 16, 32]
  @default_layout_count 4

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Camera Multiview")
      |> assign(:current_path, "/cameras")
      |> assign(:srql, %{enabled: false, page_path: "/cameras"})
      |> assign(:layout_options, @layout_options)
      |> assign(:layout_count, @default_layout_count)
      |> assign(:camera_tiles, [])
      |> assign(:camera_relay_subscriptions, MapSet.new())
      |> assign(:relay_notice, nil)

    socket =
      if connected?(socket) do
        open_camera_layout(socket, @default_layout_count)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <div class="sr-camera-page">
        <header class="sr-camera-toolbar">
          <div>
            <h2>Camera Multiview</h2>
            <p>Live relay-backed views from discovered camera inventory.</p>
          </div>
          <div class="sr-camera-layout-controls" role="group" aria-label="Camera layout">
            <button
              :for={count <- @layout_options}
              type="button"
              phx-click="set_layout"
              phx-value-count={count}
              class={["sr-camera-layout-button", @layout_count == count && "is-active"]}
            >
              {count}
            </button>
          </div>
        </header>

        <div :if={@relay_notice} class="sr-camera-notice">
          {@relay_notice}
        </div>

        <section
          class={[
            "sr-camera-multiview",
            "sr-camera-multiview-#{@layout_count}"
          ]}
          data-testid="camera-multiview"
        >
          <article
            :for={tile <- visible_camera_tiles(@camera_tiles, @layout_count)}
            class="sr-camera-cell"
          >
            <header>
              <span>{tile.label}</span>
              <small>{tile.detail || tile.source_status || "Camera stream"}</small>
            </header>
            <CameraRelayComponents.relay_player
              :if={tile.session}
              session={tile.session}
              id_prefix="camera-multiview-relay"
            />
            <div :if={!tile.session} class="sr-camera-cell-empty">
              <.icon name="hero-video-camera-slash" class="size-8" />
              <span>{tile.error || "No live relay available"}</span>
            </div>
          </article>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("set_layout", %{"count" => count}, socket) do
    count = normalize_layout_count(count)
    {:noreply, open_camera_layout(socket, count)}
  end

  @impl true
  # Fallback timer for one tile: re-read it and re-arm.
  def handle_info({:refresh_camera_multiview_relay_session, relay_session_id}, socket) do
    {:noreply, refresh_camera_tile(socket, relay_session_id, rearm: true)}
  end

  # The relay published a state change for a tile's session.
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
    Logger.debug("Ignoring unexpected camera multiview message: #{inspect(message, limit: 20, printable_limit: 200)}")
    {:noreply, socket}
  end

  defp refresh_camera_tile(socket, relay_session_id, rearm: rearm?) do
    tiles =
      Enum.map(socket.assigns.camera_tiles, fn tile ->
        if CameraMultiview.session_id(tile) == relay_session_id do
          refreshed = CameraMultiview.refresh_tile_session(socket.assigns.current_scope, tile)
          if rearm? or CameraMultiview.session_id(refreshed) != relay_session_id, do: schedule_camera_refresh(refreshed)
          refreshed
        else
          tile
        end
      end)

    socket
    |> assign(:camera_tiles, tiles)
    |> subscribe_camera_tiles(tiles)
  end

  defp subscribe_camera_tiles(socket, tiles) do
    subscribed =
      Enum.reduce(tiles, socket.assigns.camera_relay_subscriptions, &CameraMultiview.subscribe_relay_state(&2, &1))

    assign(socket, :camera_relay_subscriptions, subscribed)
  end

  defp open_camera_layout(socket, count) do
    if RBAC.can?(socket.assigns.current_scope, "devices.view") do
      tiles = CameraMultiview.open_preview_tiles(socket.assigns.current_scope, count)
      Enum.each(tiles, &schedule_camera_refresh/1)

      socket
      |> subscribe_camera_tiles(tiles)
      |> assign(:layout_count, count)
      |> assign(:camera_tiles, pad_camera_tiles(tiles, count))
      |> assign(:relay_notice, camera_layout_notice(tiles, count))
    else
      socket
      |> assign(:camera_tiles, pad_camera_tiles([], count))
      |> assign(:relay_notice, "You are not authorized to view camera streams.")
    end
  end

  defp visible_camera_tiles(tiles, count), do: Enum.take(tiles, count)

  defp pad_camera_tiles(tiles, count) do
    tiles ++
      for idx <- (length(tiles) + 1)..count//1 do
        %{label: "Camera #{idx}", detail: "Unassigned viewport", session: nil, error: "No relay-capable camera selected"}
      end
  end

  defp camera_layout_notice(tiles, count) do
    opened = Enum.count(tiles, & &1.session)

    cond do
      opened == count ->
        nil

      opened > 0 ->
        "#{opened} of #{count} viewports are backed by active relay sessions."

      tiles != [] ->
        relay_failure_notice(tiles)

      true ->
        "No relay-capable cameras were available from the current camera inventory."
    end
  end

  defp relay_failure_notice(tiles) do
    errors =
      tiles
      |> Enum.map(&Map.get(&1, :error))
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.uniq()

    case errors do
      [] ->
        "Relay-capable cameras are available, but no relay sessions opened."

      [error] ->
        "Relay-capable cameras are available, but no relay sessions opened: #{error}."

      errors ->
        "Relay-capable cameras are available, but no relay sessions opened: #{Enum.join(errors, "; ")}."
    end
  end

  defp normalize_layout_count(value) when is_binary(value) do
    value
    |> Integer.parse()
    |> case do
      {count, ""} -> normalize_layout_count(count)
      _ -> @default_layout_count
    end
  end

  defp normalize_layout_count(value) when value in @layout_options, do: value
  defp normalize_layout_count(_value), do: @default_layout_count

  defp schedule_camera_refresh(tile) do
    case CameraMultiview.session_id(tile) do
      session_id when is_binary(session_id) ->
        Process.send_after(
          self(),
          {:refresh_camera_multiview_relay_session, session_id},
          CameraMultiview.fallback_refresh_ms()
        )

      _ ->
        :ok
    end
  end
end
