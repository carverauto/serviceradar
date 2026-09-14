defmodule ServiceRadarAgentGateway.EdgeRecordIngestLaneIsolationTest do
  @moduledoc """
  Task 3.6 of `openspec/changes/unify-sweep-results-proto/tasks.md`: the edge record lane never
  enters `StatusBuffer`, never acknowledges an ERTS/Core NATS handoff as durable, and remains
  stateless across restarts.

  Each property is observed rather than inferred from the source. The lane runs in its own
  process and offers to a REAL `PublishPipeline`, whose workers publish through the REAL
  `JetStreamPublisher` and `PublisherPool`; only the NATS connection is a double, so every broker
  answer below goes through the production PubAck parsing and fencing. The buffer, ack and call
  detectors each have a control showing they fire when the property is broken.
  """

  use ExUnit.Case, async: false

  import Bitwise

  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublisherPool
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
  alias ServiceRadar.NATS.Connection
  alias ServiceRadarAgentGateway.Config
  alias ServiceRadarAgentGateway.EdgeRecordIngestServer
  alias ServiceRadarAgentGateway.JetStreamPublisher
  alias ServiceRadarAgentGateway.StatusBuffer
  alias ServiceRadarAgentGateway.StatusProcessor
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaAdapterStub
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaIdentityResolverStub
  alias ServiceRadarAgentGateway.TestSupport.EdgeContractRegistryStub
  alias ServiceRadarAgentGateway.TestSupport.EdgeRecordCapabilityStub

  @accepted :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE
  @buffer_events [
    [:serviceradar, :agent_gateway, :results, :buffer, :depth],
    [:serviceradar, :agent_gateway, :results, :buffer, :dropped]
  ]

  # Everything a lane could use to hand a record to Core instead of to a JetStream stream.
  @handoff_modules [:rpc, :erpc, Gnat, Connection, StatusProcessor, StatusBuffer]

  # Answers a real broker, or a non-authoritative hop in front of one, gives a publish request.
  # None of them is a PubAck from the stream the request named.
  @non_durable_replies [
    core_nats_responder_empty_body: {:ok, %{body: ""}},
    core_nats_protocol_ok: {:ok, %{body: "+OK"}},
    arbitrary_json_reply: {:ok, %{body: ~s({"ok":true})}},
    leaf_or_mirror_stream_ack: {:ok, %{body: ~s({"stream":"EDGE_LOCAL_MIRROR","seq":9})}},
    zero_sequence_ack: :expected_stream_zero_seq,
    stream_capacity_refusal: {:ok, %{body: ~s({"error":{"code":503,"description":"no responders available"}})}},
    no_responders: {:error, :no_responders},
    request_timeout: {:error, :timeout},
    connection_died: {:error, {:nats_connection_died, :closed}}
  ]

  defmodule FakeConn do
    @moduledoc false
    # Stands in for the NATS connection inside a pipeline's publish worker. Only `get/1` and
    # `request/4` exist: a fire-and-forget publish on this double would be an UndefinedFunctionError.

    def get(_name), do: {:ok, self()}

    def request(_conn, subject, payload, opts) do
      headers = Keyword.get(opts, :headers, [])
      send(Process.get(:isolation_test_pid), {:jetstream_request, self(), subject, payload, headers})

      case Process.get(:isolation_reply, :pub_ack) do
        :pub_ack ->
          seq = Process.get(:isolation_seq, 0) + 1
          Process.put(:isolation_seq, seq)
          {:ok, %{body: Jason.encode!(%{stream: expected_stream(headers), seq: seq})}}

        :expected_stream_zero_seq ->
          {:ok, %{body: Jason.encode!(%{stream: expected_stream(headers), seq: 0})}}

        reply ->
          reply
      end
    end

    defp expected_stream(headers), do: Enum.find_value(headers, fn {k, v} -> if k == "Nats-Expected-Stream", do: v end)
  end

  setup do
    keys = [
      :edge_record_ingest_pipelines,
      :edge_record_ingest_identity_resolver,
      :edge_record_ingest_capability,
      :edge_record_ingest_task_supervisor,
      :edge_record_contract_registry_impl
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:serviceradar_agent_gateway, &1)})

    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})

    put_env(:edge_record_ingest_identity_resolver, CameraMediaIdentityResolverStub)
    put_env(:edge_record_ingest_capability, EdgeRecordCapabilityStub)
    put_env(:edge_record_ingest_task_supervisor, __MODULE__.TaskSupervisor)
    put_env(:edge_record_contract_registry_impl, EdgeContractRegistryStub)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:serviceradar_agent_gateway, key)
        {key, value} -> Application.put_env(:serviceradar_agent_gateway, key, value)
      end)
    end)

    %{supervisor: supervisor, pipeline: start_pipeline(start_pools())}
  end

  describe "never enters StatusBuffer" do
    setup do
      # StatusBuffer reports its depth tagged with the gateway id, so it needs gateway config.
      previous_config =
        try do
          {:ok, Config.get()}
        rescue
          ArgumentError -> :missing
        end

      Config.setup(gateway_id: "gateway-test", domain: "test", capabilities: [])
      on_exit(fn -> restore_config(previous_config) end)

      buffer =
        case Process.whereis(StatusBuffer) do
          nil -> start_supervised!({StatusBuffer, flush_interval_ms: 3_600_000})
          pid -> pid
        end

      test_pid = self()
      handler_id = {__MODULE__, make_ref()}
      :ok = :telemetry.attach_many(handler_id, @buffer_events, &__MODULE__.forward_telemetry/4, test_pid)
      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{buffer: buffer}
    end

    test "no non-durable publish outcome reaches the buffer", %{buffer: buffer, pipeline: pipeline} do
      baseline = StatusBuffer.size()
      flush_telemetry()
      :erlang.trace(buffer, true, [:receive, {:tracer, self()}])

      for {{_name, reply}, index} <- Enum.with_index(@non_durable_replies, 1) do
        run_lane_to_end(single(index), pipeline: pipeline, reply: reply)
        assert_receive {:jetstream_request, _, _, _, _}
        refute_received {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}
      end

      # A pool with no frame credits left: refused before any I/O, the saturation case.
      exhausted = start_pipeline(start_pools(frame_credits: 1))
      run_lane_to_end(single(100), pipeline: exhausted, reply: {:error, :timeout})
      assert_received {:jetstream_request, _, _, _, _}
      run_lane_to_end(single(101), pipeline: exhausted, reply: :pub_ack)
      refute_received {:jetstream_request, _, _, _, _}
      refute_received {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}

      assert buffer_messages(buffer) == []
      refute_received {:buffer_telemetry, _, _, _}
      assert StatusBuffer.size() == baseline

      # Control: the same detectors see a status that does enter the buffer.
      :erlang.trace(buffer, true, [:receive, {:tracer, self()}])
      assert :ok = StatusBuffer.enqueue(%{source: "status", service_type: "status"})
      assert [{:"$gen_call", _from, {:enqueue, _status}}] = buffer_messages(buffer)
      assert_received {:buffer_telemetry, [:serviceradar, :agent_gateway, :results, :buffer, :depth], _, _}
    end
  end

  describe "never acknowledges an ERTS/Core NATS handoff as durable" do
    test "only a PubAck from the requested stream is acked, over request/reply", %{pipeline: pipeline} do
      for {{name, reply}, index} <- Enum.with_index(@non_durable_replies, 1) do
        run_lane_to_end(single(index), pipeline: pipeline, reply: reply)

        assert_receive {:jetstream_request, _, _subject, _payload, headers},
                       100,
                       "#{name}: the lane did not publish through a JetStream request"

        assert <<_, _::binary>> = header(headers, "Nats-Expected-Stream")
        refute_received {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}, "#{name}"
      end

      # Control: the authoritative PubAck on the same path is acked, so the refutations above are
      # not an artifact of a lane that never acks.
      run_lane_to_end(single(50), pipeline: pipeline, reply: :pub_ack)
      assert_receive {:jetstream_request, _, _, _, _}
      assert_received {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, ack}}}
      assert [%EdgeRecordDisposition{sequence: 50, kind: @accepted}] = ack.dispositions
    end

    test "neither the lane nor its publish workers make an ERTS RPC, Core NATS publish or StatusProcessor call",
         %{pipeline: pipeline} do
      calls =
        trace_handoff_calls(pipeline, fn ->
          lane = start_lane([lane_open(), delivery(1), delivery(2)], pipeline: pipeline, reply: :pub_ack)
          {lane, fn -> await_lane(lane) end}
        end)

      {publishes, handoffs} = Enum.split_with(calls, &match?({JetStreamPublisher, _, _}, &1))
      assert handoffs == []

      # Control: the trace reached the processes that actually publish, which are the pipeline's
      # workers rather than the lane, so the empty result above is not a trace that saw nothing.
      assert {JetStreamPublisher, :publish_record, :called} in publishes

      assert_received {:edge_record_stream_reply,
                       %EdgeRecordServerMessage{payload: {:ack, %{resolved_through_sequence: 2}}}}
    end
  end

  describe "stateless across restarts" do
    test "a killed lane leaves nothing behind and its replay re-derives every disposition",
         %{supervisor: supervisor, pipeline: pipeline} do
      # Warm-up, so lazily created VM state (logger, telemetry) exists before the snapshot.
      run_lane_to_end([lane_open(), delivery(1)], pipeline: pipeline, reply: :pub_ack)
      run_lane_to_end(single(99), pipeline: pipeline, reply: {:error, :timeout})
      flush_mailbox()
      before = global_state()

      # Session 1: resolve 1 and 2, then leave the request stream open the way a live client does,
      # with the reader blocked in a Cowboy-style read against the connection handler.
      handler = spawn(fn -> Process.sleep(:infinity) end)
      frames = [lane_open(nonce(1)), delivery(1), delivery(2)]
      lane = start_lane(Stream.concat(frames, cowboy_read_body(handler)), pipeline: pipeline, reply: :pub_ack)
      go(lane)

      first = collect_replies(3)
      first_requests = collect_requests(2)

      assert [{:lane_open_ack, _}, {:ack, %{resolved_through_sequence: 1}}, {:ack, %{resolved_through_sequence: 2}}] =
               first

      assert [_reader] = Task.Supervisor.children(supervisor)
      assert %{lanes: 1} = PublishPipeline.stats(pipeline.pid)

      # The restart: the client connection drops, taking the handler and the lane process with it.
      # An exit signal, so nothing in the lane gets to clean up after itself.
      Process.exit(handler, :kill)
      Process.exit(lane, :kill)

      assert_eventually(fn -> Task.Supervisor.children(supervisor) == [] end, "the lane's request reader outlived it")

      assert_eventually(
        fn -> PublishPipeline.stats(pipeline.pid).lanes == 0 end,
        "the lane's pipeline tracker outlived it"
      )

      assert global_state() == before
      refute_received {:edge_record_stream_reply, _}

      # Session 2, a reconnect with a new nonce replaying the same spool: every disposition comes
      # back through a fresh publish request, identical to the first, rather than from memory.
      run_lane_to_end([lane_open(nonce(2)), delivery(1), delivery(2)], pipeline: pipeline, reply: :pub_ack)

      second = collect_replies(3)
      assert collect_requests(2) == first_requests
      assert strip_nonce(second) == strip_nonce(first)
      assert Enum.all?(second, fn {_kind, message} -> message.session_nonce == nonce(2) end)

      # Session 3: the broker now refuses. A lane that remembered session 2's durable acks would
      # re-ack them; this one publishes again and withholds.
      run_lane_to_end([lane_open(nonce(3)), delivery(1), delivery(2)],
        pipeline: pipeline,
        reply: {:ok, %{body: ~s({"error":{"code":503,"description":"no responders available"}})}}
      )

      assert [{:lane_open_ack, _}] = collect_replies(1)
      assert length(collect_requests(2)) == 2
      refute_received {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}

      assert global_state() == before
    end
  end

  @doc false
  def forward_telemetry(event, measurements, metadata, test_pid) do
    send(test_pid, {:buffer_telemetry, event, measurements, metadata})
  end

  # --- lanes ---------------------------------------------------------------------------------

  # The bulk class pipeline, publishing through the real `JetStreamPublisher` into `pools`. Its
  # workers are not the lane process, so each takes the test pid and the broker's current answer
  # from here. One worker at a time, so a session's requests and acks arrive in sequence order and
  # compare exactly; concurrency is `ServiceRadar.Edge.PublishPipelineTest`'s subject.
  defp start_pipeline(pools) do
    test_pid = self()
    reply = start_supervised!({Agent, fn -> :pub_ack end}, id: make_ref())
    tasks = start_supervised!({Task.Supervisor, []}, id: make_ref())

    publisher = fn publication, opts ->
      Process.put(:isolation_test_pid, test_pid)
      Process.put(:isolation_reply, Agent.get(reply, & &1))
      JetStreamPublisher.publish_record(publication, Keyword.merge(opts, connection: FakeConn, receive_timeout: 1_000))
    end

    pid =
      start_supervised!(
        {PublishPipeline,
         class: :bulk,
         pool: Map.fetch!(pools, :bulk),
         publisher: publisher,
         task_supervisor: tasks,
         max_inflight: 1,
         name: nil},
        id: make_ref()
      )

    %{pid: pid, tasks: tasks, reply: reply}
  end

  defp start_lane(requests, opts) do
    test_pid = self()
    pipeline = Keyword.fetch!(opts, :pipeline)

    put_env(:edge_record_ingest_pipelines, %{bulk: pipeline.pid})
    :ok = Agent.update(pipeline.reply, fn _ -> Keyword.get(opts, :reply, :pub_ack) end)

    spawn(fn ->
      receive do
        :go -> :ok
      end

      result =
        try do
          {:ok,
           EdgeRecordIngestServer.stream(requests, %{adapter: CameraMediaAdapterStub, payload: :test, test_pid: test_pid})}
        rescue
          error -> {:raised, error}
        end

      send(test_pid, {:lane_finished, self(), result})
    end)
  end

  defp go(lane), do: send(lane, :go)

  defp await_lane(lane) do
    assert_receive {:lane_finished, ^lane, result}, 5_000
    result
  end

  defp run_lane_to_end(requests, opts) do
    lane = start_lane(requests, opts)
    go(lane)
    assert {:ok, :ok} = await_lane(lane)
  end

  # One frame on a lane opened at its own sequence, so a durable outcome for it WOULD be acked:
  # acks follow the contiguous prefix, and a refutation over a gap could not fail.
  defp single(sequence), do: [lane_open(nonce(1), sequence), delivery(sequence)]

  # grpc's Cowboy adapter reads the next request chunk by messaging the connection handler and
  # waiting for its answer, with no monitor and no timeout.
  defp cowboy_read_body(handler) do
    Stream.repeatedly(fn ->
      ref = make_ref()
      send(handler, {:read_body, ref, self()})

      receive do
        {^ref, message} -> message
      end
    end)
  end

  # Runs `start` with call tracing on the lane process, the pipeline and the task supervisor its
  # workers are spawned by, and returns every call they made into a module that could hand a
  # record to Core, or into `JetStreamPublisher`.
  defp trace_handoff_calls(pipeline, start) do
    modules = [JetStreamPublisher | @handoff_modules]

    Enum.each(modules, fn module ->
      Code.ensure_loaded!(module)
      :erlang.trace_pattern({module, :_, :_}, true, [:global])
    end)

    try do
      {lane, await} = start.()

      for pid <- [lane, pipeline.pid, pipeline.tasks] do
        :erlang.trace(pid, true, [:call, :set_on_spawn, {:tracer, self()}])
      end

      go(lane)
      await.()

      ref = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, :all, ^ref} -> :ok
      end

      drain_calls([])
    after
      Enum.each(modules, &:erlang.trace_pattern({&1, :_, :_}, false, [:global]))
      Enum.each([pipeline.pid, pipeline.tasks], &:erlang.trace(&1, false, [:call, :set_on_spawn]))
    end
  end

  defp drain_calls(acc) do
    receive do
      {:trace, _pid, :call, {module, function, _args}} -> drain_calls([{module, function, :called} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp buffer_messages(buffer) do
    :erlang.trace(buffer, false, [:receive])
    ref = :erlang.trace_delivered(buffer)

    receive do
      {:trace_delivered, ^buffer, ^ref} -> :ok
    end

    drain_buffer_messages(buffer, [])
  end

  defp drain_buffer_messages(buffer, acc) do
    receive do
      {:trace, ^buffer, :receive, :flush} -> drain_buffer_messages(buffer, acc)
      {:trace, ^buffer, :receive, message} -> drain_buffer_messages(buffer, [message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # --- state ---------------------------------------------------------------------------------

  # What a lane could leave behind for a later one: names, tables, persistent terms, and the
  # gateway's application environment.
  defp global_state do
    %{
      registered: MapSet.new(Process.registered()),
      ets: MapSet.new(:ets.all()),
      persistent_terms: :persistent_term.info().count,
      gateway_env: Enum.sort(Application.get_all_env(:serviceradar_agent_gateway))
    }
  end

  defp assert_eventually(fun, message, attempts \\ 50) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk(message)

      true ->
        Process.sleep(20)
        assert_eventually(fun, message, attempts - 1)
    end
  end

  defp collect_replies(count) do
    for _ <- 1..count do
      assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {kind, message}}}, 5_000
      {kind, message}
    end
  end

  defp collect_requests(count) do
    for _ <- 1..count do
      assert_receive {:jetstream_request, _worker, subject, payload, headers}, 5_000
      {subject, payload, headers}
    end
  end

  defp strip_nonce(replies) do
    Enum.map(replies, fn
      {:lane_open_ack, %EdgeRecordLaneOpenAck{} = ack} -> {:lane_open_ack, %{ack | session_nonce: nil}}
      {:ack, %EdgeDeliveryAckV1{} = ack} -> {:ack, %{ack | session_nonce: nil}}
    end)
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp flush_telemetry do
    receive do
      {:buffer_telemetry, _, _, _} -> flush_telemetry()
    after
      0 -> :ok
    end
  end

  defp start_pools(opts \\ []) do
    Map.new(PublisherLane.lanes(), fn lane ->
      {:ok, pool} =
        PublisherPool.start_link(
          class: lane,
          frame_credits: Keyword.get(opts, :frame_credits, 64),
          byte_credits: 64 * 1024 * 1024,
          name: nil
        )

      transport = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(transport, :kill) end)
      {:ok, _generation} = PublisherPool.register_transport(pool, transport)
      {lane, pool}
    end)
  end

  # --- wire fixtures -------------------------------------------------------------------------

  defp lane_open(session_nonce \\ nonce(1), first_unresolved_sequence \\ 1) do
    %EdgeRecordClientMessage{
      payload:
        {:lane_open,
         %EdgeRecordLaneOpen{
           route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
           traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
           spool_id: uuidv7(0x01),
           sequence_base: 1,
           first_unresolved_sequence: first_unresolved_sequence,
           session_nonce: session_nonce,
           requested_byte_credits: 1024 * 1024,
           requested_frame_credits: 16
         }}
    }
  end

  defp delivery(sequence) do
    bytes =
      EdgeRecordV1.encode(%EdgeRecordV1{
        network_scope_id: uuidv7(0x40),
        route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
        traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
        output_contract: EdgeContractRegistryStub.contract_ref(),
        producer_context: %EdgeProducerContext{origin_principal_id: "agent-1"},
        cost_model_version: 1,
        semantic_envelope_sha256: :crypto.hash(:sha256, "semantic-#{sequence}")
      })

    %EdgeRecordClientMessage{
      payload:
        {:delivery_frame,
         %EdgeDeliveryFrameV1{
           spool_id: uuidv7(0x01),
           sequence: sequence,
           record_sha256: :crypto.hash(:sha256, bytes),
           record_bytes: bytes
         }}
    }
  end

  defp nonce(n), do: :binary.copy(<<n>>, 8)

  defp uuidv7(seed) do
    bytes = Enum.map(0..15, &rem(seed + &1, 256))

    bytes
    |> List.replace_at(6, bor(band(Enum.at(bytes, 6), 0x0F), 0x70))
    |> List.replace_at(8, bor(band(Enum.at(bytes, 8), 0x3F), 0x80))
    |> :erlang.list_to_binary()
  end

  defp header(headers, name), do: Enum.find_value(headers, fn {k, v} -> if k == name, do: v end)

  defp put_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)

  defp restore_config({:ok, config}) do
    Config.setup(gateway_id: config.gateway_id, domain: config.domain, capabilities: config.capabilities)
  end

  defp restore_config(:missing), do: :persistent_term.erase(Config)
end
