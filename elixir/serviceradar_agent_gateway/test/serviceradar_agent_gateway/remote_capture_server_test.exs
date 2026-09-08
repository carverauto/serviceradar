defmodule ServiceRadarAgentGateway.RemoteCaptureServerTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.RemoteCaptureServer
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaAdapterStub
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaIdentityResolverStub
  alias ServiceRadarAgentGateway.TestSupport.RemoteCaptureForwarderStub

  @session_id "01J00000000000000000000000"

  setup do
    previous = %{
      forwarder: Application.get_env(:serviceradar_agent_gateway, :remote_capture_forwarder),
      resolver: Application.get_env(:serviceradar_agent_gateway, :remote_capture_identity_resolver),
      test_pid: Application.get_env(:serviceradar_agent_gateway, :remote_capture_test_pid),
      supervisor: Application.get_env(:serviceradar_agent_gateway, :remote_capture_task_supervisor)
    }

    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})

    Application.put_env(
      :serviceradar_agent_gateway,
      :remote_capture_forwarder,
      RemoteCaptureForwarderStub
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :remote_capture_identity_resolver,
      CameraMediaIdentityResolverStub
    )

    Application.put_env(:serviceradar_agent_gateway, :remote_capture_test_pid, self())

    Application.put_env(
      :serviceradar_agent_gateway,
      :remote_capture_task_supervisor,
      __MODULE__.TaskSupervisor
    )

    on_exit(fn ->
      restore_env(:remote_capture_forwarder, previous.forwarder)
      restore_env(:remote_capture_identity_resolver, previous.resolver)
      restore_env(:remote_capture_test_pid, previous.test_pid)
      restore_env(:remote_capture_task_supervisor, previous.supervisor)
    end)

    %{supervisor: supervisor}
  end

  test "opens once, forwards ordered blocks, and acknowledges only after downstream accepts" do
    messages = [
      client({:start, start()}),
      client({:block, block(1, <<1, 2, 3>>)}),
      client({:state, state(:CAPTURE_SESSION_STATE_ACTIVE)}),
      client({:state, state(:CAPTURE_SESSION_STATE_DURATION_CAP)})
    ]

    assert :ok = RemoteCaptureServer.stream_capture(messages, stream())

    assert_received {:remote_capture_open, handler_pid, opened, metadata}
    assert is_pid(handler_pid)
    assert opened.session_id == @session_id
    assert opened.gateway_id == Atom.to_string(node())
    assert opened.initial_credit_bytes == 0
    assert metadata.partition_id == "default"
    assert metadata.gateway_pid == handler_pid

    assert_received {:remote_capture_block, ^handler_pid, %Remotecapture.CaptureBlock{sequence: 1}}

    assert_received {:remote_capture_state, ^handler_pid,
                     %Remotecapture.SessionStateChanged{state: :CAPTURE_SESSION_STATE_ACTIVE}}

    assert_received {:remote_capture_state, ^handler_pid,
                     %Remotecapture.SessionStateChanged{
                       state: :CAPTURE_SESSION_STATE_DURATION_CAP
                     }}

    assert_receive {:remote_capture_stream_reply,
                    %Remotecapture.RemotePacketCaptureServerMessage{
                      message: {:ack, %Remotecapture.CaptureAck{last_accepted_sequence: 0, credit_bytes: 32}}
                    }}

    assert_receive {:remote_capture_stream_reply,
                    %Remotecapture.RemotePacketCaptureServerMessage{
                      message: {:ack, %Remotecapture.CaptureAck{last_accepted_sequence: 1, credit_bytes: 3}}
                    }}

    refute_received {:remote_capture_disconnect, _, _}
  end

  test "rejects a stream whose first message is not start" do
    error =
      assert_raise GRPC.RPCError, fn ->
        RemoteCaptureServer.stream_capture([client({:block, block(1, <<0>>)})], stream())
      end

    assert error.status == GRPC.Status.failed_precondition()
  end

  test "rejects a sequence gap instead of producing a plausible corrupt capture" do
    error =
      assert_raise GRPC.RPCError, fn ->
        RemoteCaptureServer.stream_capture(
          [client({:start, start()}), client({:block, block(2, <<0>>)})],
          stream()
        )
      end

    assert error.status == GRPC.Status.data_loss()
  end

  test "enforces gateway credit even when the agent self-grants more" do
    error =
      assert_raise GRPC.RPCError, fn ->
        RemoteCaptureServer.stream_capture(
          [client({:start, start()}), client({:block, block(1, :binary.copy(<<0>>, 33))})],
          stream()
        )
      end

    assert error.status == GRPC.Status.resource_exhausted()
    refute_received {:remote_capture_block, _, _}
  end

  test "refuses an unattributed capture before opening core ingress" do
    error =
      assert_raise GRPC.RPCError, fn ->
        RemoteCaptureServer.stream_capture(
          [client({:start, %{start() | actor: ""}})],
          stream()
        )
      end

    assert error.status == GRPC.Status.invalid_argument()
    refute_received {:remote_capture_open, _, _, _}
  end

  test "sends cancellation while the agent request stream is silent" do
    owner = self()
    response_stream = stream()

    silent_stream =
      Stream.resource(
        fn -> :start end,
        fn
          :start -> {[client({:start, start()})], :silent}
          :silent -> receive do: ({:finish_reader, ^owner} -> {:halt, :done})
        end,
        fn _state -> :ok end
      )

    task = Task.async(fn -> RemoteCaptureServer.stream_capture(silent_stream, response_stream) end)

    assert_receive {:remote_capture_open, handler_pid, _request, _metadata}, 1_000
    assert handler_pid == task.pid

    started = System.monotonic_time(:millisecond)
    assert :ok = RemoteCaptureServer.cancel(handler_pid, @session_id, "operator stopped")

    assert_receive {:remote_capture_stream_reply,
                    %Remotecapture.RemotePacketCaptureServerMessage{
                      message:
                        {:cancel,
                         %Remotecapture.CaptureCancel{
                           session_id: @session_id,
                           reason: "operator stopped"
                         }}
                    }},
                   1_000

    assert System.monotonic_time(:millisecond) - started < 1_000
    Task.shutdown(task, :brutal_kill)
  end

  defp start do
    %Remotecapture.StartRemoteCaptureSession{
      session_id: @session_id,
      agent_id: "agent-1",
      gateway_id: "untrusted-gateway",
      actor: "synthetic-operator",
      interface: "eth-test0",
      initial_credit_bytes: 4_294_967_295
    }
  end

  defp block(sequence, bytes) do
    %Remotecapture.CaptureBlock{session_id: @session_id, sequence: sequence, bytes: bytes}
  end

  defp state(value) do
    %Remotecapture.SessionStateChanged{session_id: @session_id, state: value}
  end

  defp client(message), do: %Remotecapture.RemotePacketCaptureClientMessage{message: message}

  defp stream do
    %{adapter: CameraMediaAdapterStub, payload: :test, test_pid: self()}
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)
end
