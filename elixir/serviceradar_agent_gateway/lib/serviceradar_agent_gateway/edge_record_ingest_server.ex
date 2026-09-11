defmodule ServiceRadarAgentGateway.EdgeRecordIngestServer do
  @moduledoc """
  Terminates the agent's mTLS bidirectional `EdgeRecordIngestService.Stream` RPC at the gateway
  (unify-sweep-results-proto task 3.1).

  This gives `ServiceRadarAgentGateway.JetStreamPublisher.publish_record/2` its first production
  caller: nothing else offered to it before this server existed (see that module's and
  `ServiceRadar.Edge.PublishPipeline`'s moduledocs). Each stream is exactly one spool lane --
  opened once via `lane_open`, then fed a sequence of `delivery_frame`s -- mirroring
  `ServiceRadarAgentGateway.RemoteCaptureServer`'s receive-loop shape.

  ## Deliberately narrow scope

  Task 3.1 is the RPC server and its wiring into the already-tested publish pipeline; it does NOT
  implement the full grant/contract verification of task 3.2, the exact-byte/retained-memory
  binding of task 3.4, the six-outcome-to-five-wire-disposition mapping of task 3.5, the
  transport-provenance stamping of task 3.9, or the two-watermark reclaim state machine of task
  3.10. What this server DOES verify before publishing:

    * the client certificate resolves to an authenticated `:agent` identity
      (`ServiceRadarAgentGateway.ComponentIdentityResolver.resolve_from_cert/1`);
    * the `edge-records:v1` capability is ready (`ServiceRadarAgentGateway.EdgeRecordCapability`);
    * `lane_open` names a routable `{route_profile, traffic_class}` pair
      (`ServiceRadar.Edge.PublisherLane.for_lane/2`);
    * each frame decodes as a well-formed `EdgeRecordV1`
      (`ServiceRadar.Edge.WireDecode.decode_record/1`) whose `record_sha256` matches its bytes.

  The disposition mapping used here is the subset `JetStreamPublisher.publish_record/2` can
  actually produce today, matching `ServiceRadar.Edge.PublishPipeline`'s own `disposition_of/1`:
  a durable PubAck resolves ACCEPTED_AUTHORITATIVE, a decode/integrity failure that can never
  succeed on retry resolves REJECTED_PERMANENT, and everything else caps the watermark
  REJECTED_RETRYABLE without resolving. `:not_ready`/`:systemic` decode faults are PAUSED (no
  disposition sent for that frame at all) per `WireDecode`'s own contract, rather than folded into
  either resolving class.
  """

  use GRPC.Server, service: Serviceradar.Edge.V1.EdgeRecordIngestService.Service

  alias ServiceRadar.Edge.PublisherLane
  alias Serviceradar.Edge.V1.EdgeDeliveryAckV1
  alias Serviceradar.Edge.V1.EdgeRecordClientMessage
  alias Serviceradar.Edge.V1.EdgeRecordDisposition
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpenAck
  alias Serviceradar.Edge.V1.EdgeRecordServerMessage
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadarAgentGateway.ComponentIdentityResolver
  alias ServiceRadarAgentGateway.EdgeRecordCapability
  alias ServiceRadarAgentGateway.MediaIdentity

  require Logger

  @agent_gateway_component_types [:agent]
  @unspecified_route_profile :EDGE_RECORD_ROUTE_PROFILE_UNSPECIFIED
  @unspecified_traffic_class :EDGE_RECORD_TRAFFIC_CLASS_UNSPECIFIED
  @default_credit_bytes 64 * 1024 * 1024
  @default_credit_frames 64
  @max_uint32 4_294_967_295
  @accepted :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE
  @permanent :EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT

  def stream(request_stream, stream) do
    owner = self()

    task =
      Task.Supervisor.async_nolink(task_supervisor(), fn ->
        Enum.each(request_stream, &send(owner, {:edge_record_message, &1}))
      end)

    try do
      receive_stream(stream, task, :awaiting_lane_open)
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp receive_stream(stream, task, state) do
    receive do
      {:edge_record_message, message} ->
        receive_stream(stream, task, handle_message(message, stream, state))

      {ref, :ok} when ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        finish_stream(state)

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        fail_reader(reason, state)
    end
  end

  defp handle_message(%EdgeRecordClientMessage{payload: {:lane_open, lane_open}}, stream, :awaiting_lane_open) do
    identity = extract_identity_from_stream(stream)
    require_agent_identity!(identity)

    if !capability().ready?() do
      raise GRPC.RPCError,
        status: :unavailable,
        message: "#{capability().id()} capability is not ready"
    end

    spool_id = required_bytes(lane_open.spool_id, "spool_id")
    route_profile = lane_open.route_profile
    traffic_class = lane_open.traffic_class

    if route_profile == @unspecified_route_profile or traffic_class == @unspecified_traffic_class do
      raise GRPC.RPCError, status: :invalid_argument, message: "route_profile and traffic_class are required"
    end

    case PublisherLane.for_lane(route_profile, traffic_class) do
      {:ok, _lane} -> :ok
      {:error, _reason} -> raise GRPC.RPCError, status: :invalid_argument, message: "unroutable lane"
    end

    byte_credits = grant_credits(lane_open.requested_byte_credits, configured_credit_bytes())
    frame_credits = grant_credits(lane_open.requested_frame_credits, configured_credit_frames())

    :ok =
      send_reply(stream, %EdgeRecordServerMessage{
        payload:
          {:lane_open_ack,
           %EdgeRecordLaneOpenAck{
             spool_id: spool_id,
             session_nonce: lane_open.session_nonce,
             granted_byte_credits: byte_credits,
             granted_frame_credits: frame_credits,
             route_profile: route_profile,
             traffic_class: traffic_class
           }}
      })

    %{
      identity: identity,
      spool_id: spool_id,
      session_nonce: lane_open.session_nonce,
      route_profile: route_profile,
      traffic_class: traffic_class,
      resolved_through_sequence: 0
    }
  rescue
    error in ArgumentError ->
      reraise GRPC.RPCError.exception(status: :invalid_argument, message: Exception.message(error)),
              __STACKTRACE__
  end

  defp handle_message(%EdgeRecordClientMessage{payload: {:lane_open, _lane_open}}, _stream, _state) do
    raise GRPC.RPCError, status: :already_exists, message: "edge record lane is already open"
  end

  defp handle_message(_message, _stream, :awaiting_lane_open) do
    raise GRPC.RPCError, status: :failed_precondition, message: "first edge record message must be lane_open"
  end

  defp handle_message(%EdgeRecordClientMessage{payload: {:delivery_frame, frame}}, stream, state) do
    if frame.spool_id != state.spool_id do
      raise GRPC.RPCError, status: :permission_denied, message: "delivery_frame spool_id mismatch"
    end

    sequence = required_positive_sequence(frame.sequence)

    case decode_and_verify(frame) do
      {:ok, record} ->
        publish_frame(stream, state, sequence, frame, record)

      {:error, :permanent, reason} ->
        Logger.warning("edge record permanently rejected: #{inspect(reason)}")
        ack(stream, state, sequence, @permanent)

      {:error, :paused, reason} ->
        Logger.warning("edge record decode paused (not resolved, no disposition sent): #{inspect(reason)}")

        state
    end
  end

  defp handle_message(_message, _stream, _state) do
    raise GRPC.RPCError, status: :invalid_argument, message: "unsupported edge record stream message"
  end

  defp decode_and_verify(frame) do
    case WireDecode.decode_record(frame.record_bytes) do
      {:ok, record} ->
        verify_record(frame, record)

      {:error, reason} when reason in [:too_large, :poison] ->
        {:error, :permanent, reason}

      {:error, reason} ->
        {:error, :paused, reason}
    end
  end

  defp verify_record(frame, record) do
    if :crypto.hash(:sha256, frame.record_bytes) == frame.record_sha256 do
      {:ok, record}
    else
      {:error, :permanent, :record_sha256_mismatch}
    end
  end

  defp publish_frame(stream, state, sequence, frame, record) do
    publication = %{
      slot: %{
        network_scope_id: record.network_scope_id,
        authenticated_agent_id: state.identity.component_id,
        spool_id: state.spool_id,
        sequence: sequence
      },
      route_profile: state.route_profile,
      traffic_class: state.traffic_class,
      # The only partition rule this installation can evaluate today; see
      # `ServiceRadar.Edge.StreamRoute`'s moduledoc. The contract registry that pins a rule per
      # output contract is task 3.8's scope.
      partition_rule: :network_scope_v1,
      record_bytes: frame.record_bytes,
      record_sha256: frame.record_sha256,
      semantic_envelope_sha256: record.semantic_envelope_sha256
    }

    case publisher().publish_record(publication) do
      {:ok, _pub_ack} ->
        ack(stream, state, sequence, @accepted)

      {:error, :poison} ->
        ack(stream, state, sequence, @permanent)

      {:error, reason} ->
        Logger.warning("edge record publish did not resolve: #{inspect(reason)}")
        # RETRYABLE never resolves the sequence -- the watermark must not advance past a record
        # that may not be durable. No ack is sent for this frame; the agent's own deadline drives
        # its retry.
        state
    end
  end

  defp ack(stream, state, sequence, disposition) do
    resolved_through =
      if disposition in [@accepted, @permanent], do: sequence, else: state.resolved_through_sequence

    :ok =
      send_reply(stream, %EdgeRecordServerMessage{
        payload:
          {:ack,
           %EdgeDeliveryAckV1{
             spool_id: state.spool_id,
             resolved_through_sequence: resolved_through,
             dispositions: [
               %EdgeRecordDisposition{sequence: sequence, kind: disposition}
             ],
             session_nonce: state.session_nonce
           }}
      })

    %{state | resolved_through_sequence: resolved_through}
  end

  defp finish_stream(:awaiting_lane_open) do
    raise GRPC.RPCError, status: :failed_precondition, message: "edge record stream ended before lane_open"
  end

  defp finish_stream(_state), do: :ok

  defp fail_reader(:normal, state), do: finish_stream(state)

  defp fail_reader(reason, _state) do
    raise GRPC.RPCError, status: :unavailable, message: "edge record request stream failed: #{inspect(reason)}"
  end

  defp require_agent_identity!(identity) do
    if Map.get(identity, :component_type) not in @agent_gateway_component_types do
      raise GRPC.RPCError, status: :permission_denied, message: "component type is not allowed"
    end
  end

  defp required_bytes(value, field_name) do
    case value do
      bytes when is_binary(bytes) and bytes != "" -> bytes
      _ -> raise ArgumentError, "#{field_name} is required"
    end
  end

  defp required_positive_sequence(sequence) when is_integer(sequence) and sequence >= 1, do: sequence

  defp required_positive_sequence(_sequence) do
    raise GRPC.RPCError, status: :invalid_argument, message: "sequence must be a positive integer"
  end

  defp grant_credits(requested, configured_max) do
    requested
    |> normalize_credit()
    |> min(configured_max)
  end

  defp normalize_credit(value) when is_integer(value), do: min(max(value, 0), @max_uint32)
  defp normalize_credit(_value), do: 0

  defp configured_credit_bytes do
    :serviceradar_agent_gateway
    |> Application.get_env(:edge_record_ingest_initial_credit_bytes, @default_credit_bytes)
    |> normalize_credit()
  end

  defp configured_credit_frames do
    :serviceradar_agent_gateway
    |> Application.get_env(:edge_record_ingest_initial_credit_frames, @default_credit_frames)
    |> normalize_credit()
  end

  defp task_supervisor do
    Application.get_env(
      :serviceradar_agent_gateway,
      :edge_record_ingest_task_supervisor,
      ServiceRadarAgentGateway.DeliveryTaskSupervisor
    )
  end

  defp publisher do
    Application.get_env(
      :serviceradar_agent_gateway,
      :edge_record_ingest_publisher,
      ServiceRadarAgentGateway.JetStreamPublisher
    )
  end

  defp capability do
    Application.get_env(
      :serviceradar_agent_gateway,
      :edge_record_ingest_capability,
      EdgeRecordCapability
    )
  end

  defp identity_resolver do
    Application.get_env(
      :serviceradar_agent_gateway,
      :edge_record_ingest_identity_resolver,
      ComponentIdentityResolver
    )
  end

  defp extract_identity_from_stream(stream) do
    MediaIdentity.extract_identity_from_stream(stream, identity_resolver(), "Edge record ingest")
  end

  defp send_reply(%{test_pid: test_pid}, response) when is_pid(test_pid) do
    send(test_pid, {:edge_record_stream_reply, response})
    :ok
  end

  # GRPC.Server.send_reply/2 returns the stream, not :ok; both clauses keep the :ok contract.
  defp send_reply(stream, response) do
    _stream = GRPC.Server.send_reply(stream, response)
    :ok
  end
end
