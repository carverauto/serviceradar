defmodule ServiceRadarAgentGateway.CameraMediaForwarderTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadarAgentGateway.CameraMediaForwarder
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaConnectivityStub
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaErtsIngressStub
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaRpcStub

  defmodule IngressServer do
    @moduledoc false
    use GenServer

    def start_link(mode), do: GenServer.start_link(__MODULE__, mode)

    @impl true
    def init(mode), do: {:ok, mode}

    @impl true
    def handle_call({:upload_media, _chunks}, _from, :close), do: {:stop, :normal, :close}
    def handle_call({:upload_media, _chunks}, _from, :shutdown), do: {:stop, :shutdown, :shutdown}
    def handle_call({:upload_media, _chunks}, _from, :nodedown), do: {:stop, {:nodedown, :core@synthetic}, :nodedown}

    def handle_call({:upload_media, _chunks}, _from, :other), do: {:stop, :kaboom, :other}
    def handle_call({:upload_media, _chunks}, _from, :timeout), do: {:noreply, :timeout}
  end

  test "classifies noproc, shutdown, nodedown, and other ingress exits without returning media bytes" do
    payload = "synthetic-private-media"

    {:ok, dead} = IngressServer.start_link(:close)
    Process.unlink(dead)
    GenServer.stop(dead)

    cases = [
      {dead, GRPC.Status.not_found(), "open a new relay session"},
      {:shutdown, GRPC.Status.not_found(), "open a new relay session"},
      {:nodedown, GRPC.Status.unavailable(), "reconnect and open a new relay session"},
      {:other, GRPC.Status.unavailable(), "check core health and open a new relay session"}
    ]

    for {mode_or_pid, status, recovery} <- cases do
      pid =
        case mode_or_pid do
          pid when is_pid(pid) ->
            pid

          mode ->
            {:ok, pid} = IngressServer.start_link(mode)
            Process.unlink(pid)
            pid
        end

      log =
        capture_log([level: :debug], fn ->
          assert {:error, %GRPC.RPCError{status: ^status, message: message}} =
                   CameraMediaForwarder.upload_media(
                     [%Camera.MediaChunk{payload: payload, sequence: 7}],
                     ingress_pid: pid,
                     timeout: 5_000
                   )

          assert message =~ recovery
          refute message =~ payload
        end)

      classification =
        log
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "ERTS camera media ingress call failed"))

      assert classification != []
      refute Enum.any?(classification, &String.contains?(&1, payload))
    end
  end

  test "distinguishes ingress closure and timeout without logging media payloads" do
    for {mode, status, recovery, timeout} <- [
          {:close, GRPC.Status.not_found(), "open a new relay session", 5_000},
          {:timeout, GRPC.Status.deadline_exceeded(), "check core load", 5}
        ] do
      pid = start_supervised!({IngressServer, mode}, id: mode)
      payload = "synthetic-private-media"

      log =
        capture_log([level: :debug], fn ->
          assert {:error, %GRPC.RPCError{status: ^status, message: message}} =
                   CameraMediaForwarder.upload_media(
                     [%Camera.MediaChunk{payload: payload, sequence: 1}],
                     ingress_pid: pid,
                     timeout: timeout
                   )

          assert message =~ recovery
        end)

      assert log =~ "core_node="
      assert log =~ "operation=upload_media failure="
      refute log =~ payload
    end
  end

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
         max_chunk_bytes: 1_048_576,
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
         max_chunk_bytes: 1_048_576,
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
