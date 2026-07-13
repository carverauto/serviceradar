defmodule ServiceRadarAgentGateway.DesktopMediaForwarderTest do
  use ExUnit.Case, async: true

  alias ServiceRadarAgentGateway.DesktopMediaForwarder
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaConnectivityStub
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaRpcStub
  alias ServiceRadarAgentGateway.TestSupport.DesktopMediaErtsIngressStub

  setup do
    Process.delete({CameraMediaConnectivityStub, :results})
    Process.delete({CameraMediaRpcStub, :results})
    :ok
  end

  test "pings core before forwarding a desktop media frame" do
    frame = frame()
    session = session()

    Process.put({CameraMediaConnectivityStub, :results}, [:pong])

    Process.put({CameraMediaRpcStub, :results}, [
      {:ok,
       %Desktopmedia.DesktopMediaAck{
         desktop_session_id: frame.desktop_session_id,
         media_session_id: frame.media_session_id,
         media_ingest_id: frame.media_ingest_id,
         gateway_id: session.gateway_id,
         last_accepted_sequence: frame.sequence,
         credit_bytes: 3
       }}
    ])

    assert {:ok,
            %Desktopmedia.DesktopMediaAck{
              desktop_session_id: "desktop-forwarder-1",
              media_session_id: "media-forwarder-1",
              media_ingest_id: "ingest-forwarder-1",
              last_accepted_sequence: 7,
              credit_bytes: 3
            }} =
             DesktopMediaForwarder.forward_frame(
               frame,
               session,
               core_node: :serviceradar_core@test,
               connectivity_module: CameraMediaConnectivityStub,
               ingress_module: DesktopMediaErtsIngressStub,
               rpc_module: CameraMediaRpcStub,
               timeout: 5_000
             )

    assert_received {:core_ping, :serviceradar_core@test}

    assert_received {:rpc_call, :serviceradar_core@test, DesktopMediaErtsIngressStub, :forward_frame,
                     [%Desktopmedia.DesktopMediaFrameChunk{}, %{desktop_session_id: "desktop-forwarder-1"}], 5_000}
  end

  test "retries desktop frame forward once when the first core RPC returns nodedown" do
    frame = frame()
    session = session()

    Process.put({CameraMediaConnectivityStub, :results}, [:pong, :pong])

    Process.put({CameraMediaRpcStub, :results}, [
      {:badrpc, :nodedown},
      {:ok,
       %Desktopmedia.DesktopMediaAck{
         desktop_session_id: frame.desktop_session_id,
         media_session_id: frame.media_session_id,
         media_ingest_id: frame.media_ingest_id,
         gateway_id: session.gateway_id,
         last_accepted_sequence: frame.sequence,
         credit_bytes: 3
       }}
    ])

    assert {:ok, %Desktopmedia.DesktopMediaAck{last_accepted_sequence: 7}} =
             DesktopMediaForwarder.forward_frame(
               frame,
               session,
               core_node: :serviceradar_core@test,
               connectivity_module: CameraMediaConnectivityStub,
               ingress_module: DesktopMediaErtsIngressStub,
               rpc_module: CameraMediaRpcStub,
               timeout: 5_000
             )

    assert_received {:core_ping, :serviceradar_core@test}
    assert_received {:core_ping, :serviceradar_core@test}

    assert_received {:rpc_call, :serviceradar_core@test, DesktopMediaErtsIngressStub, :forward_frame, _, 5_000}
    assert_received {:rpc_call, :serviceradar_core@test, DesktopMediaErtsIngressStub, :forward_frame, _, 5_000}
  end

  test "fails fast when core connectivity probe returns pang" do
    Process.put({CameraMediaConnectivityStub, :results}, [:pang])

    assert {:error, :core_unavailable} =
             DesktopMediaForwarder.forward_frame(
               frame(),
               session(),
               core_node: :serviceradar_core@test,
               connectivity_module: CameraMediaConnectivityStub,
               ingress_module: DesktopMediaErtsIngressStub,
               rpc_module: CameraMediaRpcStub,
               timeout: 5_000
             )

    assert_received {:core_ping, :serviceradar_core@test}
    refute_received {:rpc_call, :serviceradar_core@test, _, _, _, _}
  end

  test "explicitly closes the matching core desktop ingress" do
    Process.put({CameraMediaConnectivityStub, :results}, [:pong])
    Process.put({CameraMediaRpcStub, :results}, [:ok])

    assert :ok =
             DesktopMediaForwarder.close_session("desktop-forwarder-1",
               core_node: :serviceradar_core@test,
               connectivity_module: CameraMediaConnectivityStub,
               ingress_module: DesktopMediaErtsIngressStub,
               rpc_module: CameraMediaRpcStub,
               timeout: 5_000
             )

    assert_received {:core_ping, :serviceradar_core@test}

    assert_received {:rpc_call, :serviceradar_core@test, DesktopMediaErtsIngressStub, :close_session,
                     ["desktop-forwarder-1"], 5_000}
  end

  defp frame do
    %Desktopmedia.DesktopMediaFrameChunk{
      desktop_session_id: "desktop-forwarder-1",
      media_session_id: "media-forwarder-1",
      media_ingest_id: "ingest-forwarder-1",
      agent_id: "agent-1",
      sequence: 7,
      payload: <<1, 2, 3>>
    }
  end

  defp session do
    %{
      desktop_session_id: "desktop-forwarder-1",
      media_session_id: "media-forwarder-1",
      media_ingest_id: "ingest-forwarder-1",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      max_chunk_bytes: 1_048_576
    }
  end
end
