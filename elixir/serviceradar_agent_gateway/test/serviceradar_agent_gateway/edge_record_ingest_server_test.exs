defmodule ServiceRadarAgentGateway.EdgeRecordIngestServerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.PublishPipeline
  alias Serviceradar.Edge.V1.EdgeDeliveryAckV1
  alias Serviceradar.Edge.V1.EdgeDeliveryFrameV1
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordClientMessage
  alias Serviceradar.Edge.V1.EdgeRecordDisposition
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpen
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpenAck
  alias Serviceradar.Edge.V1.EdgeRecordServerMessage
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadarAgentGateway.EdgeRecordIngestServer
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaAdapterStub
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaIdentityResolverStub
  alias ServiceRadarAgentGateway.TestSupport.EdgeContractRegistryStub
  alias ServiceRadarAgentGateway.TestSupport.EdgeRecordCapabilityStub
  alias ServiceRadarAgentGateway.TestSupport.EdgeRecordPublisherStub

  @spool_id :binary.copy(<<0xAB>>, 16)
  @session_nonce :binary.copy(<<0xCD>>, 8)
  @network_scope_id :binary.copy(<<0x40>>, 16)
  @other_network_scope_id :binary.copy(<<0x41>>, 16)
  @event_id :binary.copy(<<0x0E>>, 16)
  @accepted :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE
  @permanent :EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT
  @second_contract_id "serviceradar.test.second"

  setup do
    previous = %{
      pipelines: Application.get_env(:serviceradar_agent_gateway, :edge_record_ingest_pipelines),
      resolver: Application.get_env(:serviceradar_agent_gateway, :edge_record_ingest_identity_resolver),
      capability: Application.get_env(:serviceradar_agent_gateway, :edge_record_ingest_capability),
      supervisor: Application.get_env(:serviceradar_agent_gateway, :edge_record_ingest_task_supervisor),
      drain: Application.get_env(:serviceradar_agent_gateway, :edge_record_ingest_drain_timeout_ms),
      registry: Application.get_env(:serviceradar_agent_gateway, :edge_record_contract_registry_impl)
    }

    Application.put_env(:serviceradar_agent_gateway, :edge_record_contract_registry_impl, EdgeContractRegistryStub)

    _supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})

    Application.put_env(
      :serviceradar_agent_gateway,
      :edge_record_ingest_identity_resolver,
      CameraMediaIdentityResolverStub
    )

    Application.put_env(:serviceradar_agent_gateway, :edge_record_ingest_capability, EdgeRecordCapabilityStub)

    Application.put_env(
      :serviceradar_agent_gateway,
      :edge_record_ingest_task_supervisor,
      __MODULE__.TaskSupervisor
    )

    on_exit(fn ->
      restore_env(:edge_record_ingest_pipelines, previous.pipelines)
      restore_env(:edge_record_ingest_identity_resolver, previous.resolver)
      restore_env(:edge_record_ingest_capability, previous.capability)
      restore_env(:edge_record_ingest_task_supervisor, previous.supervisor)
      restore_env(:edge_record_ingest_drain_timeout_ms, previous.drain)
      restore_env(:edge_record_contract_registry_impl, previous.registry)
    end)

    %{pipeline: EdgeRecordPublisherStub.start_pipeline!(EdgeRecordPublisherStub.publisher(self()))}
  end

  test "opens a lane, publishes a verified frame through the pipeline, and acks it durable", %{pipeline: pipeline} do
    record = record()
    frame = frame(1, record)

    messages = [client({:lane_open, lane_open()}), client({:delivery_frame, frame})]

    assert :ok = EdgeRecordIngestServer.stream(messages, stream())

    assert_receive {:edge_record_stream_reply,
                    %EdgeRecordServerMessage{
                      payload:
                        {:lane_open_ack,
                         %EdgeRecordLaneOpenAck{
                           spool_id: @spool_id,
                           session_nonce: @session_nonce,
                           route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
                           traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK
                         }}
                    }}

    assert_receive {:edge_record_published, publication}
    assert publication.slot.authenticated_agent_id == "agent-1"
    assert publication.slot.network_scope_id == @network_scope_id
    assert publication.slot.spool_id == @spool_id
    assert publication.slot.sequence == 1
    assert publication.route_profile == :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1
    assert publication.traffic_class == :EDGE_RECORD_TRAFFIC_CLASS_BULK
    assert publication.partition_rule == :network_scope_v1
    assert publication.record_bytes == frame.record_bytes
    assert publication.record_sha256 == frame.record_sha256
    assert publication.semantic_envelope_sha256 == record.semantic_envelope_sha256

    assert_receive {:edge_record_stream_reply,
                    %EdgeRecordServerMessage{
                      payload:
                        {:ack,
                         %EdgeDeliveryAckV1{
                           spool_id: @spool_id,
                           resolved_through_sequence: 1,
                           session_nonce: @session_nonce,
                           dispositions: [
                             %EdgeRecordDisposition{sequence: 1, event_id: @event_id, kind: @accepted}
                           ]
                         }}
                    }}

    # The session's lane ends with the stream rather than holding one of the pipeline's lanes.
    assert %{lanes: 0, inflight: 0, queued: 0} = PublishPipeline.stats(pipeline)
  end

  test "replies through a real GRPC.Server.Stream, not only the test_pid shortcut" do
    messages = [client({:lane_open, lane_open()}), client({:delivery_frame, frame(1, record())})]

    assert :ok = EdgeRecordIngestServer.stream(messages, grpc_stream())

    assert_receive {:grpc_adapter_reply,
                    %EdgeRecordServerMessage{
                      payload: {:lane_open_ack, %EdgeRecordLaneOpenAck{spool_id: @spool_id}}
                    }}

    assert_receive {:grpc_adapter_reply,
                    %EdgeRecordServerMessage{
                      payload: {:ack, %EdgeDeliveryAckV1{resolved_through_sequence: 1}}
                    }}
  end

  test "refuses a lane_open when the client identity is not an agent" do
    Application.put_env(
      :serviceradar_agent_gateway,
      :edge_record_ingest_identity_resolver,
      __MODULE__.AddonIdentityResolverStub
    )

    error =
      assert_raise GRPC.RPCError, fn ->
        EdgeRecordIngestServer.stream([client({:lane_open, lane_open()})], stream())
      end

    assert error.status == GRPC.Status.permission_denied()
  end

  test "refuses a lane_open while the edge-records:v1 capability is not ready" do
    Process.put(:edge_record_capability_ready, false)

    error =
      assert_raise GRPC.RPCError, fn ->
        EdgeRecordIngestServer.stream([client({:lane_open, lane_open()})], stream())
      end

    assert error.status == GRPC.Status.unavailable()
  end

  test "refuses a lane_open whose class has no running publish pipeline, before acking it" do
    Application.put_env(:serviceradar_agent_gateway, :edge_record_ingest_pipelines, %{bulk: __MODULE__.NoPipeline})

    error =
      assert_raise GRPC.RPCError, fn ->
        EdgeRecordIngestServer.stream([client({:lane_open, lane_open()})], stream())
      end

    assert error.status == GRPC.Status.unavailable()
    refute_received {:edge_record_stream_reply, _}
  end

  test "refuses a lane_open without a positive first_unresolved_sequence" do
    error =
      assert_raise GRPC.RPCError, fn ->
        EdgeRecordIngestServer.stream(
          [client({:lane_open, %{lane_open() | first_unresolved_sequence: 0}})],
          stream()
        )
      end

    assert error.status == GRPC.Status.invalid_argument()
  end

  test "rejects a stream whose first message is a delivery_frame" do
    error =
      assert_raise GRPC.RPCError, fn ->
        EdgeRecordIngestServer.stream([client({:delivery_frame, frame(1, record())})], stream())
      end

    assert error.status == GRPC.Status.failed_precondition()
  end

  test "refuses a delivery_frame naming a spool_id other than the opened lane's" do
    other_frame = 1 |> frame(record()) |> Map.put(:spool_id, :binary.copy(<<0xEE>>, 16))

    error =
      assert_raise GRPC.RPCError, fn ->
        EdgeRecordIngestServer.stream(
          [client({:lane_open, lane_open()}), client({:delivery_frame, other_frame})],
          stream()
        )
      end

    assert error.status == GRPC.Status.permission_denied()
  end

  test "permanently rejects a frame whose record_sha256 does not match its bytes, without raising" do
    assert :ok =
             EdgeRecordIngestServer.stream(
               [client({:lane_open, lane_open()}), client({:delivery_frame, tampered(1)})],
               stream()
             )

    assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:lane_open_ack, _}}}

    assert_receive {:edge_record_stream_reply,
                    %EdgeRecordServerMessage{
                      payload:
                        {:ack,
                         %EdgeDeliveryAckV1{
                           resolved_through_sequence: 1,
                           dispositions: [%EdgeRecordDisposition{sequence: 1, kind: @permanent}]
                         }}
                    }}

    refute_received {:edge_record_published, _}
  end

  test "publishes with the route the registry entry pins, not a hardcoded rule" do
    # StreamRoute evaluates only one rule today, so a sentinel the stub publisher records is what
    # distinguishes "taken from the entry" from the old hardcoded :network_scope_v1.
    Process.put(
      :edge_contract_registry_snapshot,
      {:ok, EdgeContractRegistryStub.snapshot_with(:active, %{partition_rule: :registry_pinned_rule})}
    )

    assert :ok = run_one_frame(record())

    assert_receive {:edge_record_published, publication}
    assert publication.partition_rule == :registry_pinned_rule
  end

  test "withholds a contract the loaded snapshot does not contain: nothing published, nothing resolved" do
    assert_caps_later_sequences(record_for_contract("serviceradar.test.unknown"))
  end

  test "never acks past a withheld sequence, even for a later record that published durably" do
    stale = %{EdgeContractRegistryStub.contract_ref() | registry_epoch: 2}

    assert_caps_later_sequences(%{record() | output_contract: stale})
  end

  test "permanently rejects a record whose principal is not the authenticated agent, filling its place" do
    impostor = %{record() | producer_context: %EdgeProducerContext{origin_principal_id: "agent-2"}}

    assert :ok = EdgeRecordIngestServer.stream(open_and_records([impostor, record()]), stream())

    assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:lane_open_ack, _}}}
    # The rejection resolves sequence 1 in the prefix, under the decoded record's event id, so the
    # durable sequence behind it is acked rather than capped.
    assert Enum.map(acks_through(2), &{&1.sequence, &1.event_id, &1.kind}) ==
             [{1, @event_id, @permanent}, {2, @event_id, @accepted}]

    refute_received {:edge_record_published, %{slot: %{sequence: 1}}}
  end

  test "withholds a record on a candidate bundle: nothing published, nothing resolved" do
    Process.put(:edge_contract_registry_snapshot, snapshot_with_second_contract(:candidate))

    assert_caps_later_sequences(record_for_contract(@second_contract_id))
  end

  test "holds a record on a security-revoked bundle: nothing published, nothing resolved" do
    Process.put(:edge_contract_registry_snapshot, snapshot_with_second_contract(:security_revoked))

    assert_caps_later_sequences(record_for_contract(@second_contract_id))
  end

  test "withholds every record while no registry is loaded" do
    Process.put(:edge_contract_registry_snapshot, {:error, :registry_not_configured})

    assert :ok = run_one_frame(record())

    refute_received {:edge_record_published, _}
    refute_received {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}
  end

  test "withholds a retryable publish outcome instead of acking it durable" do
    EdgeRecordPublisherStub.start_pipeline!(EdgeRecordPublisherStub.publisher(self(), {:error, :capacity}))

    assert :ok = EdgeRecordIngestServer.stream(open_and_frames([1]), stream())

    assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:lane_open_ack, _}}}
    # NOT VACUOUS: the frame really was published, so the missing ack is a withheld outcome and not
    # a frame that never went out.
    assert_receive {:edge_record_published, %{slot: %{sequence: 1}}}
    refute_received {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}
  end

  describe "frames are offered to the pipeline, and acks follow its resolution" do
    test "a frame is published by a pipeline worker, and its ack waits for out-of-order PubAcks" do
      EdgeRecordPublisherStub.start_pipeline!(gated_publisher(self()))
      stream_pid = start_stream(open_and_frames([1, 2, 3]))

      assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:lane_open_ack, _}}}

      # All three are on the wire at once, each in a pipeline worker rather than in the stream
      # handler -- a synchronous server could only ever have had one of them outstanding.
      workers = started_any(3)
      assert workers |> Map.keys() |> Enum.sort() == [1, 2, 3]
      refute Enum.any?(Map.values(workers), &(&1 in [self(), stream_pid]))

      # 3 and 2 resolve first. Neither is contiguous from the watermark, so NOTHING is acked.
      release(workers[3], durable())
      release(workers[2], durable())
      refute_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}, 200

      # 1 closes the gap, and ONE ack covers all three in order.
      release(workers[1], durable())

      assert_receive {:edge_record_stream_reply,
                      %EdgeRecordServerMessage{
                        payload: {:ack, %EdgeDeliveryAckV1{resolved_through_sequence: 3, dispositions: dispositions}}
                      }},
                     5_000

      assert Enum.map(dispositions, &{&1.sequence, &1.kind}) == [{1, @accepted}, {2, @accepted}, {3, @accepted}]
      assert_receive {:stream_result, ^stream_pid, :ok}, 5_000
    end

    test "a retryable outcome caps the ack, so a later durable sequence is not acked past it" do
      # A per-frame ack would have reported sequence 2 with resolved_through 2 -- claiming 1 was
      # resolved when it may never have been published, and failing the agent's contiguity check.
      EdgeRecordPublisherStub.start_pipeline!(publisher_by_sequence(self(), %{1 => {:error, :timeout}, 2 => durable()}))

      assert :ok = EdgeRecordIngestServer.stream(open_and_frames([1, 2]), stream())

      assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:lane_open_ack, _}}}
      assert_receive {:edge_record_published, %{slot: %{sequence: 1}}}
      assert_receive {:edge_record_published, %{slot: %{sequence: 2}}}
      refute_received {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}
    end

    test "a permanent rejection after the lane is bound fills its place, so later sequences resolve" do
      messages = [
        client({:lane_open, lane_open()}),
        client({:delivery_frame, frame(1, record())}),
        client({:delivery_frame, tampered(2)}),
        client({:delivery_frame, frame(3, record())})
      ]

      assert :ok = EdgeRecordIngestServer.stream(messages, stream())

      assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:lane_open_ack, _}}}
      # Each disposition carries its own record's event id; the digest mismatch is rejected before
      # the record is trusted, so it names none, the one case the agent accepts without an id.
      assert Enum.map(acks_through(3), &{&1.sequence, &1.event_id, &1.kind}) ==
               [{1, @event_id, @accepted}, {2, "", @permanent}, {3, @event_id, @accepted}]

      refute_received {:edge_record_published, %{slot: %{sequence: 2}}}
    end

    test "a permanent rejection before the lane is bound is acked, and the lane resumes after it" do
      messages = [
        client({:lane_open, lane_open()}),
        client({:delivery_frame, tampered(1)}),
        client({:delivery_frame, frame(2, record())})
      ]

      assert :ok = EdgeRecordIngestServer.stream(messages, stream())

      assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:lane_open_ack, _}}}
      assert Enum.map(acks_through(2), &{&1.sequence, &1.kind}) == [{1, @permanent}, {2, @accepted}]
    end

    test "a rejection held behind a gap before the lane is bound is replayed into it" do
      # 2 is rejected while 1 has not arrived, so there is no lane yet and nothing contiguous to ack.
      # Unless 2 reaches the pipeline once 1 binds the lane, the prefix stops at 1 forever.
      messages = [
        client({:lane_open, lane_open()}),
        client({:delivery_frame, tampered(2)}),
        client({:delivery_frame, frame(1, record())})
      ]

      assert :ok = EdgeRecordIngestServer.stream(messages, stream())

      assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:lane_open_ack, _}}}
      assert Enum.map(acks_through(2), &{&1.sequence, &1.kind}) == [{1, @accepted}, {2, @permanent}]
    end

    test "a verified record for a different network scope ends the stream" do
      other_scope = frame(2, %{record() | network_scope_id: @other_network_scope_id})

      error =
        assert_raise GRPC.RPCError, fn ->
          EdgeRecordIngestServer.stream(
            [
              client({:lane_open, lane_open()}),
              client({:delivery_frame, frame(1, record())}),
              client({:delivery_frame, other_scope})
            ],
            stream()
          )
        end

      assert error.status == GRPC.Status.permission_denied()
      refute_received {:edge_record_published, %{slot: %{sequence: 2}}}
    end

    test "an offer refused :queue_full waits for the stream's own outcome, then is offered again and acked" do
      # One publish in flight and one queued fill the class, so sequence 3 is refused :queue_full.
      pipeline = EdgeRecordPublisherStub.start_pipeline!(gated_publisher(self()), max_inflight: 1, max_queue: 1)
      trace_offers(pipeline)
      stream_pid = start_stream(open_and_frames([1, 2, 3]))

      worker = started(1)
      assert_offered(pipeline, 3)
      assert %{inflight: 1, queued: 1} = PublishPipeline.stats(pipeline)

      # Nothing of its own has resolved, so the stream waits instead of offering 3 again in a loop.
      refute_receive {:trace, ^pipeline, :receive, {:"$gen_call", _from, {:offer, %{slot: %{sequence: 3}}}}}, 200

      # 1's outcome frees 1's place, and sequence 3 is offered again.
      release(worker, durable())
      assert_offered(pipeline, 3)

      release(started(2), durable())
      release(started(3), durable())

      assert Enum.map(acks_through(3), &{&1.sequence, &1.kind}) == [{1, @accepted}, {2, @accepted}, {3, @accepted}]
      assert_receive {:stream_result, ^stream_pid, :ok}, 5_000
    end

    test "a full queue with nothing of the stream's own outstanding ends it :resource_exhausted" do
      pipeline = EdgeRecordPublisherStub.start_pipeline!(gated_publisher(self()), max_inflight: 1, max_queue: 1)
      trace_offers(pipeline)

      # Another spool's stream fills the class: 1 in flight, 2 queued.
      busy = start_stream(open_and_frames([1, 2]))
      worker = started(1)
      assert_offered(pipeline, 2)

      other_spool = :binary.copy(<<0xAC>>, 16)

      error =
        assert_raise GRPC.RPCError, fn ->
          EdgeRecordIngestServer.stream(
            [
              client({:lane_open, %{lane_open() | spool_id: other_spool}}),
              client({:delivery_frame, %{frame(1, record()) | spool_id: other_spool}})
            ],
            stream()
          )
        end

      assert error.status == GRPC.Status.resource_exhausted()

      release(worker, durable())
      release(started(2), durable())
      assert_receive {:stream_result, ^busy, :ok}, 5_000
      refute_received {:started, 1, _worker}
    end

    test "losing the pipeline ends the stream :unavailable" do
      pipeline = EdgeRecordPublisherStub.start_pipeline!(gated_publisher(self()))
      stream_pid = start_stream(open_and_frames([1]))
      _worker = started(1)

      Process.exit(pipeline, :kill)

      assert_receive {:stream_result, ^stream_pid, {:raised, %GRPC.RPCError{} = error}}, 5_000
      assert error.status == GRPC.Status.unavailable()
      refute_received {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}
    end

    test "a half-closed stream waits for in-flight outcomes only until its drain deadline" do
      Application.put_env(:serviceradar_agent_gateway, :edge_record_ingest_drain_timeout_ms, 100)
      EdgeRecordPublisherStub.start_pipeline!(gated_publisher(self()))

      assert :ok = EdgeRecordIngestServer.stream(open_and_frames([1]), stream())

      # The frame WAS offered and is still on the wire; the stream stopped waiting for it.
      assert_receive {:started, 1, _worker}
      refute_received {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}
    end
  end

  describe "a frame must lie inside the granted frame credit window" do
    test "the window's last sequence is offered, and the one past it ends the stream before it is kept",
         %{pipeline: pipeline} do
      trace_offers(pipeline)

      # lane_open is granted 4 frames. Sequence 1 is rejected before a lane is bound, which acks it at
      # once and moves the window to 2..5.
      messages = [
        client({:lane_open, lane_open()}),
        client({:delivery_frame, tampered(1)}),
        client({:delivery_frame, frame(5, record())}),
        client({:delivery_frame, frame(6, record())})
      ]

      error = assert_raise GRPC.RPCError, fn -> EdgeRecordIngestServer.stream(messages, stream()) end
      assert error.status == GRPC.Status.resource_exhausted()

      assert_receive {:edge_record_stream_reply,
                      %EdgeRecordServerMessage{
                        payload: {:lane_open_ack, %EdgeRecordLaneOpenAck{granted_frame_credits: 4}}
                      }}

      assert Enum.map(acks_through(1), &{&1.sequence, &1.kind}) == [{1, @permanent}]
      assert_receive {:edge_record_published, %{slot: %{sequence: 5}}}, 5_000

      _stats = PublishPipeline.stats(pipeline)
      refute_received {:trace, ^pipeline, :receive, {:"$gen_call", _from, {:offer, %{slot: %{sequence: 6}}}}}
      refute_received {:edge_record_published, %{slot: %{sequence: 6}}}
    end

    test "digest-failing frames past the window are refused before the stream or the pipeline keeps them",
         %{pipeline: pipeline} do
      trace_offers(pipeline)
      beyond = Enum.map(5..64, &client({:delivery_frame, tampered(&1)}))

      # Before a lane is bound, and after sequence 2 binds it at 1. Sequence 1 never arrives, so nothing
      # is acked and a kept rejection would stay kept until the stream ended.
      unbound = [client({:lane_open, lane_open()})]
      bound = unbound ++ [client({:delivery_frame, frame(2, record())})]

      for opening <- [unbound, bound] do
        stream_pid = start_stream(opening ++ beyond)
        assert_receive {:stream_result, ^stream_pid, {:raised, %GRPC.RPCError{} = error}}, 5_000
        assert error.status == GRPC.Status.resource_exhausted()
      end

      _stats = PublishPipeline.stats(pipeline)
      refute_received {:trace, ^pipeline, :receive, {:"$gen_call", _from, {:reject_permanent, _lane, _sequence}}}
      refute_received {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}
    end
  end

  defmodule AddonIdentityResolverStub do
    @moduledoc false

    def resolve_from_cert(_cert_der) do
      {:ok, %{component_id: "addon-1", component_type: :addon, partition_id: "default"}}
    end
  end

  defp lane_open do
    %EdgeRecordLaneOpen{
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      spool_id: @spool_id,
      sequence_base: 1,
      first_unresolved_sequence: 1,
      session_nonce: @session_nonce,
      requested_byte_credits: 1024,
      requested_frame_credits: 4
    }
  end

  defp record do
    %EdgeRecordV1{
      event_id: @event_id,
      network_scope_id: @network_scope_id,
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      output_contract: EdgeContractRegistryStub.contract_ref(),
      producer_context: %EdgeProducerContext{origin_principal_id: "agent-1"},
      cost_model_version: 1,
      semantic_envelope_sha256: :binary.copy(<<0xAA>>, 32)
    }
  end

  defp run_one_frame(record) do
    result =
      EdgeRecordIngestServer.stream(
        [client({:lane_open, lane_open()}), client({:delivery_frame, frame(1, record)})],
        stream()
      )

    assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:lane_open_ack, _}}}
    result
  end

  # Sequence 1 is `unresolved`, sequence 2 a record the registry admits. The stream drains 2's
  # outcome before it returns, so any ack it was ever going to send has been sent by the refutations.
  defp assert_caps_later_sequences(unresolved) do
    assert :ok = EdgeRecordIngestServer.stream(open_and_records([unresolved, record()]), stream())

    assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:lane_open_ack, _}}}
    # NOT VACUOUS: 2 published durably, so the missing ack is 1's gap capping the watermark.
    assert_receive {:edge_record_published, %{slot: %{sequence: 2}}}
    refute_received {:edge_record_published, _}
    refute_received {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}
  end

  defp record_for_contract(contract_id) do
    %{record() | output_contract: %{EdgeContractRegistryStub.contract_ref() | contract_id: contract_id}}
  end

  # The stub's active contract plus a second one in `state`, so one stream carries both a record the
  # registry admits and one it does not.
  defp snapshot_with_second_contract(state) do
    active = EdgeContractRegistryStub.snapshot_with(:active)
    second = EdgeContractRegistryStub.snapshot_with(state, %{contract_id: @second_contract_id})

    {:ok, %{active | contracts: Map.merge(active.contracts, second.contracts)}}
  end

  defp frame(sequence, record) do
    bytes = EdgeRecordV1.encode(record)

    %EdgeDeliveryFrameV1{
      spool_id: @spool_id,
      sequence: sequence,
      record_sha256: :crypto.hash(:sha256, bytes),
      record_bytes: bytes
    }
  end

  defp tampered(sequence), do: sequence |> frame(record()) |> Map.put(:record_sha256, :binary.copy(<<0>>, 32))

  defp open_and_frames(sequences) do
    [client({:lane_open, lane_open()}) | Enum.map(sequences, &client({:delivery_frame, frame(&1, record())}))]
  end

  # Each record is delivered at its 1-based position.
  defp open_and_records(records) do
    frames = records |> Enum.with_index(1) |> Enum.map(fn {record, sequence} -> frame(sequence, record) end)
    [client({:lane_open, lane_open()}) | Enum.map(frames, &client({:delivery_frame, &1}))]
  end

  defp client(payload), do: %EdgeRecordClientMessage{payload: payload}

  defp durable, do: {:ok, %{stream: "TELEMETRY_EDGE_RECORD_V1_BULK", seq: 1, duplicate: false}}

  # Holds each publish until the test releases it, so PubAcks can be made to land in any order.
  defp gated_publisher(test) do
    fn publication, _opts ->
      send(test, {:started, publication.slot.sequence, self()})

      receive do
        {:release, result} -> result
      after
        15_000 -> {:error, :timeout}
      end
    end
  end

  defp publisher_by_sequence(test, results) do
    fn publication, _opts ->
      send(test, {:edge_record_published, publication})
      Map.fetch!(results, publication.slot.sequence)
    end
  end

  defp release(worker, result), do: send(worker, {:release, result})

  # Every message the pipeline receives is copied here, so an offer is observed as the call it is.
  defp trace_offers(pipeline), do: :erlang.trace(pipeline, true, [:receive])

  defp assert_offered(pipeline, sequence) do
    assert_receive {:trace, ^pipeline, :receive, {:"$gen_call", _from, {:offer, %{slot: %{sequence: ^sequence}}}}},
                   5_000

    # The pipeline answers calls in order, so this returns only after that offer was answered.
    _stats = PublishPipeline.stats(pipeline)
  end

  defp started(sequence) do
    receive do
      {:started, ^sequence, worker} -> worker
    after
      5_000 -> flunk("sequence #{sequence} was never published")
    end
  end

  defp started_any(n) do
    Enum.reduce(1..n, %{}, fn _, acc ->
      receive do
        {:started, sequence, worker} -> Map.put(acc, sequence, worker)
      after
        5_000 -> flunk("only #{map_size(acc)} of #{n} frames were published")
      end
    end)
  end

  # Runs a stream in its own process, as the gRPC adapter does, so this process can drive the
  # publisher while the stream waits on it.
  defp start_stream(messages) do
    test = self()

    spawn(fn ->
      result =
        try do
          EdgeRecordIngestServer.stream(messages, stream(test))
        rescue
          error -> {:raised, error}
        end

      send(test, {:stream_result, self(), result})
    end)
  end

  # Collects acks until the watermark reaches `through`, holding each to the rule the Go agent
  # applies in `edgerecord.ValidateAck`: a contiguous ascending run from the previous watermark plus
  # one, ending at resolved_through_sequence.
  defp acks_through(through, acked \\ 0, dispositions \\ [])
  defp acks_through(through, acked, dispositions) when acked >= through, do: dispositions

  defp acks_through(through, acked, dispositions) do
    assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, ack}}}, 5_000

    assert Enum.map(ack.dispositions, & &1.sequence) ==
             Enum.to_list((acked + 1)..ack.resolved_through_sequence//1)

    acks_through(through, ack.resolved_through_sequence, dispositions ++ ack.dispositions)
  end

  defp stream(test_pid \\ self()), do: %{adapter: CameraMediaAdapterStub, payload: :test, test_pid: test_pid}

  # A real stream carries no test_pid, so replies go through GRPC.Server.send_reply/2.
  defp grpc_stream do
    %GRPC.Server.Stream{
      server: EdgeRecordIngestServer,
      grpc_type: :bidirectional_stream,
      adapter: __MODULE__.ReplyingAdapterStub,
      payload: self()
    }
  end

  defmodule ReplyingAdapterStub do
    @moduledoc false

    # Stands in for the Cowboy adapter; the stream payload is the test pid.
    def get_cert(pid) when is_pid(pid), do: <<1, 2, 3>>

    def send_reply(pid, data, _opts) do
      send(pid, {:grpc_adapter_reply, EdgeRecordServerMessage.decode(IO.iodata_to_binary(data))})
      :ok
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)
end
