defmodule ServiceRadarCoreElx.CameraMediaSessionTrackerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadarCoreElx.CameraMediaSessionTracker

  defmodule RelaySessionLifecycleStub do
    @moduledoc false
    def activate_session(relay_session_id, media_ingest_id, attrs, opts) do
      send(opts[:test_pid], {:activate_session, relay_session_id, media_ingest_id, attrs})
      {:ok, %{id: relay_session_id, media_ingest_id: media_ingest_id}}
    end

    def heartbeat_session(relay_session_id, media_ingest_id, attrs, opts) do
      send(opts[:test_pid], {:heartbeat_session, relay_session_id, media_ingest_id, attrs})
      {:ok, %{id: relay_session_id, media_ingest_id: media_ingest_id}}
    end

    def close_session(relay_session_id, media_ingest_id, attrs, opts) do
      send(opts[:test_pid], {:close_session, relay_session_id, media_ingest_id, attrs})
      {:ok, %{id: relay_session_id, media_ingest_id: media_ingest_id}}
    end
  end

  setup do
    previous_sync_module =
      Application.get_env(:serviceradar_core_elx, :camera_relay_session_lifecycle)

    previous_sync_opts =
      Application.get_env(:serviceradar_core_elx, :camera_relay_session_lifecycle_opts)

    Application.put_env(
      :serviceradar_core_elx,
      :camera_relay_session_lifecycle,
      RelaySessionLifecycleStub
    )

    Application.put_env(
      :serviceradar_core_elx,
      :camera_relay_session_lifecycle_opts,
      test_pid: self()
    )

    restart_tracker!()

    on_exit(fn ->
      restore_env(:camera_relay_session_lifecycle, previous_sync_module)
      restore_env(:camera_relay_session_lifecycle_opts, previous_sync_opts)
    end)

    :ok
  end

  test "opens, tracks, heartbeats, and closes a core relay session" do
    :ok = RelayPubSub.subscribe("relay-1")

    assert {:ok, session} =
             CameraMediaSessionTracker.open_session(%{
               relay_session_id: "relay-1",
               agent_id: "agent-1",
               gateway_id: "gateway-1",
               camera_source_id: "camera-1",
               stream_profile_id: "main"
             })

    assert String.starts_with?(session.media_ingest_id, "core-media-")
    assert_receive {:activate_session, "relay-1", media_ingest_id, %{lease_expires_at_unix: lease_expires_at_unix}}
    assert_receive {:camera_relay_state, %{relay_session_id: "relay-1", status: "active", playback_state: "ready"}}
    assert media_ingest_id == session.media_ingest_id
    assert is_integer(lease_expires_at_unix)

    assert {:ok, updated} =
             CameraMediaSessionTracker.record_chunk(session.relay_session_id, session.media_ingest_id, %{
               sequence: 7,
               codec: "h264",
               payload_format: "annexb",
               payload: <<1, 2, 3, 4>>
             })

    assert updated.last_sequence == 7
    assert updated.sent_bytes == 4
    assert_receive {:camera_relay_chunk, %{relay_session_id: "relay-1", sequence: 7, payload: <<1, 2, 3, 4>>}}

    assert {:ok, heartbeated} =
             CameraMediaSessionTracker.heartbeat(session.relay_session_id, session.media_ingest_id, %{
               last_sequence: 8,
               sent_bytes: 20
             })

    assert heartbeated.last_sequence == 8
    assert heartbeated.sent_bytes == 20
    assert_receive {:heartbeat_session, "relay-1", ^media_ingest_id, %{lease_expires_at_unix: renewed_lease}}
    assert is_integer(renewed_lease)

    assert :ok = CameraMediaSessionTracker.close_session(session.relay_session_id, session.media_ingest_id)
    assert_receive {:close_session, "relay-1", ^media_ingest_id, %{close_reason: nil}}
    assert_receive {:camera_relay_state, %{relay_session_id: "relay-1", status: "closed", playback_state: "closed"}}
  end

  test "rejects duplicate relay session ids" do
    assert {:ok, _session} =
             CameraMediaSessionTracker.open_session(%{
               relay_session_id: "relay-1",
               agent_id: "agent-1",
               gateway_id: "gateway-1",
               camera_source_id: "camera-1",
               stream_profile_id: "main"
             })

    assert {:error, :already_exists} =
             CameraMediaSessionTracker.open_session(%{
               relay_session_id: "relay-1",
               agent_id: "agent-1",
               gateway_id: "gateway-1",
               camera_source_id: "camera-1",
               stream_profile_id: "main"
             })
  end

  defp restart_tracker! do
    if pid = Process.whereis(CameraMediaSessionTracker) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    end

    wait_for_tracker_start()
  end

  defp wait_for_tracker_start(attempts \\ 20)

  defp wait_for_tracker_start(0) do
    raise "camera media session tracker did not restart"
  end

  defp wait_for_tracker_start(attempts) do
    case Process.whereis(CameraMediaSessionTracker) do
      nil ->
        Process.sleep(50)
        wait_for_tracker_start(attempts - 1)

      _pid ->
        :ok
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core_elx, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core_elx, key, value)
end
