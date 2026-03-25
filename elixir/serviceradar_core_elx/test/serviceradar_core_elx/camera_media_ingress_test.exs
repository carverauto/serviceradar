defmodule ServiceRadarCoreElx.CameraMediaIngressTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadarCoreElx.CameraMediaIngress
  alias ServiceRadarCoreElx.CameraMediaIngressSession
  alias ServiceRadarCoreElx.CameraMediaIngressSupervisor
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
      {:ok, %{id: relay_session_id, media_ingest_id: media_ingest_id, close_reason: attrs[:close_reason]}}
    end
  end

  setup do
    clear_ingress_sessions()

    previous_state =
      CameraMediaSessionTracker
      |> :sys.get_state()
      |> Map.put(:sessions, %{})

    test_pid = self()

    :sys.replace_state(CameraMediaSessionTracker, fn state ->
      state
      |> Map.put(:sessions, %{})
      |> Map.put(:sync_module, RelaySessionLifecycleStub)
      |> Map.put(:sync_opts, test_pid: test_pid)
    end)

    on_exit(fn ->
      clear_ingress_sessions()

      :sys.replace_state(CameraMediaSessionTracker, fn _state ->
        previous_state
      end)
    end)

    :ok
  end

  test "opens an ingress pid and forwards upload, heartbeat, and close through it" do
    relay_session_id = unique_id("relay-ingress")
    :ok = RelayPubSub.subscribe(relay_session_id)

    {:ok, open_response, %{ingress_pid: ingress_pid, core_node: core_node}} =
      CameraMediaIngress.open_relay_session(%Camera.OpenRelaySessionRequest{
        relay_session_id: relay_session_id,
        agent_id: "agent-1",
        gateway_id: "gateway-1",
        camera_source_id: "camera-1",
        stream_profile_id: "main",
        codec_hint: "h264",
        container_hint: "annexb"
      })

    assert open_response.accepted == true
    assert open_response.message == "core relay session accepted"
    assert is_pid(ingress_pid)
    assert core_node == node()

    assert_receive {:activate_session, ^relay_session_id, media_ingest_id,
                    %{viewer_count: 0, lease_expires_at_unix: lease_expires_at_unix}}

    assert is_integer(lease_expires_at_unix)
    assert open_response.media_ingest_id == media_ingest_id

    assert %{
             relay_session_id: ^relay_session_id,
             media_ingest_id: ^media_ingest_id
           } = CameraMediaSessionTracker.fetch_session(relay_session_id)

    upload_response =
      CameraMediaIngressSession.upload_media(ingress_pid, [
        %Camera.MediaChunk{
          relay_session_id: relay_session_id,
          media_ingest_id: media_ingest_id,
          sequence: 7,
          payload: <<1, 2, 3, 4>>,
          codec: "h264",
          payload_format: "annexb",
          track_id: "video"
        }
      ])

    assert {:ok, %Camera.UploadMediaResponse{} = upload_ack} = upload_response
    assert upload_ack.received == true
    assert upload_ack.last_sequence == 7
    assert upload_ack.message == "media chunks accepted by core-elx"

    heartbeat_response =
      CameraMediaIngressSession.heartbeat(
        ingress_pid,
        %Camera.RelayHeartbeat{
          relay_session_id: relay_session_id,
          media_ingest_id: media_ingest_id,
          last_sequence: 7,
          sent_bytes: 4
        }
      )

    assert {:ok, %Camera.RelayHeartbeatAck{} = heartbeat_ack} = heartbeat_response
    assert heartbeat_ack.accepted == true
    assert heartbeat_ack.message == "core heartbeat accepted"

    assert_receive {:heartbeat_session, ^relay_session_id, ^media_ingest_id,
                    %{lease_expires_at_unix: renewed_lease, viewer_count: 0}}

    assert is_integer(renewed_lease)

    assert {:ok, %Camera.CloseRelaySessionResponse{} = close_response} =
             CameraMediaIngressSession.close_relay_session(
               ingress_pid,
               %Camera.CloseRelaySessionRequest{
                 relay_session_id: relay_session_id,
                 media_ingest_id: media_ingest_id,
                 reason: "operator stop"
               }
             )

    assert close_response.closed == true
    assert close_response.message == "core relay session closed"

    assert_receive {:close_session, ^relay_session_id, ^media_ingest_id,
                    %{close_reason: "operator stop", viewer_count: 0}}

    refute Process.alive?(ingress_pid)
    assert CameraMediaSessionTracker.fetch_session(relay_session_id) == nil
  end

  test "returns drain acknowledgments when the relay is already closing" do
    relay_session_id = unique_id("relay-ingress-drain")
    :ok = RelayPubSub.subscribe(relay_session_id)

    {:ok, open_response, %{ingress_pid: ingress_pid}} =
      CameraMediaIngress.open_relay_session(%Camera.OpenRelaySessionRequest{
        relay_session_id: relay_session_id,
        agent_id: "agent-1",
        gateway_id: "gateway-1",
        camera_source_id: "camera-1",
        stream_profile_id: "main"
      })

    media_ingest_id = open_response.media_ingest_id

    :ok =
      CameraMediaSessionTracker.mark_closing(relay_session_id, %{
        close_reason: "viewer idle timeout",
        viewer_count: 0
      })

    assert_receive {:camera_relay_state, %{relay_session_id: ^relay_session_id, status: "closing"}}

    assert {:ok, %Camera.UploadMediaResponse{} = upload_ack} =
             CameraMediaIngressSession.upload_media(ingress_pid, [
               %Camera.MediaChunk{
                 relay_session_id: relay_session_id,
                 media_ingest_id: media_ingest_id,
                 sequence: 9,
                 payload: <<9, 8, 7>>,
                 codec: "h264",
                 payload_format: "annexb"
               }
             ])

    assert upload_ack.message == "media chunks accepted during relay drain"

    assert {:ok, %Camera.RelayHeartbeatAck{} = heartbeat_ack} =
             CameraMediaIngressSession.heartbeat(
               ingress_pid,
               %Camera.RelayHeartbeat{
                 relay_session_id: relay_session_id,
                 media_ingest_id: media_ingest_id,
                 last_sequence: 9,
                 sent_bytes: 3
               }
             )

    assert heartbeat_ack.message == "core heartbeat accepted during relay drain"
  end

  defp clear_ingress_sessions do
    if Process.whereis(CameraMediaIngressSupervisor) do
      CameraMediaIngressSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn
        {_id, pid, _type, _modules} when is_pid(pid) ->
          _ = DynamicSupervisor.terminate_child(CameraMediaIngressSupervisor, pid)

        _other ->
          :ok
      end)
    end
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
