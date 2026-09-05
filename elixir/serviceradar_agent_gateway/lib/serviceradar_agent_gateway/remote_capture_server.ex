defmodule ServiceRadarAgentGateway.RemoteCaptureServer do
  @moduledoc """
  Terminates the agent's bidirectional remote-capture stream at the mTLS gateway.

  The handler process owns the session state. A supervised reader task pulls
  agent messages while the handler remains able to deliver a core-initiated
  cancellation even when the capture interface is silent.
  """

  use GRPC.Server, service: Remotecapture.RemotePacketCaptureService.Service

  import ServiceRadarAgentGateway.MediaIdentity,
    only: [
      enforce_component_identity!: 3,
      gateway_id: 0,
      required_agent_id: 1,
      required_string: 2,
      resolve_partition: 1
    ]

  alias ServiceRadarAgentGateway.ComponentIdentityResolver
  alias ServiceRadarAgentGateway.MediaIdentity
  alias ServiceRadarAgentGateway.RemoteCaptureForwarder

  require Logger

  @agent_gateway_component_types [:agent]
  @default_credit_bytes 1_048_576
  @max_uint32 4_294_967_295
  @terminal_states [
    :CAPTURE_SESSION_STATE_DURATION_CAP,
    :CAPTURE_SESSION_STATE_BYTE_CAP,
    :CAPTURE_SESSION_STATE_CLIENT_CANCEL,
    :CAPTURE_SESSION_STATE_AGENT_DISCONNECT,
    :CAPTURE_SESSION_STATE_FILTER_ERROR,
    :CAPTURE_SESSION_STATE_INTERFACE_DOWN,
    :CAPTURE_SESSION_STATE_UNKNOWN_REASON
  ]

  def stream_capture(request_stream, stream) do
    owner = self()

    task =
      Task.Supervisor.async_nolink(task_supervisor(), fn ->
        Enum.each(request_stream, &send(owner, {:remote_capture_message, &1}))
      end)

    try do
      receive_stream(stream, task, :awaiting_start)
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  @doc "Delivers a cancellation to a live gateway stream handler."
  def cancel(handler_pid, session_id, reason) when is_pid(handler_pid) do
    send(handler_pid, {:remote_capture_cancel, session_id, reason})
    :ok
  end

  defp receive_stream(stream, task, state) do
    receive do
      {:remote_capture_message, message} ->
        case handle_message(message, stream, state) do
          {:continue, next_state} -> receive_stream(stream, task, next_state)
          {:halt, _next_state} -> :ok
        end

      {:remote_capture_cancel, session_id, reason} ->
        next_state = send_cancel(stream, state, session_id, reason)
        receive_stream(stream, task, next_state)

      {ref, :ok} when ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        finish_stream(state)

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        fail_reader(reason, state)
    end
  end

  defp handle_message(%Remotecapture.RemotePacketCaptureClientMessage{message: {:start, start}}, stream, :awaiting_start) do
    identity = extract_identity_from_stream(stream)
    agent_id = required_agent_id(start.agent_id)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)

    session_id = required_string(start.session_id, "session_id")
    interface = required_string(start.interface, "interface")
    actor = required_string(start.actor, "actor")

    request = %{
      start
      | session_id: session_id,
        agent_id: agent_id,
        gateway_id: gateway_id(),
        actor: actor,
        interface: interface,
        initial_credit_bytes: 0
    }

    metadata = %{
      gateway_pid: self(),
      gateway_id: gateway_id(),
      partition_id: resolve_partition(identity)
    }

    with {:ok, ingress_pid, response_metadata} <- open_session(request, metadata),
         credit = initial_credit(response_metadata),
         :ok <- send_reply(stream, ack(session_id, 0, credit)) do
      {:continue,
       %{
         session_id: session_id,
         ingress_pid: ingress_pid,
         last_sequence: 0,
         credit_bytes: credit,
         cancel_sent?: false,
         terminal?: false
       }}
    else
      {:error, reason} -> raise_forward_error(reason)
    end
  rescue
    error in ArgumentError ->
      reraise GRPC.RPCError.exception(status: :invalid_argument, message: Exception.message(error)),
              __STACKTRACE__
  end

  defp handle_message(
         %Remotecapture.RemotePacketCaptureClientMessage{message: {:block, block}},
         stream,
         %{terminal?: false} = state
       ) do
    validate_session!(block.session_id, state.session_id)
    expected = state.last_sequence + 1
    block_bytes = byte_size(block.bytes)

    if block.sequence != expected do
      raise GRPC.RPCError,
        status: :data_loss,
        message: "capture block sequence gap: expected #{expected}, got #{block.sequence}"
    end

    if block_bytes > state.credit_bytes do
      raise GRPC.RPCError,
        status: :resource_exhausted,
        message: "capture block exceeds granted credit"
    end

    case forwarder().forward_block(state.ingress_pid, block) do
      :ok ->
        :ok = send_reply(stream, ack(state.session_id, block.sequence, block_bytes))
        {:continue, %{state | last_sequence: block.sequence}}

      {:ok, _accepted} ->
        :ok = send_reply(stream, ack(state.session_id, block.sequence, block_bytes))
        {:continue, %{state | last_sequence: block.sequence}}

      {:error, reason} ->
        raise_forward_error(reason)
    end
  end

  defp handle_message(
         %Remotecapture.RemotePacketCaptureClientMessage{message: {:state, update}},
         _stream,
         %{terminal?: false} = state
       ) do
    validate_session!(update.session_id, state.session_id)

    case forwarder().forward_state(state.ingress_pid, update) do
      :ok -> state_result(update, state)
      {:ok, _accepted} -> state_result(update, state)
      {:error, reason} -> raise_forward_error(reason)
    end
  end

  defp handle_message(%Remotecapture.RemotePacketCaptureClientMessage{message: {:start, _start}}, _stream, _state) do
    raise GRPC.RPCError, status: :already_exists, message: "capture stream is already started"
  end

  defp handle_message(_message, _stream, :awaiting_start) do
    raise GRPC.RPCError, status: :failed_precondition, message: "first capture message must be start"
  end

  defp handle_message(_message, _stream, _state) do
    raise GRPC.RPCError, status: :invalid_argument, message: "unsupported capture stream message"
  end

  defp state_result(update, state) do
    if update.state in @terminal_states do
      {:halt, %{state | terminal?: true}}
    else
      {:continue, state}
    end
  end

  defp send_cancel(_stream, :awaiting_start, _session_id, _reason), do: :awaiting_start

  defp send_cancel(stream, %{terminal?: false} = state, session_id, reason) do
    validate_session!(session_id, state.session_id)

    :ok =
      send_reply(stream, %Remotecapture.RemotePacketCaptureServerMessage{
        message: {:cancel, %Remotecapture.CaptureCancel{session_id: session_id, reason: to_string(reason)}}
      })

    %{state | cancel_sent?: true}
  end

  defp send_cancel(_stream, state, _session_id, _reason), do: state

  defp finish_stream(:awaiting_start) do
    raise GRPC.RPCError, status: :failed_precondition, message: "capture stream ended before start"
  end

  defp finish_stream(%{terminal?: true}), do: :ok

  defp finish_stream(state) do
    _ = forwarder().disconnect(state.ingress_pid, state.session_id)
    :ok
  end

  defp fail_reader(:normal, state), do: finish_stream(state)

  defp fail_reader(reason, state) do
    _ = finish_stream(state)
    raise GRPC.RPCError, status: :unavailable, message: "capture request stream failed: #{inspect(reason)}"
  end

  defp open_session(request, metadata) do
    case forwarder().open_session(request, metadata) do
      {:ok, ingress_pid} -> {:ok, ingress_pid, %{}}
      {:ok, ingress_pid, response_metadata} -> {:ok, ingress_pid, response_metadata}
      {:error, _reason} = error -> error
    end
  end

  defp initial_credit(metadata) do
    metadata
    |> Map.get(:initial_credit_bytes, configured_credit())
    |> normalize_credit()
    |> min(configured_credit())
  end

  defp configured_credit do
    :serviceradar_agent_gateway
    |> Application.get_env(
      :remote_capture_initial_credit_bytes,
      @default_credit_bytes
    )
    |> normalize_credit()
  end

  defp normalize_credit(value) when is_integer(value), do: min(max(value, 0), @max_uint32)
  defp normalize_credit(_value), do: 0

  defp ack(session_id, sequence, credit) do
    %Remotecapture.RemotePacketCaptureServerMessage{
      message:
        {:ack,
         %Remotecapture.CaptureAck{
           session_id: session_id,
           gateway_id: gateway_id(),
           last_accepted_sequence: sequence,
           credit_bytes: credit
         }}
    }
  end

  defp validate_session!(actual, expected) do
    if actual != expected do
      raise GRPC.RPCError, status: :permission_denied, message: "capture session_id mismatch"
    end
  end

  defp send_reply(%{test_pid: test_pid}, response) when is_pid(test_pid) do
    send(test_pid, {:remote_capture_stream_reply, response})
    :ok
  end

  defp send_reply(stream, response), do: GRPC.Server.send_reply(stream, response)

  defp raise_forward_error(%GRPC.RPCError{} = error), do: raise(error)

  defp raise_forward_error(reason) do
    raise GRPC.RPCError,
      status: :unavailable,
      message: "failed to forward remote capture: #{inspect(reason)}"
  end

  defp task_supervisor do
    Application.get_env(
      :serviceradar_agent_gateway,
      :remote_capture_task_supervisor,
      ServiceRadarAgentGateway.DeliveryTaskSupervisor
    )
  end

  defp forwarder do
    Application.get_env(
      :serviceradar_agent_gateway,
      :remote_capture_forwarder,
      RemoteCaptureForwarder
    )
  end

  defp identity_resolver do
    Application.get_env(
      :serviceradar_agent_gateway,
      :remote_capture_identity_resolver,
      ComponentIdentityResolver
    )
  end

  defp extract_identity_from_stream(stream) do
    MediaIdentity.extract_identity_from_stream(stream, identity_resolver(), "Remote capture")
  end
end
