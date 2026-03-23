defmodule ServiceRadarAgentGateway.CameraMediaNegotiationIntegrationTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.CameraMediaServer
  alias ServiceRadarAgentGateway.CameraMediaSessionTracker
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaAdapterStub
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaCoreTestServer
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaForwarderProxy
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaIdentityResolverStub

  setup do
    previous_forwarder = Application.get_env(:serviceradar_agent_gateway, :camera_media_forwarder)

    previous_tracker =
      Application.get_env(:serviceradar_agent_gateway, :camera_media_session_tracker_module)

    previous_identity_resolver =
      Application.get_env(:serviceradar_agent_gateway, :camera_media_identity_resolver)

    previous_test_pid =
      Application.get_env(:serviceradar_agent_gateway, :camera_media_integration_test_pid)

    previous_forwarder_host =
      Application.get_env(:serviceradar_agent_gateway, :camera_media_test_forwarder_host)

    previous_forwarder_port =
      Application.get_env(:serviceradar_agent_gateway, :camera_media_test_forwarder_port)

    previous_media_ingest_id =
      Application.get_env(:serviceradar_agent_gateway, :camera_media_core_test_media_ingest_id)

    previous_open_lease =
      Application.get_env(:serviceradar_agent_gateway, :camera_media_core_test_lease_expires_at_unix)

    previous_heartbeat_lease =
      Application.get_env(
        :serviceradar_agent_gateway,
        :camera_media_core_test_heartbeat_lease_expires_at_unix
      )

    previous_agent_limit =
      Application.get_env(:serviceradar_agent_gateway, :camera_relay_max_sessions_per_agent)

    previous_gateway_limit =
      Application.get_env(:serviceradar_agent_gateway, :camera_relay_max_sessions_per_gateway)

    previous_state =
      CameraMediaSessionTracker
      |> :sys.get_state()
      |> clear_sessions()

    :sys.replace_state(CameraMediaSessionTracker, fn state ->
      Map.put(state, :sessions, %{})
    end)

    port = open_port()
    media_ingest_id = "core-media-negotiation-1"
    lease_expires_at_unix = System.os_time(:second) + 60
    heartbeat_lease_expires_at_unix = lease_expires_at_unix + 30

    Application.put_env(
      :serviceradar_agent_gateway,
      :camera_media_forwarder,
      CameraMediaForwarderProxy
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :camera_media_session_tracker_module,
      CameraMediaSessionTracker
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :camera_media_identity_resolver,
      CameraMediaIdentityResolverStub
    )

    Application.put_env(:serviceradar_agent_gateway, :camera_media_integration_test_pid, self())
    Application.put_env(:serviceradar_agent_gateway, :camera_media_test_forwarder_host, "127.0.0.1")
    Application.put_env(:serviceradar_agent_gateway, :camera_media_test_forwarder_port, port)

    Application.put_env(
      :serviceradar_agent_gateway,
      :camera_media_core_test_media_ingest_id,
      media_ingest_id
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :camera_media_core_test_lease_expires_at_unix,
      lease_expires_at_unix
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :camera_media_core_test_heartbeat_lease_expires_at_unix,
      heartbeat_lease_expires_at_unix
    )

    Application.put_env(:serviceradar_agent_gateway, :camera_relay_max_sessions_per_agent, :infinity)
    Application.put_env(:serviceradar_agent_gateway, :camera_relay_max_sessions_per_gateway, :infinity)

    ensure_grpc_client_supervisor_started()

    start_supervised!(
      {GRPC.Server.Supervisor,
       servers: [CameraMediaCoreTestServer], port: port, start_server: true, adapter_opts: [ip: {127, 0, 0, 1}]}
    )

    wait_for_server(port)

    on_exit(fn ->
      CameraMediaSessionTracker
      |> :sys.get_state()
      |> clear_sessions()

      :sys.replace_state(CameraMediaSessionTracker, fn _state -> previous_state end)

      restore_env(:camera_media_forwarder, previous_forwarder)
      restore_env(:camera_media_session_tracker_module, previous_tracker)
      restore_env(:camera_media_identity_resolver, previous_identity_resolver)
      restore_env(:camera_media_integration_test_pid, previous_test_pid)
      restore_env(:camera_media_test_forwarder_host, previous_forwarder_host)
      restore_env(:camera_media_test_forwarder_port, previous_forwarder_port)
      restore_env(:camera_media_core_test_media_ingest_id, previous_media_ingest_id)
      restore_env(:camera_media_core_test_lease_expires_at_unix, previous_open_lease)

      restore_env(
        :camera_media_core_test_heartbeat_lease_expires_at_unix,
        previous_heartbeat_lease
      )

      restore_env(:camera_relay_max_sessions_per_agent, previous_agent_limit)
      restore_env(:camera_relay_max_sessions_per_gateway, previous_gateway_limit)
    end)

    {:ok,
     media_ingest_id: media_ingest_id,
     lease_expires_at_unix: lease_expires_at_unix,
     heartbeat_lease_expires_at_unix: heartbeat_lease_expires_at_unix}
  end

  test "negotiates relay media sessions across gateway and core ingress", %{
    media_ingest_id: media_ingest_id,
    lease_expires_at_unix: lease_expires_at_unix,
    heartbeat_lease_expires_at_unix: heartbeat_lease_expires_at_unix
  } do
    stream = %{adapter: CameraMediaAdapterStub, payload: :test}

    open_response =
      CameraMediaServer.open_relay_session(
        %Camera.OpenRelaySessionRequest{
          relay_session_id: "relay-negotiation-1",
          agent_id: "agent-1",
          camera_source_id: "camera-1",
          stream_profile_id: "main",
          lease_token: "lease-negotiation-1",
          codec_hint: "h264",
          container_hint: "annexb"
        },
        stream
      )

    assert open_response.accepted == true
    assert open_response.message == "core relay session accepted"
    assert open_response.media_ingest_id == media_ingest_id
    assert open_response.max_chunk_bytes == 262_144
    assert open_response.lease_expires_at_unix == lease_expires_at_unix

    assert_receive {:core_open_relay_session,
                    %Camera.OpenRelaySessionRequest{
                      relay_session_id: "relay-negotiation-1",
                      agent_id: "agent-1",
                      gateway_id: gateway_id,
                      camera_source_id: "camera-1",
                      stream_profile_id: "main",
                      lease_token: "lease-negotiation-1",
                      codec_hint: "h264",
                      container_hint: "annexb"
                    }}

    assert gateway_id == Atom.to_string(node())

    assert %{
             relay_session_id: "relay-negotiation-1",
             media_ingest_id: ^media_ingest_id,
             agent_id: "agent-1",
             camera_source_id: "camera-1",
             stream_profile_id: "main",
             partition_id: "default",
             status: "active"
           } = CameraMediaSessionTracker.fetch_session("relay-negotiation-1")

    upload_response =
      CameraMediaServer.upload_media(
        [
          %Camera.MediaChunk{
            relay_session_id: "relay-negotiation-1",
            media_ingest_id: media_ingest_id,
            agent_id: "agent-1",
            sequence: 7,
            payload: <<1, 2, 3, 4>>,
            codec: "h264",
            payload_format: "annexb",
            track_id: "video"
          }
        ],
        stream
      )

    assert upload_response.received == true
    assert upload_response.last_sequence == 7
    assert upload_response.message == "media chunks accepted by core-elx"

    assert_receive {:core_upload_media,
                    [
                      %Camera.MediaChunk{
                        relay_session_id: "relay-negotiation-1",
                        media_ingest_id: ^media_ingest_id,
                        agent_id: "agent-1",
                        sequence: 7,
                        payload: <<1, 2, 3, 4>>,
                        codec: "h264",
                        payload_format: "annexb",
                        track_id: "video"
                      }
                    ]}

    assert %{
             last_sequence: 7,
             sent_bytes: 4,
             status: "active"
           } = CameraMediaSessionTracker.fetch_session("relay-negotiation-1")

    heartbeat_response =
      CameraMediaServer.heartbeat(
        %Camera.RelayHeartbeat{
          relay_session_id: "relay-negotiation-1",
          media_ingest_id: media_ingest_id,
          agent_id: "agent-1",
          last_sequence: 7,
          sent_bytes: 4
        },
        stream
      )

    assert heartbeat_response.accepted == true
    assert heartbeat_response.lease_expires_at_unix == heartbeat_lease_expires_at_unix
    assert heartbeat_response.message == "core heartbeat accepted"

    assert_receive {:core_heartbeat,
                    %Camera.RelayHeartbeat{
                      relay_session_id: "relay-negotiation-1",
                      media_ingest_id: ^media_ingest_id,
                      agent_id: "agent-1",
                      last_sequence: 7,
                      sent_bytes: 4
                    }}

    assert %{
             last_sequence: 7,
             sent_bytes: 4,
             lease_expires_at_unix: ^heartbeat_lease_expires_at_unix,
             status: "active"
           } = CameraMediaSessionTracker.fetch_session("relay-negotiation-1")

    close_response =
      CameraMediaServer.close_relay_session(
        %Camera.CloseRelaySessionRequest{
          relay_session_id: "relay-negotiation-1",
          media_ingest_id: media_ingest_id,
          agent_id: "agent-1",
          reason: "operator stop"
        },
        stream
      )

    assert close_response.closed == true
    assert close_response.message == "core relay session closed"

    assert_receive {:core_close_relay_session,
                    %Camera.CloseRelaySessionRequest{
                      relay_session_id: "relay-negotiation-1",
                      media_ingest_id: ^media_ingest_id,
                      agent_id: "agent-1",
                      reason: "operator stop"
                    }}

    assert CameraMediaSessionTracker.fetch_session("relay-negotiation-1") == nil
  end

  defp clear_sessions(state) do
    Map.put(state, :sessions, %{})
  end

  defp open_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp wait_for_server(port, attempts \\ 20)

  defp wait_for_server(_port, 0), do: flunk("core camera media test server did not start")

  defp wait_for_server(port, attempts) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 100) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        :ok

      {:error, _reason} ->
        Process.sleep(25)
        wait_for_server(port, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)

  defp ensure_grpc_client_supervisor_started do
    case Process.whereis(GRPC.Client.Supervisor) do
      nil ->
        start_supervised!({GRPC.Client.Supervisor, []})
        :ok

      _pid ->
        :ok
    end
  end
end
