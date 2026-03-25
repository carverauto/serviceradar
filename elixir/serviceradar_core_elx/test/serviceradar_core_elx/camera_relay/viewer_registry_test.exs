defmodule ServiceRadarCoreElx.CameraRelay.ViewerRegistryTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadarCoreElx.CameraRelay.ViewerRegistry

  defmodule RelaySessionCloserStub do
    @moduledoc false

    def request_close(relay_session_id, opts) do
      send(opts[:test_pid], {:request_close, relay_session_id, opts})
      {:ok, %{id: relay_session_id, status: :closing}}
    end
  end

  defmodule SessionTrackerStub do
    @moduledoc false

    def sync_viewer_count(relay_session_id, viewer_count) do
      send(test_pid(), {:sync_viewer_count, relay_session_id, viewer_count})
      :ok
    end

    def mark_closing(relay_session_id, attrs) do
      send(test_pid(), {:mark_closing, relay_session_id, attrs})
      :ok
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :camera_relay_viewer_registry_test_pid)
    end
  end

  setup do
    previous_state =
      ViewerRegistry
      |> :sys.get_state()
      |> cancel_close_timers()

    test_pid = self()

    previous_tracker_test_pid =
      Application.get_env(:serviceradar_core_elx, :camera_relay_viewer_registry_test_pid)

    Application.put_env(:serviceradar_core_elx, :camera_relay_viewer_registry_test_pid, test_pid)

    :sys.replace_state(ViewerRegistry, fn state ->
      state
      |> Map.put(:viewers, %{})
      |> Map.put(:close_timers, %{})
      |> Map.put(:idle_close_ms, 25)
      |> Map.put(:session_closer, RelaySessionCloserStub)
      |> Map.put(:session_closer_opts, test_pid: test_pid)
      |> Map.put(:session_tracker, SessionTrackerStub)
    end)

    on_exit(fn ->
      restore_env(:camera_relay_viewer_registry_test_pid, previous_tracker_test_pid)

      ViewerRegistry
      |> :sys.get_state()
      |> cancel_close_timers()

      :sys.replace_state(ViewerRegistry, fn _state -> previous_state end)
    end)

    :ok
  end

  test "fans chunks only to registered viewers for a relay session" do
    relay_session_id = "relay-viewers-1"
    viewer_a = "viewer-a"
    viewer_b = "viewer-b"

    :ok = RelayPubSub.subscribe_viewer(relay_session_id, viewer_a)
    :ok = RelayPubSub.subscribe_viewer(relay_session_id, viewer_b)

    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_a)
    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_b)
    _ = :sys.get_state(ViewerRegistry)

    assert_receive {:sync_viewer_count, ^relay_session_id, 1}
    assert_receive {:sync_viewer_count, ^relay_session_id, 2}

    ViewerRegistry.broadcast_chunk(relay_session_id, %{
      media_ingest_id: "core-media-1",
      sequence: 5,
      payload: <<1, 2, 3>>
    })

    assert_receive {:camera_relay_viewer_chunk, %{viewer_id: ^viewer_a, sequence: 5, payload: <<1, 2, 3>>}}

    assert_receive {:camera_relay_viewer_chunk, %{viewer_id: ^viewer_b, sequence: 5, payload: <<1, 2, 3>>}}

    assert ViewerRegistry.viewer_count(relay_session_id) == 2

    :ok = RelayPubSub.viewer_leave(relay_session_id, viewer_b)
    _ = :sys.get_state(ViewerRegistry)
    assert_receive {:sync_viewer_count, ^relay_session_id, 1}

    ViewerRegistry.broadcast_chunk(relay_session_id, %{
      media_ingest_id: "core-media-1",
      sequence: 6,
      payload: <<4, 5, 6>>
    })

    assert_receive {:camera_relay_viewer_chunk, %{viewer_id: ^viewer_a, sequence: 6, payload: <<4, 5, 6>>}}

    refute_receive {:camera_relay_viewer_chunk, %{viewer_id: ^viewer_b, sequence: 6, payload: <<4, 5, 6>>}},
                   100

    assert ViewerRegistry.viewer_count(relay_session_id) == 1
  end

  test "requests relay close after idle timeout when the last viewer leaves" do
    relay_session_id = "relay-idle-close-1"
    viewer_id = "viewer-idle-close-1"

    :ok = RelayPubSub.subscribe_viewer(relay_session_id, viewer_id)
    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_id)
    _ = :sys.get_state(ViewerRegistry)

    :ok = RelayPubSub.viewer_leave(relay_session_id, viewer_id)

    assert_receive {:sync_viewer_count, ^relay_session_id, 0}
    assert_receive {:request_close, ^relay_session_id, opts}, 500
    assert opts[:reason] == "viewer idle timeout"
    assert opts[:test_pid] == self()
    assert_receive {:mark_closing, ^relay_session_id, %{close_reason: "viewer idle timeout", viewer_count: 0}}
  end

  test "cancels idle close if a viewer rejoins before timeout" do
    relay_session_id = "relay-idle-cancel-1"
    viewer_id = "viewer-idle-cancel-1"

    :ok = RelayPubSub.subscribe_viewer(relay_session_id, viewer_id)
    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_id)
    _ = :sys.get_state(ViewerRegistry)

    :ok = RelayPubSub.viewer_leave(relay_session_id, viewer_id)
    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_id)

    assert_receive {:sync_viewer_count, ^relay_session_id, 1}
    assert_receive {:sync_viewer_count, ^relay_session_id, 0}
    assert_receive {:sync_viewer_count, ^relay_session_id, 1}
    refute_receive {:request_close, ^relay_session_id, _opts}, 200
    refute_receive {:mark_closing, ^relay_session_id, _attrs}, 50
  end

  defp cancel_close_timers(state) do
    Enum.each(Map.values(Map.get(state, :close_timers, %{})), &Process.cancel_timer/1)
    Map.put(state, :close_timers, %{})
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core_elx, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core_elx, key, value)
end
