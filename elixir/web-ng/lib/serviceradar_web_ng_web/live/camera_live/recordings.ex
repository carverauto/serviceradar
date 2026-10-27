defmodule ServiceRadarWebNGWeb.CameraLive.Recordings do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveUploads
  alias ServiceRadarWebNG.CameraArchiveWindow
  alias ServiceRadarWebNGWeb.CameraArchiveAccess
  alias ServiceRadarWebNGWeb.CameraLive.RecordingsComponents

  @impl true
  def mount(%{"camera_source_id" => source_id}, _session, socket) do
    path = "/cameras/#{source_id}/recordings"

    socket =
      assign(socket,
        page_title: "Camera Recordings",
        current_path: path,
        srql: %{enabled: false, page_path: path},
        camera_source_id: source_id,
        source: nil,
        items: [],
        next_cursor: nil,
        selected: nil,
        error: nil,
        loading: true
      )

    {:ok, if(connected?(socket), do: load_inventory(socket, nil), else: socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <RecordingsComponents.recordings
        source={@source}
        items={@items}
        next_cursor={@next_cursor}
        selected={@selected}
        error={@error}
        loading={@loading}
        timezone={@current_scope.user.timezone || "Etc/UTC"}
      />
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("refresh_recordings", _, socket), do: {:noreply, load_inventory(socket, nil)}

  def handle_event("next_recordings", _, socket), do: {:noreply, load_inventory(socket, socket.assigns.next_cursor)}

  def handle_event("select_recording", %{"id" => block_id}, socket), do: {:noreply, select_recording(socket, block_id, 0)}

  def handle_event("recording_window", %{"direction" => direction}, socket) when direction in ["previous", "next"] do
    case socket.assigns.selected do
      nil ->
        {:noreply, load_inventory(socket, nil)}

      selected ->
        index = selected.window.index + if(direction == "next", do: 1, else: -1)
        {:noreply, select_recording(socket, selected.block_id, index)}
    end
  end

  defp load_inventory(socket, cursor) do
    with {:ok, scope, source} <- CameraArchiveAccess.source(socket.assigns.current_scope, socket.assigns.camera_source_id),
         {:ok, inventory} <-
           ArchiveUploads.archive_inventory(source.id, [limit: 10, cursor: cursor],
             actor: SystemActor.system(:camera_archive_metadata)
           ) do
      assign(socket,
        current_scope: scope,
        source: source,
        items: inventory.items,
        next_cursor: inventory.next_cursor,
        selected: nil,
        error: nil,
        loading: false
      )
    else
      {:error, reason} -> unavailable(socket, reason)
    end
  end

  defp select_recording(socket, block_id, index) do
    with {:ok, scope, source_id, block_id} <-
           CameraArchiveAccess.recording(socket.assigns.current_scope, socket.assigns.camera_source_id, block_id),
         {:ok, metadata} <-
           ArchiveUploads.archive_metadata(source_id, block_id, actor: SystemActor.system(:camera_archive_metadata)),
         {:ok, window} <- CameraArchiveWindow.select(metadata, index) do
      selected = %{
        block_id: block_id,
        window: window,
        playlist_path:
          "/api/cameras/#{source_id}/recordings/#{block_id}/playlist.m3u8?first=#{window.first}&count=#{window.count}"
      }

      assign(socket, current_scope: scope, selected: selected, error: nil)
    else
      {:error, reason} -> unavailable(socket, reason)
    end
  end

  defp unavailable(socket, reason) do
    assign(socket, source: nil, items: [], next_cursor: nil, selected: nil, loading: false, error: message(reason))
  end

  defp message(reason) when reason in [:unauthorized, :permission_revoked],
    do: "You no longer have permission to view camera recordings."

  defp message(%Forbidden{}), do: message(:permission_revoked)
  defp message(:invalid_id), do: "The camera or recording identifier is invalid."
  defp message(:recording_block_not_found), do: "The camera or recording could not be found."
  defp message(:archive_unavailable), do: "This recording is no longer available for playback."

  defp message(reason) when reason in [:invalid_recording_window, :recording_window_too_large],
    do: "This recording window cannot be played within the current playback limits."

  defp message(_), do: "Camera recordings are temporarily unavailable. Try refreshing."
end
