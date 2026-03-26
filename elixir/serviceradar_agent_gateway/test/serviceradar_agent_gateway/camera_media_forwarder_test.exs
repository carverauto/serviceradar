defmodule ServiceRadarAgentGateway.CameraMediaForwarderTest do
  use ExUnit.Case, async: true

  alias ServiceRadarAgentGateway.CameraMediaForwarder
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaConnectivityStub
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaErtsIngressStub
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaRpcStub

  setup do
    Process.delete({CameraMediaConnectivityStub, :results})
    Process.delete({CameraMediaRpcStub, :results})
    :ok
  end

  test "pings core before opening a relay session" do
    request = %Camera.OpenRelaySessionRequest{
      relay_session_id: "relay-forwarder-ping-1",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      camera_source_id: "camera-1",
      stream_profile_id: "main",
      lease_token: "lease-1"
    }

    Process.put({CameraMediaConnectivityStub, :results}, [:pong])

    Process.put({CameraMediaRpcStub, :results}, [
      {:ok,
       %Camera.OpenRelaySessionResponse{
         accepted: true,
         message: "core relay session accepted",
         media_ingest_id: "media-1",
         max_chunk_bytes: 262_144,
         lease_expires_at_unix: 1_800_000_060
       }, %{core_node: :serviceradar_core@test}}
    ])

    assert {:ok,
            %Camera.OpenRelaySessionResponse{
              accepted: true,
              message: "core relay session accepted",
              media_ingest_id: "media-1"
            }, %{core_node: :serviceradar_core@test}} =
             CameraMediaForwarder.open_relay_session(
               request,
               core_node: :serviceradar_core@test,
               connectivity_module: CameraMediaConnectivityStub,
               ingress_module: CameraMediaErtsIngressStub,
               rpc_module: CameraMediaRpcStub,
               timeout: 5_000
             )

    assert_received {:core_ping, :serviceradar_core@test}

    assert_received {:rpc_call, :serviceradar_core@test, CameraMediaErtsIngressStub, :open_relay_session,
                     [%Camera.OpenRelaySessionRequest{}], 5_000}
  end

  test "fails fast when core connectivity probe returns pang" do
    request = %Camera.OpenRelaySessionRequest{
      relay_session_id: "relay-forwarder-pang-1",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      camera_source_id: "camera-1",
      stream_profile_id: "main",
      lease_token: "lease-1"
    }

    Process.put({CameraMediaConnectivityStub, :results}, [:pang])

    assert {:error, :core_unavailable} =
             CameraMediaForwarder.open_relay_session(
               request,
               core_node: :serviceradar_core@test,
               connectivity_module: CameraMediaConnectivityStub,
               ingress_module: CameraMediaErtsIngressStub,
               rpc_module: CameraMediaRpcStub,
               timeout: 5_000
             )

    assert_received {:core_ping, :serviceradar_core@test}
    refute_received {:rpc_call, :serviceradar_core@test, _, _, _, _}
  end

  test "fails when core node resolution returns nil" do
    request = %Camera.OpenRelaySessionRequest{
      relay_session_id: "relay-forwarder-nil-node-1",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      camera_source_id: "camera-1",
      stream_profile_id: "main",
      lease_token: "lease-1"
    }

    assert {:error, :core_unavailable} =
             CameraMediaForwarder.open_relay_session(
               request,
               core_node_resolver: fn -> nil end,
               connectivity_module: CameraMediaConnectivityStub,
               ingress_module: CameraMediaErtsIngressStub,
               rpc_module: CameraMediaRpcStub,
               timeout: 5_000
             )

    refute_received {:core_ping, _}
    refute_received {:rpc_call, _, _, _, _, _}
  end

  test "retries relay open once when the first core RPC returns nodedown" do
    request = %Camera.OpenRelaySessionRequest{
      relay_session_id: "relay-forwarder-retry-1",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      camera_source_id: "camera-1",
      stream_profile_id: "main",
      lease_token: "lease-1"
    }

    Process.put({CameraMediaConnectivityStub, :results}, [:pong, :pong])

    Process.put({CameraMediaRpcStub, :results}, [
      {:badrpc, :nodedown},
      {:ok,
       %Camera.OpenRelaySessionResponse{
         accepted: true,
         message: "core relay session accepted",
         media_ingest_id: "media-1",
         max_chunk_bytes: 262_144,
         lease_expires_at_unix: 1_800_000_060
       }, %{core_node: :serviceradar_core@test}}
    ])

    assert {:ok,
            %Camera.OpenRelaySessionResponse{
              accepted: true,
              message: "core relay session accepted",
              media_ingest_id: "media-1"
            }, %{core_node: :serviceradar_core@test}} =
             CameraMediaForwarder.open_relay_session(
               request,
               core_node: :serviceradar_core@test,
               connectivity_module: CameraMediaConnectivityStub,
               ingress_module: CameraMediaErtsIngressStub,
               rpc_module: CameraMediaRpcStub,
               timeout: 5_000
             )

    assert_received {:core_ping, :serviceradar_core@test}
    assert_received {:core_ping, :serviceradar_core@test}

    assert_received {:rpc_call, :serviceradar_core@test, CameraMediaErtsIngressStub, :open_relay_session,
                     [%Camera.OpenRelaySessionRequest{}], 5_000}

    assert_received {:rpc_call, :serviceradar_core@test, CameraMediaErtsIngressStub, :open_relay_session,
                     [%Camera.OpenRelaySessionRequest{}], 5_000}
  end
end
