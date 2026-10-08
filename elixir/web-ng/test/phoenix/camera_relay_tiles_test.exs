defmodule ServiceRadarWebNGWeb.CameraRelayTilesTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveView.Socket
  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadarWebNGWeb.CameraLive.Index, as: CameraIndex
  alias ServiceRadarWebNGWeb.CameraMultiview
  alias ServiceRadarWebNGWeb.DashboardLive.Index, as: DashboardIndex

  @moduletag :db_free

  setup_all do
    if !Process.whereis(ServiceRadar.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    :ok
  end

  setup do
    previous_fetcher = Application.get_env(:serviceradar_web_ng, :camera_relay_session_fetcher)
    test_pid = self()

    Application.put_env(:serviceradar_web_ng, :camera_relay_session_fetcher, fn id, _opts ->
      send(test_pid, {:relay_session_fetched, id})
      {:ok, %RelaySession{id: id, status: :active, media_ingest_id: "core-media-tile"}}
    end)

    on_exit(fn ->
      if previous_fetcher do
        Application.put_env(:serviceradar_web_ng, :camera_relay_session_fetcher, previous_fetcher)
      else
        Application.delete_env(:serviceradar_web_ng, :camera_relay_session_fetcher)
      end
    end)

    relay_id = Ecto.UUID.generate()
    tile = %{label: "Camera", session: %RelaySession{id: relay_id, status: :opening}}
    other = %{label: "Other camera", session: %RelaySession{id: Ecto.UUID.generate(), status: :opening}}

    %{relay_id: relay_id, tile: tile, other: other}
  end

  test "a camera tile subscribes to its relay session's state broadcasts", %{relay_id: relay_id, tile: tile} do
    subscribed = CameraMultiview.subscribe_relay_state(MapSet.new(), tile)
    assert MapSet.member?(subscribed, relay_id)
    # Subscribing again is a no-op, so a broadcast is delivered once.
    assert CameraMultiview.subscribe_relay_state(subscribed, tile) == subscribed

    :ok = RelayPubSub.broadcast_state(relay_id, %{relay_session_id: relay_id, viewer_count: 1})
    assert_receive {:camera_relay_state, %{relay_session_id: ^relay_id}}
    refute_receive {:camera_relay_state, _}, 50
  end

  test "the multiview refreshes only the broadcasting tile when relay state changes",
       %{relay_id: relay_id, tile: tile, other: other} do
    socket = socket(%{camera_tiles: [tile, other]})

    assert {:noreply, socket} =
             CameraIndex.handle_info({:camera_relay_state, %{relay_session_id: relay_id}}, socket)

    assert_received {:relay_session_fetched, ^relay_id}
    refute_received {:relay_session_fetched, _}
    assert [%{session: %RelaySession{status: :active}}, ^other] = socket.assigns.camera_tiles
  end

  test "dashboard previews refresh only the broadcasting tile when relay state changes",
       %{relay_id: relay_id, tile: tile, other: other} do
    socket = socket(%{camera_preview_tiles: [tile, other]})

    assert {:noreply, socket} =
             DashboardIndex.handle_info({:camera_relay_state, %{relay_session_id: relay_id}}, socket)

    assert_received {:relay_session_fetched, ^relay_id}
    refute_received {:relay_session_fetched, _}
    assert [%{session: %RelaySession{status: :active}}, ^other] = socket.assigns.camera_preview_tiles
  end

  test "the fallback refresh is a slow safety net, not a per-second poll" do
    previous = Application.get_env(:serviceradar_web_ng, :camera_relay_poll_interval_ms)
    Application.delete_env(:serviceradar_web_ng, :camera_relay_poll_interval_ms)

    try do
      assert CameraMultiview.fallback_refresh_ms() >= 10_000
    after
      if previous, do: Application.put_env(:serviceradar_web_ng, :camera_relay_poll_interval_ms, previous)
    end
  end

  for index <- [DashboardIndex, CameraIndex],
      event <- [
        :camera_relay_webrtc_closed,
        :camera_relay_chunk,
        :camera_relay_viewer_chunk,
        :unexpected_relay_event
      ] do
    test "#{inspect(index)} keeps its socket on #{event}", %{relay_id: relay_id, tile: tile} do
      socket = socket(%{camera_preview_tiles: [tile], camera_tiles: [tile]})

      message =
        {unquote(event),
         %{
           relay_session_id: relay_id,
           viewer_id: Ecto.UUID.generate(),
           transport: "membrane_webrtc",
           reason: "viewer closed webrtc signaling session"
         }}

      assert unquote(index).handle_info(message, socket) == {:noreply, socket}
      refute_received {:relay_session_fetched, _}
    end
  end

  defp socket(assigns) do
    %Socket{
      assigns:
        Map.merge(
          %{__changed__: %{}, current_scope: nil, camera_relay_subscriptions: MapSet.new()},
          assigns
        )
    }
  end
end
