defmodule ServiceRadarAgentGateway.RemoteCaptureForwarderTest do
  use ExUnit.Case, async: true

  alias ServiceRadarAgentGateway.RemoteCaptureForwarder
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaConnectivityStub
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaRpcStub

  defmodule Ingress do
    @moduledoc false
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_call(message, _from, owner) do
      send(owner, {:ingress_call, message})
      {:reply, :ok, owner}
    end
  end

  setup do
    Process.delete({CameraMediaConnectivityStub, :results})
    Process.delete({CameraMediaRpcStub, :results})
    :ok
  end

  test "uses rpc once to open, then sends blocks and states directly to the ingress pid" do
    {:ok, ingress_pid} = start_supervised({Ingress, self()})
    Process.put({CameraMediaConnectivityStub, :results}, [:pong])
    Process.put({CameraMediaRpcStub, :results}, [{:ok, ingress_pid}])

    request = start_request()
    metadata = %{partition_id: "default", gateway_pid: self()}

    assert {:ok, ^ingress_pid} =
             RemoteCaptureForwarder.open_session(request, metadata,
               core_node: :serviceradar_core@test,
               connectivity_module: CameraMediaConnectivityStub,
               ingress_module: Ingress,
               rpc_module: CameraMediaRpcStub
             )

    assert_received {:rpc_call, :serviceradar_core@test, Ingress, :open_session, [^request, ^metadata], 15_000}

    block = %Remotecapture.CaptureBlock{session_id: request.session_id, sequence: 1, bytes: <<1>>}
    state = %Remotecapture.SessionStateChanged{session_id: request.session_id}

    assert :ok = RemoteCaptureForwarder.forward_block(ingress_pid, block)
    assert :ok = RemoteCaptureForwarder.forward_state(ingress_pid, state)
    assert :ok = RemoteCaptureForwarder.disconnect(ingress_pid, request.session_id)

    assert_received {:ingress_call, {:capture_block, ^block}}
    assert_received {:ingress_call, {:capture_state, ^state}}
    assert_received {:ingress_call, {:capture_disconnected, "01J00000000000000000000000"}}

    refute_received {:rpc_call, _, _, _, _, _}
  end

  test "retries one nodedown while opening and does not retry application errors" do
    {:ok, ingress_pid} = start_supervised({Ingress, self()})
    Process.put({CameraMediaConnectivityStub, :results}, [:pong, :pong])
    Process.put({CameraMediaRpcStub, :results}, [{:badrpc, :nodedown}, {:ok, ingress_pid}])

    assert {:ok, ^ingress_pid} =
             RemoteCaptureForwarder.open_session(start_request(), %{},
               core_node: :serviceradar_core@test,
               connectivity_module: CameraMediaConnectivityStub,
               ingress_module: Ingress,
               rpc_module: CameraMediaRpcStub
             )

    assert_received {:rpc_call, _, Ingress, :open_session, _, _}
    assert_received {:rpc_call, _, Ingress, :open_session, _, _}
  end

  defp start_request do
    %Remotecapture.StartRemoteCaptureSession{
      session_id: "01J00000000000000000000000",
      agent_id: "agent-test",
      gateway_id: "gateway-test",
      actor: "synthetic-operator",
      interface: "eth-test0"
    }
  end
end
