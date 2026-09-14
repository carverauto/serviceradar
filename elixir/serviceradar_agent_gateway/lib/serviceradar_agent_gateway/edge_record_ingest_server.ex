defmodule ServiceRadarAgentGateway.EdgeRecordIngestServer do
  @moduledoc """
  Terminates the agent's mTLS bidirectional `EdgeRecordIngestService.Stream` RPC at the gateway
  (unify-sweep-results-proto task 3.1), and is the production offerer of
  `ServiceRadar.Edge.PublishPipeline` (task 3.3(c)).

  Each stream is exactly one spool lane -- opened once via `lane_open`, then fed a sequence of
  `delivery_frame`s -- mirroring `ServiceRadarAgentGateway.RemoteCaptureServer`'s receive-loop
  shape.

  ## Deliberately narrow scope

  Task 3.1 is the RPC server and its wiring into the already-tested publish pipeline; it does NOT
  implement the full grant/contract verification of task 3.2, the exact-byte/retained-memory
  binding of task 3.4, the six-outcome-to-five-wire-disposition mapping of task 3.5 (including
  rejection codes on dispositions), the transport-provenance stamping of task 3.9,
  or the two-watermark reclaim state machine of task 3.10. What this server DOES verify before
  publishing:

    * the client certificate resolves to an authenticated `:agent` identity
      (`ServiceRadarAgentGateway.ComponentIdentityResolver.resolve_from_cert/1`);
    * the `edge-records:v1` capability is ready (`ServiceRadarAgentGateway.EdgeRecordCapability`);
    * `lane_open` names a routable `{route_profile, traffic_class}` pair
      (`ServiceRadar.Edge.PublisherLane.for_lane/2`) whose `PublishPipeline` is running;
    * each `delivery_frame` names a sequence inside the frame credits granted at `lane_open`, counted
      from the watermark this session has acked; one beyond it ends the stream `:resource_exhausted`
      before anything about it is kept;
    * each frame decodes as a well-formed `EdgeRecordV1`
      (`ServiceRadar.Edge.WireDecode.decode_record/1`) whose `record_sha256` matches its bytes;
    * each decoded record is admitted by `ServiceRadarAgentGateway.EdgeContractRegistry.admit/3`
      BEFORE it is offered to the pipeline (task 3.8, narrowed): its provenance must match the
      authenticated session, its output contract must be an `active` bundle of the loaded
      snapshot, and the published route profile, traffic class and partition rule come from that
      registry entry. A rejection resolves REJECTED_PERMANENT; a withhold (rollout lag, a bundle
      that is not active) and a hold (security-revoked bundle) are never offered and record
      nothing, so the sequence stays unresolved.

  ## Frames are OFFERED, and acks follow the pipeline

  A verified frame is offered to its class's pipeline (`PublishPipeline.via/1`, started last in
  each `ServiceRadar.Edge.LaneSupervisor`) and this process moves straight on to the next message:
  publishing is no longer one synchronous request per frame. Outcomes come back as
  `:edge_publish_outcome` messages, in whatever order the PubAcks land.

  The class's queue is shared by every stream on it, so an offer can be refused `:queue_full`. The
  frame is not dropped for that: this process waits for one of its own outstanding outcomes,
  handles it exactly as the receive loop would, and offers the frame again. Its own work leaving
  the pipeline is what makes room, so a saturated class slows each stream to the pace of its own
  PubAcks. A stream with nothing of its own outstanding has nothing to wait for, and ends
  `:resource_exhausted` for the agent to retry rather than polling a queue other streams fill.

  An ack is sent only when the pipeline's contiguous resolved watermark moves, and it carries the
  kind of EVERY sequence it newly covers, in order. That is the agent's contract rather than a
  presentation choice: `edgerecord.ValidateAck` accepts dispositions only as a contiguous ascending
  run from its previous watermark plus one, ending at `resolved_through_sequence`. A per-frame ack
  for an out-of-order PubAck, or one that moved the watermark past a withheld sequence, is refused
  there.

  The watermark is cumulative, and the agent sends each sequence once per session. So the first
  sequence a session leaves unresolved -- withheld or held by the contract registry, paused, or
  retryable -- caps the lane: no later sequence of that session is acked, even one that published
  durably, and the agent's next session replays from it. Nothing here tracks that sequence: it is
  a gap in the pipeline's prefix, and the gap is what stops the watermark.

  The dispositions are the subset `JetStreamPublisher.publish_record/2` can produce today, matching
  the pipeline's own classification: a durable PubAck resolves ACCEPTED_AUTHORITATIVE; a decode or
  integrity failure that can never succeed on retry, or a record the contract registry rejects,
  resolves REJECTED_PERMANENT, recorded through `PublishPipeline.reject_permanent/3` so it fills
  its place in the prefix instead of leaving a gap nothing could close; everything else is
  REJECTED_RETRYABLE, which caps the watermark and sends nothing, so the agent's own deadline
  drives its retry. `:not_ready`/`:systemic` decode faults are PAUSED (no disposition for that
  frame at all) per `WireDecode`'s own contract.

  ## The pipeline lane is bound on the first VERIFIED record

  A pipeline lane is `{network_scope_id, agent, spool}`, and the network scope arrives on the
  record rather than on `lane_open`. The lane is therefore opened when the first frame decodes and
  matches its digest, and a later verified record naming a different scope ends the stream
  `:permission_denied`. One agent spool never carries records from more than one
  `network_scope_id` (ingestion-routing, "An agent spool carries exactly one network scope"), so a
  second scope breaks that invariant rather than naming a second lane: one spool's sequences cannot
  be split across two prefixes without wedging both.

  A frame rejected permanently before that point has no lane to be recorded on. Its outcome is
  kept here and acked by the same contiguous rule. The lane then opens at the first sequence this
  session has not already acked, and a rejection still waiting behind a gap is replayed into it.

  The lane is bound before the record is admitted, so a verified record the contract registry
  rejects, withholds or holds still binds it and still has its scope checked: which scope a spool
  carries does not depend on whether this gateway admits the record's contract.

  ## Ending a stream

  The agent half-closes BEFORE it reads its acks, so when the request stream ends this server waits
  up to `:edge_record_ingest_drain_timeout_ms` for the outcomes still in flight. Whatever is
  unresolved at the deadline is left to the agent's retry. The pipeline dying ends the stream
  `:unavailable`: its trackers are gone, and only the agent can say where the lane resumes.

  ## Lane isolation (task 3.6)

    * The lane never enters `ServiceRadarAgentGateway.StatusBuffer`. An unresolved publication is
      withheld, so the agent spool keeps it. The only place a frame waits here is its class
      pipeline's bounded queue.
    * Only a PubAck is acked durable. The lane's pipeline workers publish by JetStream
      request/reply, never by a Core NATS publish or an ERTS/RPC handoff, and
      `JetStreamPublisher.publish_record/2` returns `{:ok, _}` only for a PubAck it parsed and
      fenced to the stream the request named.
    * The lane keeps no state of its own across restarts. Its state lives in the stream process and
      in the pipeline lane that process owns, which the pipeline drops when the process dies, and
      the request reader is ended with it, so a reconnect replays the spool through the same
      publication path rather than recovering anything from the gateway. The exception is a frame
      whose publish was in flight when the lane died: its pipeline worker, not the stream process,
      owns the `PublisherPool` attempt, so until that attempt ends a replay of the frame is refused
      `:attempt_in_flight` and withheld.

  `ServiceRadarAgentGateway.EdgeRecordIngestLaneIsolationTest` observes each of these.
  """

  use GRPC.Server, service: Serviceradar.Edge.V1.EdgeRecordIngestService.Service

  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublishPipeline
  alias ServiceRadar.Edge.ResolvedPrefix
  alias Serviceradar.Edge.V1.EdgeDeliveryAckV1
  alias Serviceradar.Edge.V1.EdgeRecordClientMessage
  alias Serviceradar.Edge.V1.EdgeRecordDisposition
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpenAck
  alias Serviceradar.Edge.V1.EdgeRecordServerMessage
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadarAgentGateway.ComponentIdentityResolver
  alias ServiceRadarAgentGateway.EdgeContractRegistry
  alias ServiceRadarAgentGateway.EdgeRecordCapability
  alias ServiceRadarAgentGateway.MediaIdentity

  require Logger

  @agent_gateway_component_types [:agent]
  @unspecified_route_profile :EDGE_RECORD_ROUTE_PROFILE_UNSPECIFIED
  @unspecified_traffic_class :EDGE_RECORD_TRAFFIC_CLASS_UNSPECIFIED
  @default_credit_bytes 64 * 1024 * 1024
  @default_credit_frames 64
  @default_drain_timeout_ms 10_000
  @max_uint32 4_294_967_295
  @max_uint64 0xFFFFFFFFFFFFFFFF
  # The agent refuses an ack carrying more dispositions than `edgerecord.DefaultMaxDispositions`, so
  # a watermark jump larger than that is acked as several contiguous runs.
  @max_dispositions_per_ack 4096
  @permanent :EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT
  # The session's pipeline and bound lane, for the cleanup in `stream/2`'s `after`, which cannot
  # see the state threaded through the receive loop.
  @session_key {__MODULE__, :pipeline_session}

  def stream(request_stream, stream) do
    owner = self()

    task =
      Task.Supervisor.async_nolink(task_supervisor(), fn ->
        stop_with_owner(owner)
        Enum.each(request_stream, &send(owner, {:edge_record_message, &1}))
      end)

    try do
      receive_stream(stream, task, :awaiting_lane_open)
    after
      Task.shutdown(task, :brutal_kill)
      close_session()
    end
  end

  # The reader is unlinked so a request-stream failure becomes a clean RPC error rather than
  # killing this process, which means it does not die with this process either. An exit signal
  # (a client disconnect tearing down the handler, a kill) skips the `after` above, and grpc's
  # Cowboy read waits for the handler's reply with no monitor and no timeout, so the reader would
  # stay blocked under the task supervisor forever -- lane state outliving the lane (task 3.6).
  # This watcher ends the reader when the owner goes, and exits on its own when the reader
  # finishes first.
  defp stop_with_owner(owner) do
    reader = self()

    spawn(fn ->
      owner_ref = Process.monitor(owner)
      reader_ref = Process.monitor(reader)

      receive do
        {:DOWN, ^owner_ref, :process, _pid, _reason} -> Process.exit(reader, :kill)
        {:DOWN, ^reader_ref, :process, _pid, _reason} -> :ok
      end
    end)
  end

  defp receive_stream(stream, task, state) do
    pipeline_monitor = pipeline_monitor(state)

    receive do
      {:edge_record_message, message} ->
        receive_stream(stream, task, handle_message(message, stream, state))

      {:edge_publish_outcome, lane, sequence, outcome, resolved_through} ->
        state = handle_outcome(stream, state, lane, sequence, outcome, resolved_through)
        receive_stream(stream, task, state)

      {ref, :ok} when ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        finish_stream(stream, state)

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        fail_reader(stream, reason, state)

      {:DOWN, ^pipeline_monitor, :process, _pid, reason} ->
        pipeline_lost!(reason)
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

    class =
      case PublisherLane.for_lane(route_profile, traffic_class) do
        {:ok, class} -> class
        {:error, _reason} -> raise GRPC.RPCError, status: :invalid_argument, message: "unroutable lane"
      end

    first_unresolved = required_first_unresolved(lane_open.first_unresolved_sequence)
    pipeline = pipeline_for!(class)
    pipeline_monitor = Process.monitor(pipeline)
    Process.put(@session_key, {pipeline, pipeline_monitor, nil})

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
      pipeline: pipeline,
      pipeline_monitor: pipeline_monitor,
      # {network_scope_id, agent, spool} once the first verified record binds it.
      lane: nil,
      # The watermark this session has acked. The agent validates every ack against it.
      acked_through: first_unresolved - 1,
      # Granted at lane_open. A frame above acked_through plus these is refused.
      frame_credits: frame_credits,
      # sequence => resolving kind, above acked_through and not yet covered by an ack.
      resolved: %{},
      # sequence => the decoded record's event id, above acked_through, for the ack that covers it.
      event_ids: %{},
      # sequence => how many outcomes are still owed for it by the pipeline.
      outstanding: %{}
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
    require_within_credit_window!(state, sequence)

    case decode_and_verify(frame) do
      {:ok, record} ->
        state
        |> bind_lane!(record.network_scope_id)
        |> admit_frame(stream, sequence, frame, record)

      {:error, :permanent, reason} ->
        Logger.warning("edge record permanently rejected: #{inspect(reason)}")
        reject_frame(stream, state, sequence)

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

  defp bind_lane!(%{lane: nil} = state, network_scope_id) do
    lane = {network_scope_id, state.identity.component_id, state.spool_id}

    # Opened at the first sequence this session has not acked, not at the agent's
    # first_unresolved_sequence: anything below it was rejected before the lane existed and is
    # already covered by an ack the agent holds.
    case pipeline_call(fn -> PublishPipeline.open_lane(state.pipeline, lane, state.acked_through + 1) end) do
      :ok ->
        :ok

      {:error, :lane_already_open} ->
        raise GRPC.RPCError, status: :already_exists, message: "edge record lane is already open on this gateway"

      {:error, :lane_limit} ->
        raise GRPC.RPCError, status: :resource_exhausted, message: "edge record lane limit reached"

      {:error, reason} ->
        raise GRPC.RPCError, status: :invalid_argument, message: "edge record lane not opened: #{inspect(reason)}"
    end

    Process.put(@session_key, {state.pipeline, state.pipeline_monitor, lane})

    # Rejections still waiting behind a gap were recorded before there was a lane to put them on.
    Enum.each(Map.keys(state.resolved), &reject_on_pipeline!(state.pipeline, lane, &1))

    %{state | lane: lane}
  end

  defp bind_lane!(%{lane: {network_scope_id, _agent, _spool}} = state, network_scope_id), do: state

  defp bind_lane!(_state, _network_scope_id) do
    raise GRPC.RPCError, status: :permission_denied, message: "delivery_frame network_scope_id does not match the lane"
  end

  # The session is the authority the registry compares the record against; nothing on the frame
  # is trusted to describe it. Only an admitted record is offered to the pipeline.
  defp admit_frame(state, stream, sequence, frame, record) do
    session = %{
      authenticated_agent_id: state.identity.component_id,
      route_profile: state.route_profile,
      traffic_class: state.traffic_class
    }

    case EdgeContractRegistry.admit(record, session, EdgeContractRegistry.impl().snapshot()) do
      {:ok, route} ->
        state
        |> remember_event_id(sequence, record.event_id)
        |> offer_frame(stream, sequence, frame, record, route)

      {:reject, reason} ->
        # Proven invalid for this session and snapshot: it resolves in the prefix exactly like an
        # integrity failure, but under the decoded record's event id.
        Logger.warning("edge record rejected by contract registry: #{inspect(reason)}")
        reject_frame(stream, remember_event_id(state, sequence, record.event_id), sequence)

      {:withhold, reason} ->
        # Not proof of poison: nothing is offered or recorded, so the sequence stays a gap that caps
        # the watermark, exactly like a retryable publish outcome.
        Logger.warning("edge record withheld by contract registry: #{inspect(reason)}")
        state

      {:hold, reason} ->
        # A security-revoked bundle is never published and never resolved, and is reported apart
        # from an ordinary withhold.
        Logger.error("edge record held for a security-revoked contract: #{inspect(reason)}")
        state
    end
  end

  defp offer_frame(state, stream, sequence, frame, record, route) do
    publication = %{
      slot: %{
        network_scope_id: record.network_scope_id,
        authenticated_agent_id: state.identity.component_id,
        spool_id: state.spool_id,
        sequence: sequence
      },
      # All three are pinned by the admitted contract's registry entry.
      route_profile: route.route_profile,
      traffic_class: route.traffic_class,
      partition_rule: route.partition_rule,
      record_bytes: frame.record_bytes,
      record_sha256: frame.record_sha256,
      semantic_envelope_sha256: record.semantic_envelope_sha256
    }

    offer(state, stream, sequence, publication)
  end

  defp offer(state, stream, sequence, publication) do
    case pipeline_call(fn -> PublishPipeline.offer(state.pipeline, publication) end) do
      :ok ->
        track(state, sequence)

      {:error, :queue_full} ->
        state
        |> await_own_outcome!(stream)
        |> offer(stream, sequence, publication)

      {:error, :lane_not_open} ->
        pipeline_lost!(:lane_not_open)

      {:error, reason} ->
        Logger.warning("edge record not offered for publication, ack withheld: #{inspect(reason)}")
        state
    end
  end

  defp await_own_outcome!(%{outstanding: outstanding}, _stream) when map_size(outstanding) == 0 do
    raise GRPC.RPCError, status: :resource_exhausted, message: "edge record publish queue is full"
  end

  defp await_own_outcome!(state, stream) do
    {:ok, state} = await_outcome(stream, state, :infinity)
    state
  end

  defp await_outcome(stream, state, timeout) do
    pipeline_monitor = state.pipeline_monitor

    receive do
      {:edge_publish_outcome, lane, sequence, outcome, resolved_through} ->
        {:ok, handle_outcome(stream, state, lane, sequence, outcome, resolved_through)}

      {:DOWN, ^pipeline_monitor, :process, _pid, reason} ->
        pipeline_lost!(reason)
    after
      timeout -> :timeout
    end
  end

  # Before a lane is bound there is nowhere to record the outcome but here, so it is acked by the
  # same contiguous rule the pipeline's watermark follows. A sequence the session already acked is
  # below that watermark, exactly as the pipeline would refuse it.
  defp reject_frame(stream, %{lane: nil} = state, sequence) do
    if sequence > state.acked_through do
      emit_acks(stream, remember(state, sequence, @permanent), @max_uint64)
    else
      state
    end
  end

  defp reject_frame(_stream, state, sequence) do
    reject_on_pipeline!(state.pipeline, state.lane, sequence)
    track(state, sequence)
  end

  defp reject_on_pipeline!(pipeline, lane, sequence) do
    case pipeline_call(fn -> PublishPipeline.reject_permanent(pipeline, lane, sequence) end) do
      :ok -> :ok
      {:error, reason} -> pipeline_lost!(reason)
    end
  end

  defp handle_outcome(stream, %{lane: lane} = state, lane, sequence, outcome, resolved_through) when lane != nil do
    state = untrack(state, sequence)

    state =
      case outcome do
        {:recorded, kind} ->
          if ResolvedPrefix.resolving?(kind) do
            remember(state, sequence, kind)
          else
            # RETRYABLE never resolves the sequence -- the watermark must not advance past a record
            # that may not be durable. No ack covers it; the agent's own deadline drives its retry.
            Logger.warning("edge record sequence #{sequence} did not resolve (#{kind}); ack withheld")
            state
          end

        {:refused, kind, reason} ->
          Logger.warning("edge record sequence #{sequence} outcome #{kind} refused by the lane: #{inspect(reason)}")
          state
      end

    emit_acks(stream, state, resolved_through)
  end

  # An outcome for a lane this stream does not hold, left over from an earlier session in this process.
  defp handle_outcome(_stream, state, _lane, _sequence, _outcome, _resolved_through), do: state

  defp remember(state, sequence, kind) do
    if sequence > state.acked_through do
      %{state | resolved: Map.put(state.resolved, sequence, kind)}
    else
      state
    end
  end

  defp remember_event_id(state, sequence, event_id) do
    if sequence > state.acked_through do
      %{state | event_ids: Map.put(state.event_ids, sequence, event_id)}
    else
      state
    end
  end

  defp track(state, sequence), do: %{state | outstanding: Map.update(state.outstanding, sequence, 1, &(&1 + 1))}

  defp untrack(state, sequence) do
    case Map.fetch(state.outstanding, sequence) do
      {:ok, 1} -> %{state | outstanding: Map.delete(state.outstanding, sequence)}
      {:ok, count} -> %{state | outstanding: Map.put(state.outstanding, sequence, count - 1)}
      :error -> state
    end
  end

  # Acks the contiguous run of remembered outcomes above what this session has acked, up to
  # `through` -- the pipeline's watermark, or unlimited before a lane is bound. It stops at the
  # first sequence whose kind this server has not seen rather than ack an outcome it cannot name.
  defp emit_acks(stream, state, through) do
    (state.acked_through + 1)
    |> Stream.iterate(&(&1 + 1))
    |> Enum.take_while(&(&1 <= through and Map.has_key?(state.resolved, &1)))
    |> Enum.chunk_every(@max_dispositions_per_ack)
    |> Enum.reduce(state, &send_ack(stream, &2, &1))
  end

  defp send_ack(stream, state, sequences) do
    resolved_through = List.last(sequences)

    :ok =
      send_reply(stream, %EdgeRecordServerMessage{
        payload:
          {:ack,
           %EdgeDeliveryAckV1{
             spool_id: state.spool_id,
             resolved_through_sequence: resolved_through,
             dispositions: Enum.map(sequences, &disposition(state, &1)),
             session_nonce: state.session_nonce
           }}
      })

    %{
      state
      | acked_through: resolved_through,
        resolved: Map.drop(state.resolved, sequences),
        event_ids: Map.drop(state.event_ids, sequences)
    }
  end

  # The agent binds each disposition to the event it sent for that sequence (`edgerecord.ValidateAck`)
  # and refuses one with no id unless it is a rejection. A frame rejected before its record was
  # trusted has no id remembered, so it goes out empty.
  defp disposition(state, sequence) do
    %EdgeRecordDisposition{
      sequence: sequence,
      event_id: Map.get(state.event_ids, sequence, ""),
      kind: Map.fetch!(state.resolved, sequence)
    }
  end

  defp finish_stream(_stream, :awaiting_lane_open) do
    raise GRPC.RPCError, status: :failed_precondition, message: "edge record stream ended before lane_open"
  end

  defp finish_stream(stream, state) do
    _state = drain(stream, state, System.monotonic_time(:millisecond) + drain_timeout_ms())
    :ok
  end

  defp drain(_stream, %{outstanding: outstanding} = state, _deadline) when map_size(outstanding) == 0, do: state

  defp drain(stream, state, deadline) do
    case await_outcome(stream, state, max(deadline - System.monotonic_time(:millisecond), 0)) do
      {:ok, state} ->
        drain(stream, state, deadline)

      :timeout ->
        Logger.warning(
          "edge record stream ended with #{map_size(state.outstanding)} sequence(s) unresolved; the agent retries them"
        )

        state
    end
  end

  defp fail_reader(stream, :normal, state), do: finish_stream(stream, state)

  defp fail_reader(_stream, reason, _state) do
    raise GRPC.RPCError, status: :unavailable, message: "edge record request stream failed: #{inspect(reason)}"
  end

  defp pipeline_monitor(%{pipeline_monitor: monitor}), do: monitor
  defp pipeline_monitor(_state), do: nil

  # Resolved to a PID once, at lane_open, so a replacement pipeline never receives this session's
  # offers: it holds none of this session's lane state. A dead one exits the call.
  defp pipeline_for!(class) do
    server =
      :serviceradar_agent_gateway
      |> Application.get_env(:edge_record_ingest_pipelines, %{})
      |> Map.get(class, PublishPipeline.via(class))

    case GenServer.whereis(server) do
      pid when is_pid(pid) -> pid
      _ -> raise GRPC.RPCError, status: :unavailable, message: "edge record publish pipeline is not running"
    end
  end

  defp pipeline_call(fun) do
    fun.()
  catch
    :exit, reason -> pipeline_lost!(reason)
  end

  defp pipeline_lost!(reason) do
    raise GRPC.RPCError,
      status: :unavailable,
      message: "edge record publish pipeline lost (#{inspect(reason)}); re-open the lane"
  end

  defp close_session do
    case Process.delete(@session_key) do
      {pipeline, monitor, lane} ->
        Process.demonitor(monitor, [:flush])
        close_lane(pipeline, lane)

      nil ->
        :ok
    end
  end

  defp close_lane(_pipeline, nil), do: :ok

  defp close_lane(pipeline, lane) do
    PublishPipeline.close_lane(pipeline, lane)
  catch
    :exit, _reason -> :ok
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

  defp require_within_credit_window!(state, sequence) do
    window_end = state.acked_through + state.frame_credits

    if sequence > window_end do
      raise GRPC.RPCError,
        status: :resource_exhausted,
        message: "delivery_frame sequence #{sequence} is beyond the frame credit window ending at #{window_end}"
    end
  end

  defp required_first_unresolved(sequence) when is_integer(sequence) and sequence >= 1 and sequence <= @max_uint64,
    do: sequence

  defp required_first_unresolved(_sequence) do
    raise GRPC.RPCError, status: :invalid_argument, message: "first_unresolved_sequence must be a positive integer"
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

  defp drain_timeout_ms do
    Application.get_env(:serviceradar_agent_gateway, :edge_record_ingest_drain_timeout_ms, @default_drain_timeout_ms)
  end

  defp task_supervisor do
    Application.get_env(
      :serviceradar_agent_gateway,
      :edge_record_ingest_task_supervisor,
      ServiceRadarAgentGateway.DeliveryTaskSupervisor
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
