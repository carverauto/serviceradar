defmodule ServiceRadar.EventWriter.EdgeRecordOutcomeClassificationNatsTest do
  @moduledoc """
  End-to-end outcome classification, PipelineStats accounting, JetStream ACK/NAK/DLQ
  routing, and staged running-config artifact lifecycle across `EdgeRecord`,
  `WasmPluginResult`, non-plugin projectors, `EdgeRecordDeadLetter`, and `Replay`
  on a disposable real JetStream broker.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Broadway.Message
  alias ServiceRadar.Dgraph
  alias ServiceRadar.Edge.ContractCatalog
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.OutputGrant
  alias ServiceRadar.Edge.OutputGrants
  alias ServiceRadar.Edge.PipelineStats
  alias ServiceRadar.Edge.Projectors.BumblebeeScan
  alias ServiceRadar.Edge.Projectors.EndpointInventory
  alias ServiceRadar.Edge.Projectors.ScheduledMtrTrace
  alias ServiceRadar.Edge.Projectors.TelemetryBatch, as: TelemetryBatchProjector
  alias ServiceRadar.Edge.Projectors.UnleasedSweepResults
  alias ServiceRadar.Edge.Projectors.WorkloadIdentity, as: WorkloadIdentityProjector
  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.RecordValidate
  alias ServiceRadar.Edge.SemanticDigest
  alias Serviceradar.Edge.V1.BumblebeeScanPayloadV1
  alias Serviceradar.Edge.V1.EdgeOutputContractRef
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.EndpointInventoryScanPayloadV1
  alias Serviceradar.Edge.V1.PluginResultProvenanceV1
  alias Serviceradar.Edge.V1.UnleasedSweepHostResultV1
  alias Serviceradar.Edge.V1.UnleasedSweepResultsBatchV1
  alias Serviceradar.Edge.V1.WasmPluginResultBatchV1
  alias Serviceradar.Edge.V1.WasmPluginResultItemV1
  alias Serviceradar.Edge.V1.WorkloadIdentitySnapshotV1
  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.ConsumerReconciler
  alias ServiceRadar.EventWriter.EdgeRecordDeadLetter
  alias ServiceRadar.EventWriter.EdgeRecordDeadLetter.Replay
  alias ServiceRadar.EventWriter.EdgeRecordRefusedError
  alias ServiceRadar.EventWriter.EdgeRecordTransientError
  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.EventWriter.Processors.EdgeRecord
  alias ServiceRadar.EventWriter.Producer
  alias ServiceRadar.EventWriter.Telemetry, as: EventWriterTelemetry
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.NetworkConfig.PluginIngestor
  alias ServiceRadar.Observability.PluginResultHandler
  alias ServiceRadar.Observability.ServiceStatus
  alias ServiceRadar.SweepJobs.ExecutionSlots
  alias ServiceRadar.TestSupport.ExposureBroker

  @moduletag :db_free
  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  @plugin_results_contract "serviceradar.plugin_results.batch"
  @source_subject "telemetry.edge-record.v1.bulk.p07"
  @dlq_stream "TELEMETRY_EDGE_RECORD_DLQ_V1_BULK"

  defmodule FakeLedgerRepo do
    @moduledoc false

    def start_link do
      Elixir.Agent.start_link(fn -> %{slots: %{}, ledger: %{}, agents: %{}, partitions: %{}} end)
    end

    def bind_process(pid) do
      Process.put(:fake_ledger_repo_pid, pid)
    end

    def slot_count(pid), do: Elixir.Agent.get(pid, &map_size(&1.slots))
    def ledger_count(pid), do: Elixir.Agent.get(pid, &map_size(&1.ledger))

    def transaction(fun) do
      pid = repo_pid!()
      snapshot = Elixir.Agent.get(pid, & &1)

      try do
        {:ok, fun.()}
      rescue
        e ->
          Elixir.Agent.update(pid, fn _ -> snapshot end)
          reraise e, __STACKTRACE__
      catch
        {:fake_repo_rollback, reason} ->
          Elixir.Agent.update(pid, fn _ -> snapshot end)
          {:error, reason}
      end
    end

    def rollback(reason), do: throw({:fake_repo_rollback, reason})

    def get(Partition, id) do
      Elixir.Agent.get(repo_pid!(), &Map.get(&1.partitions, id))
    end

    def get(Agent, id) do
      Elixir.Agent.get(repo_pid!(), &Map.get(&1.agents, id))
    end

    def query!(sql, params) do
      pid = repo_pid!()

      cond do
        String.contains?(sql, "INSERT INTO platform.edge_delivery_slots") ->
          [scope, agent_id, spool_id, seq, record_sha, event_id, semantic_sha] = params
          key = {scope, agent_id, spool_id, seq}

          val = %{
            record_sha256: record_sha,
            event_id: event_id,
            semantic_envelope_sha256: semantic_sha
          }

          Elixir.Agent.get_and_update(pid, fn state ->
            case Map.get(state.slots, key) do
              nil -> {%{rows: [[true]]}, put_in(state.slots[key], val)}
              %{record_sha256: ^record_sha} -> {%{rows: [[false]]}, state}
              _other -> {%{rows: []}, state}
            end
          end)

        String.contains?(sql, "FROM platform.edge_delivery_slots") ->
          [scope, agent_id, spool_id, seq] = params

          case Elixir.Agent.get(pid, &Map.get(&1.slots, {scope, agent_id, spool_id, seq})) do
            nil -> %{rows: []}
            row -> %{rows: [[row.record_sha256, row.event_id, row.semantic_envelope_sha256]]}
          end

        String.contains?(sql, "INSERT INTO platform.event_ledger") ->
          [scope, event_id, semantic_sha, record_sha | _late_admission_audit] = params
          key = {scope, event_id}
          val = %{semantic_envelope_sha256: semantic_sha, record_sha256: record_sha}

          Elixir.Agent.get_and_update(pid, fn state ->
            case Map.get(state.ledger, key) do
              nil -> {%{rows: [[true]]}, put_in(state.ledger[key], val)}
              %{semantic_envelope_sha256: ^semantic_sha} -> {%{rows: [[false]]}, state}
              _other -> {%{rows: []}, state}
            end
          end)

        String.contains?(sql, "FROM platform.event_ledger") ->
          [scope, event_id] = params

          case Elixir.Agent.get(pid, &Map.get(&1.ledger, {scope, event_id})) do
            nil -> %{rows: []}
            row -> %{rows: [[row.semantic_envelope_sha256, row.record_sha256]]}
          end
      end
    end

    defp repo_pid! do
      Process.get(:fake_ledger_repo_pid) || raise "FakeLedgerRepo pid not bound to process"
    end
  end

  defmodule EdgeRecordSink do
    @moduledoc false
    use GenStage

    def start_link({producer, owner, repo_pid, batch_opts_fn}) do
      GenStage.start_link(__MODULE__, {producer, owner, repo_pid, batch_opts_fn})
    end

    @impl true
    def init({producer, owner, repo_pid, batch_opts_fn}) do
      FakeLedgerRepo.bind_process(repo_pid)

      {:consumer, {owner, batch_opts_fn},
       subscribe_to: [{producer, max_demand: 1, min_demand: 0}]}
    end

    @impl true
    def handle_events(events, _from, {owner, batch_opts_fn} = state) do
      Enum.each(events, fn event ->
        ack = event.metadata.jetstream_ack
        msg = Pipeline.transform(event, [])
        batch_opts = batch_opts_fn.()

        case EdgeRecord.process_batch([msg], batch_opts) do
          {:ok, _count} ->
            send(owner, {:processed, :ok, ack.stream_sequence, ack.delivery_count})
            Pipeline.ack(:ack_ref, [msg], [])

          {:incomplete, _count, [{failed_msg, reason}]} ->
            send(owner, {:processed, {:failed, reason}, ack.stream_sequence, ack.delivery_count})
            Pipeline.ack(:ack_ref, [], [Message.failed(failed_msg, reason)])
        end
      end)

      {:noreply, [], state}
    end
  end

  defmodule SettledHandler do
    @moduledoc false
    @behaviour PluginResultHandler

    @impl true
    def supports?(_payload, _status), do: true

    @impl true
    def settled_reasons, do: [:plugin_assignment_disabled]

    @impl true
    def refused_reasons, do: []

    @impl true
    def ingest(_payload, _status, _opts) do
      {:settled, :plugin_assignment_disabled,
       %{assignment_id: "00000000-0000-4000-8000-000000000501"}}
    end
  end

  defmodule RefusedHandler do
    @moduledoc false
    @behaviour PluginResultHandler

    @impl true
    def supports?(_payload, _status), do: true

    @impl true
    def settled_reasons, do: []

    @impl true
    def refused_reasons, do: [:plugin_assignment_agent_mismatch]

    @impl true
    def ingest(_payload, _status, _opts) do
      {:refused, :plugin_assignment_agent_mismatch,
       %{assignment_id: "00000000-0000-4000-8000-000000000502", agent_id: "edge-agent-01"}}
    end
  end

  defmodule DgraphWriteHandler do
    @moduledoc false
    # Writes through `ServiceRadar.Dgraph.Call`, as the hypervisor enrichment does, against a
    # native client stub whose single reply is `Process.get(:dgraph_reply)`: `{message, kind}`.
    @behaviour PluginResultHandler

    @impl true
    def supports?(_payload, _status), do: true

    @impl true
    def settled_reasons, do: []

    @impl true
    def refused_reasons, do: []

    @impl true
    def ingest(_payload, _status, _opts) do
      {message, kind} = Process.get(:dgraph_reply)

      submit = fn _deadline_ms ->
        ref = make_ref()
        send(self(), {:dgraph_nif_reply, ref, {:error, message}, {kind, 0, 0}})
        {:ok, ref, ref}
      end

      Dgraph.Call.run(:upsert_device, submit, deadline_ms: 1_000, cancel: fn _ -> :cancelled end)
    end
  end

  test "a Dgraph leader change is a transient failure that is redelivered, and a Dgraph refusal is not" do
    {:ok, repo_pid} = FakeLedgerRepo.start_link()
    FakeLedgerRepo.bind_process(repo_pid)
    frame = build_plugin_frame([plugin_item("synthetic-proxmox-check")])

    msg = %Message{
      data: frame.record_bytes,
      metadata: %{
        headers: frame.headers,
        subject: @source_subject,
        dead_letter_after: 20,
        max_deliver: -1,
        jetstream_ack: %{
          stream: "TELEMETRY_EDGE_RECORD_V1_BULK",
          delivery_count: 1,
          stream_sequence: 1
        }
      },
      acknowledger: {Broadway.NoopAcknowledger, nil, nil}
    }

    project = fn reply ->
      Process.put(:dgraph_reply, reply)

      with_log(fn ->
        EdgeRecord.process_batch([msg],
          repo: FakeLedgerRepo,
          projector_opts: plugin_projector_opts([DgraphWriteHandler])
        )
      end)
    end

    # Zero lost its leader mid-commit: the native client reports it as transient.
    {result, log} =
      project.(
        {"dgraph (transient): RPC Error: Unknown: Only leader can decide to commit or abort",
         :transient}
      )

    assert {:incomplete, 0, [{failed, %EdgeRecordTransientError{} = transient}]} = result
    refute EdgeRecordDeadLetter.due?(Message.failed(failed, transient))
    refute log =~ "[error]"
    assert FakeLedgerRepo.ledger_count(repo_pid) == 0

    # A schema refusal fails the same way on every delivery: it is not transient.
    {result, log} =
      project.(
        {"dgraph: RPC Error: Unknown: Schema not defined for predicate: device.example", :error}
      )

    assert {:incomplete, 0, [{_failed, %RuntimeError{} = refusal}]} = result
    assert Exception.message(refusal) =~ "Schema not defined"
    assert log =~ "[error]"
  end

  test "settled outcome commits slot and ledger, increments PipelineStats :settled (not :projected), and ACKs without DLQ",
       ctx do
    start_supervised!(PipelineStats)
    {:ok, repo_pid} = FakeLedgerRepo.start_link()

    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, port ->
      cfg = broker_config(port, 1_000_000_000)
      [source, dead_letter] = cfg.streams
      assert :ok = ConsumerReconciler.ensure_stream(conn, cfg, source)
      assert :ok = ConsumerReconciler.ensure_stream(conn, cfg, dead_letter)

      batch_opts_fn = fn ->
        [
          repo: FakeLedgerRepo,
          projector_opts: plugin_projector_opts([SettledHandler])
        ]
      end

      producer = start_supervised!({Producer, %{cfg | streams: [source]}})
      start_supervised!({EdgeRecordSink, {producer, self(), repo_pid, batch_opts_fn}})
      await_ready(:edge_outcome_producer)

      frame = build_plugin_frame([plugin_item("synthetic-proxmox-check")])
      publish_frame!(conn, frame)

      assert_receive {:processed, :ok, 1, 1}, 20_000
      await_settled(conn)

      assert FakeLedgerRepo.slot_count(repo_pid) == 1
      assert FakeLedgerRepo.ledger_count(repo_pid) == 1

      {:ok, %{contracts: contracts}} = PipelineStats.snapshot()
      counts = Enum.find(contracts, &(&1.contract == "serviceradar.plugin_results.batch/1"))
      assert counts.settled == 1
      assert counts.projected == 0
      assert counts.projector_refused == 0
      assert counts.failed == 0

      assert {:ok, %{entries: []}} = Replay.list()
    end)
  end

  test "refused outcome rolls back slot and ledger, dead-letters on delivery 1 with exact reason atom, and never uses RuntimeError",
       ctx do
    start_supervised!(PipelineStats)
    {:ok, repo_pid} = FakeLedgerRepo.start_link()

    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, port ->
      cfg = broker_config(port, 1_000_000_000)
      [source, dead_letter] = cfg.streams
      assert :ok = ConsumerReconciler.ensure_stream(conn, cfg, source)
      assert :ok = ConsumerReconciler.ensure_stream(conn, cfg, dead_letter)

      batch_opts_fn = fn ->
        [
          repo: FakeLedgerRepo,
          projector_opts: plugin_projector_opts([RefusedHandler])
        ]
      end

      producer = start_supervised!({Producer, %{cfg | streams: [source]}})
      start_supervised!({EdgeRecordSink, {producer, self(), repo_pid, batch_opts_fn}})
      await_ready(:edge_outcome_producer)

      frame = build_plugin_frame([plugin_item("synthetic-proxmox-check")])
      publish_frame!(conn, frame)

      assert_receive {:processed, {:failed, %EdgeRecordRefusedError{}}, 1, 1}, 20_000
      await_settled(conn)

      assert FakeLedgerRepo.slot_count(repo_pid) == 0
      assert FakeLedgerRepo.ledger_count(repo_pid) == 0

      {:ok, %{contracts: contracts}} = PipelineStats.snapshot()
      counts = Enum.find(contracts, &(&1.contract == "serviceradar.plugin_results.batch/1"))
      assert counts.projector_refused == 1
      assert counts.projected == 0
      assert counts.settled == 0

      assert {:ok, %{entries: [held]}} = Replay.list()
      assert held.failure["attempts"] == "1"
      assert held.failure["reason"] == "plugin_assignment_agent_mismatch"
      refute held.failure["reason"] in ["RuntimeError", "refused", "error"]
    end)
  end

  test "staged running-config artifact survives retryable and refused deliveries, replays from DLQ, and deletes only in committed/3",
       ctx do
    start_supervised!(PipelineStats)
    {:ok, repo_pid} = FakeLedgerRepo.start_link()

    assignment_id = "00000000-0000-4000-8000-000000000601"

    config_body =
      "hostname synthetic-router-01.example\ninterface Loopback0\n ip address 192.0.2.1 255.255.255.255\n"

    sha = :sha256 |> :crypto.hash(config_body) |> Base.encode16(case: :lower)

    object_key =
      "agent-artifacts/edge-agent-01/#{assignment_id}/opentext-nom/running-config/device-01"

    {:ok, store_pid} =
      Elixir.Agent.start_link(fn ->
        %{
          objects: %{object_key => config_body},
          mode: :transient_db,
          deleted_keys: [],
          ingested_configs: []
        }
      end)

    fetcher = fn key ->
      case Elixir.Agent.get(store_pid, &Map.get(&1.objects, key)) do
        nil -> {:error, :not_found}
        bytes -> {:ok, bytes}
      end
    end

    deleter = fn key ->
      Elixir.Agent.update(store_pid, fn state ->
        %{
          state
          | objects: Map.delete(state.objects, key),
            deleted_keys: [key | state.deleted_keys]
        }
      end)

      :ok
    end

    submitter = fn attrs, _opts ->
      case Elixir.Agent.get(store_pid, & &1.mode) do
        :transient_db ->
          {:error, %DBConnection.ConnectionError{message: "synthetic db timeout"}}

        :accept ->
          Elixir.Agent.update(store_pid, fn s ->
            %{s | ingested_configs: [{attrs.device_uid, attrs.body} | s.ingested_configs]}
          end)

          {:ok, :changed, %{}}
      end
    end

    # 1. Verify direct retryable failure preserves staged artifact
    FakeLedgerRepo.bind_process(repo_pid)

    handler_entry =
      {PluginIngestor, artifact_fetcher: fetcher, artifact_deleter: deleter, submitter: submitter}

    retry_frame = build_plugin_frame_with_details_json(assignment_id, object_key, sha)

    retry_msg = %Message{
      data: retry_frame.record_bytes,
      metadata: %{headers: retry_frame.headers, subject: @source_subject},
      acknowledger: {Broadway.NoopAcknowledger, nil, nil}
    }

    assert {:incomplete, 0, [{_failed, retry_err}]} =
             EdgeRecord.process_batch(
               [retry_msg],
               repo: FakeLedgerRepo,
               projector_opts:
                 plugin_projector_opts([handler_entry],
                   cleanup_artifacts_fn: fn payload_or_items, status ->
                     PluginIngestor.discard_artifacts(payload_or_items, status,
                       artifact_deleter: deleter
                     )
                   end
                 )
             )

    refute match?(%EdgeRecordRefusedError{}, retry_err)
    assert Elixir.Agent.get(store_pid, &Map.has_key?(&1.objects, object_key))
    assert Elixir.Agent.get(store_pid, & &1.deleted_keys) == []

    # 2. Now run full JetStream refusal -> DLQ -> operator fix -> Replay -> committed cleanup!
    Elixir.Agent.update(store_pid, &%{&1 | mode: :accept})

    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, port ->
      cfg = broker_config(port, 1_000_000_000)
      [source, dead_letter] = cfg.streams
      assert :ok = ConsumerReconciler.ensure_stream(conn, cfg, source)
      assert :ok = ConsumerReconciler.ensure_stream(conn, cfg, dead_letter)

      {:ok, gate_pid} = Elixir.Agent.start_link(fn -> :refuse_hash end)

      batch_opts_fn = fn ->
        current_gate = Elixir.Agent.get(gate_pid, & &1)

        fetcher_for_attempt =
          case current_gate do
            :refuse_hash -> fn _k -> {:ok, "corrupted-first-read-before-repair"} end
            :repaired -> fetcher
          end

        [
          repo: FakeLedgerRepo,
          projector_opts:
            plugin_projector_opts(
              [
                {PluginIngestor,
                 artifact_fetcher: fetcher_for_attempt,
                 artifact_deleter: deleter,
                 submitter: submitter}
              ],
              cleanup_artifacts_fn: fn payload_or_items, status ->
                PluginIngestor.discard_artifacts(payload_or_items, status,
                  artifact_deleter: deleter
                )
              end
            )
        ]
      end

      producer = start_supervised!({Producer, %{cfg | streams: [source]}})
      start_supervised!({EdgeRecordSink, {producer, self(), repo_pid, batch_opts_fn}})
      await_ready(:edge_outcome_producer)

      dlq_frame = build_plugin_frame_with_details_json(assignment_id, object_key, sha)
      publish_frame!(conn, dlq_frame)

      assert_receive {:processed, {:failed, %EdgeRecordRefusedError{}}, 1, 1}, 20_000
      await_settled(conn)

      # Staged artifact MUST still exist while held in DLQ!
      assert Elixir.Agent.get(store_pid, &Map.has_key?(&1.objects, object_key))
      assert {:ok, %{entries: [held]}} = Replay.list()
      assert held.failure["reason"] == "running_config_artifact_hash_mismatch"

      # Operator repairs condition and replays from DLQ (wait >1s for source duplicate window)
      Process.sleep(1_100)
      Elixir.Agent.update(gate_pid, fn _ -> :repaired end)

      assert {:ok, %{entries: [%{result: :replayed}]}} =
               Replay.replay(reason: "running_config_artifact_hash_mismatch")

      assert_receive {:processed, :ok, 2, 1}, 20_000
      await_settled(conn)

      assert Elixir.Agent.get(store_pid, &length(&1.ingested_configs)) == 1
      refute Elixir.Agent.get(store_pid, &Map.has_key?(&1.objects, object_key))
      assert Elixir.Agent.get(store_pid, & &1.deleted_keys) == [object_key]
    end)
  end

  test "WasmPluginResult lookup split, recovery-control retention, nested refusal unwrap, and non-plugin projector classifications" do
    {:ok, repo_pid} = FakeLedgerRepo.start_link()
    FakeLedgerRepo.bind_process(repo_pid)

    frame = build_plugin_frame([plugin_item("synthetic-check")])

    # 1. WasmPluginResult transient Partition lookup failure -> retryable (raises, NOT EdgeRecordRefusedError)
    msg = %Message{
      data: frame.record_bytes,
      metadata: %{
        headers: frame.headers,
        subject: @source_subject,
        dead_letter_after: 20,
        max_deliver: -1,
        jetstream_ack: %{
          stream: "TELEMETRY_EDGE_RECORD_V1_BULK",
          delivery_count: 1,
          stream_sequence: 1
        }
      },
      acknowledger: {Broadway.NoopAcknowledger, nil, nil}
    }

    assert {:incomplete, 0, [{failed_transient, transient_reason}]} =
             EdgeRecord.process_batch([msg],
               repo: FakeLedgerRepo,
               projector_opts: [
                 check_grant_fn: fn _, _, _, _, _ -> :ok end,
                 partition_lookup_fn: fn _id ->
                   {:error,
                    %DBConnection.ConnectionError{message: "synthetic partition lookup timeout"}}
                 end
               ]
             )

    refute match?(%EdgeRecordRefusedError{}, transient_reason)
    refute EdgeRecordDeadLetter.due?(Message.failed(failed_transient, transient_reason))

    # 2. WasmPluginResult Partition NotFound -> refused (:plugin_result_batch_partition_not_found)
    assert {:incomplete, 0, [{failed_not_found, %EdgeRecordRefusedError{} = not_found_refusal}]} =
             EdgeRecord.process_batch([msg],
               repo: FakeLedgerRepo,
               projector_opts: [
                 check_grant_fn: fn _, _, _, _, _ -> :ok end,
                 partition_lookup_fn: fn _id -> {:ok, nil} end
               ]
             )

    assert EventWriterTelemetry.failure_class(not_found_refusal) ==
             "plugin_result_batch_partition_not_found"

    assert EdgeRecordDeadLetter.due?(Message.failed(failed_not_found, not_found_refusal))

    # 3. WasmPluginResult transient Agent lookup failure -> retryable
    assert {:incomplete, 0, [{_failed_agent, agent_transient_reason}]} =
             EdgeRecord.process_batch([msg],
               repo: FakeLedgerRepo,
               projector_opts: [
                 check_grant_fn: fn _, _, _, _, _ -> :ok end,
                 partition_lookup_fn: fn _id -> {:ok, %Partition{slug: "partition-alpha"}} end,
                 agent_lookup_fn: fn _id ->
                   {:error,
                    %DBConnection.ConnectionError{message: "synthetic agent lookup timeout"}}
                 end
               ]
             )

    refute match?(%EdgeRecordRefusedError{}, agent_transient_reason)

    # 4. Recovery-control refusal retains broker delivery without dead-lettering
    recovery_msg = %Message{
      data: <<0xFF, 0x00>>,
      metadata: %{
        headers: %{},
        subject: "telemetry.edge-record-recovery.v1",
        dead_letter_after: 20,
        max_deliver: -1,
        jetstream_ack: %{
          stream: "TELEMETRY_EDGE_RECORD_RECOVERY_V1",
          delivery_count: 1,
          stream_sequence: 1
        }
      },
      acknowledger: {Broadway.NoopAcknowledger, nil, nil}
    }

    assert {:incomplete, 0, [{failed_rec, %EdgeRecordRefusedError{} = rec_refusal}]} =
             EdgeRecord.process_batch([recovery_msg], repo: FakeLedgerRepo)

    assert rec_refusal.reason == :missing_header
    refute EdgeRecordDeadLetter.applies?(failed_rec)
    refute EdgeRecordDeadLetter.applies?(Message.failed(failed_rec, rec_refusal))

    # 5. Nested refusal tuple unwraps to underlying reason atom ("gateway_unknown", never "refused")
    nested_err = EdgeRecordRefusedError.exception(reason: {:refused, :gateway_unknown})
    assert EventWriterTelemetry.failure_class(nested_err) == "gateway_unknown"

    struct_literal_err = %EdgeRecordRefusedError{reason: {:refused, :gateway_unknown}}
    assert EventWriterTelemetry.failure_class(struct_literal_err) == "gateway_unknown"

    # 6. UnleasedSweepResults {:declined, reason} split (Decision 4)
    assert :ok ==
             UnleasedSweepResults.classify_ingest_outcome(
               {:declined, :conflicting_execution_reporter}
             )

    assert :ok ==
             UnleasedSweepResults.classify_ingest_outcome(
               {:declined, :conflicting_execution_group}
             )

    assert {:refused, :missing_sweep_group_id} ==
             UnleasedSweepResults.classify_ingest_outcome({:declined, :missing_sweep_group_id})

    assert {:refused, :unresolved_execution_identity} ==
             UnleasedSweepResults.classify_ingest_outcome(
               {:declined, :unresolved_execution_identity}
             )

    assert {:refused, :no_hosts} ==
             UnleasedSweepResults.classify_ingest_outcome({:declined, :no_hosts})

    assert {:error, %EdgeRecordTransientError{reason: :unresolved_sweep_group}} =
             UnleasedSweepResults.classify_ingest_outcome({:declined, :unresolved_sweep_group})

    # 7. WorkloadIdentity, EndpointInventory, BumblebeeScan, TelemetryBatch deterministic refusals vs transient errors
    assert {:refused, :missing_workload_identity_message} =
             WorkloadIdentityProjector.classify_persist_result(
               {:error, :missing_workload_identity_message}
             )

    assert {:error, {:workload_identity_persist_failed, %DBConnection.ConnectionError{}}} =
             WorkloadIdentityProjector.classify_persist_result(
               {:error, %DBConnection.ConnectionError{message: "timeout"}}
             )

    assert {:refused, {:endpoint_inventory_missing_required_key, :agent_id}} =
             EndpointInventory.classify_ingest_result(
               {:error, {:missing_required_key, :agent_id}}
             )

    assert {:refused, {:bumblebee_missing_required_key, :agent_id}} =
             BumblebeeScan.classify_ingest_result({:error, {:missing_required_key, :agent_id}})

    assert {:refused, :telemetry_batch_partition_not_found} =
             TelemetryBatchProjector.classify_partition_lookup({:ok, nil})

    assert {:error, {:telemetry_batch_partition_lookup_failed, %DBConnection.ConnectionError{}}} =
             TelemetryBatchProjector.classify_partition_lookup(
               {:error, %DBConnection.ConnectionError{message: "timeout"}}
             )

    _ = ScheduledMtrTrace
    _ = WorkloadIdentitySnapshotV1
    _ = EndpointInventoryScanPayloadV1
    _ = BumblebeeScanPayloadV1
    _ = UnleasedSweepHostResultV1
    _ = UnleasedSweepResultsBatchV1
  end

  defp plugin_projector_opts(handlers, extra \\ []) do
    persistence = %{
      remap_service_name: fn status -> {:ok, status} end,
      insert_status: fn status_row, _actor ->
        {:ok, struct(ServiceStatus, status_row), :inserted}
      end,
      persist_applied: fn status_row, _payload, _outcomes, _actor ->
        {:ok, struct(ServiceStatus, status_row)}
      end,
      persist_settled: fn status_row, _payload, _outcomes, _actor ->
        {:ok, struct(ServiceStatus, status_row)}
      end,
      persist_failed: fn status_row, _payload, _errors, _handlers, _actor ->
        {:ok, struct(ServiceStatus, status_row)}
      end,
      publish_status: fn _status -> :ok end
    }

    Keyword.merge(
      [
        check_grant_fn: fn _, _, _, _, _ -> :ok end,
        partition_lookup_fn: fn _id -> {:ok, %Partition{slug: "partition-alpha"}} end,
        agent_lookup_fn: fn _id -> {:ok, %Agent{capabilities: ["proxmox_inventory"]}} end,
        ingestor_opts: [handlers: handlers, persistence: persistence]
      ],
      extra
    )
  end

  defp plugin_item(name) do
    %WasmPluginResultItemV1{
      schema_version: 1,
      status: :PLUGIN_RESULT_STATUS_OK,
      summary: "synthetic plugin result healthy",
      service_name: name,
      service_type: "plugin",
      observed_at_unix_nano:
        DateTime.utc_now() |> DateTime.shift(second: -30) |> DateTime.to_unix(:nanosecond)
    }
  end

  defp build_plugin_frame_with_details_json(assignment_id, object_key, sha) do
    details_json =
      Jason.encode!(%{
        "kind" => "running_config",
        "artifact" => %{
          "object_key" => object_key,
          "sha256" => sha
        }
      })

    item = %WasmPluginResultItemV1{
      schema_version: 1,
      status: :PLUGIN_RESULT_STATUS_OK,
      summary: "running config captured",
      service_name: "network-config",
      service_type: "plugin",
      labels: %{
        "kind" => "running_config",
        "assignment_id" => assignment_id,
        "device_uid" => "sr:00000000-0000-4000-8000-000000000602"
      },
      details: details_json,
      observed_at_unix_nano:
        DateTime.utc_now() |> DateTime.shift(second: -15) |> DateTime.to_unix(:nanosecond)
    }

    build_plugin_frame([item], assignment_id: assignment_id)
  end

  defp build_plugin_frame(items, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, "edge-agent-01")
    partition_id = Keyword.get(opts, :partition_id, "00000000-0000-4000-8000-000000000701")
    grant_id = Keyword.get(opts, :grant_id, "00000000-0000-4000-8000-000000000702")
    assignment_id = Keyword.get(opts, :assignment_id, "00000000-0000-4000-8000-000000000703")

    grant = %OutputGrant{
      id: grant_id,
      agent_id: agent_id,
      contract_id: @plugin_results_contract,
      network_scope_id: partition_id,
      authority_epoch: 1,
      state: :active
    }

    provenance = %PluginResultProvenanceV1{
      assignment_id: assignment_id,
      plugin_id: "synthetic-edge-check",
      plugin_package_id: "pkg-synthetic-1",
      plugin_version: "1.0.0",
      content_hash: String.duplicate("ab", 32)
    }

    batch = %WasmPluginResultBatchV1{provenance: provenance, results: items}
    payload = WasmPluginResultBatchV1.encode(batch)
    now = DateTime.utc_now()
    {:ok, catalog_entry} = ContractCatalog.fetch({@plugin_results_contract, 1})

    contract = %{
      contract_id: @plugin_results_contract,
      contract_version: 1,
      contract_bundle_sha256: :crypto.hash(:sha256, "plugin-results-bundle"),
      registry_epoch: 1,
      registry_snapshot_sha256: :crypto.hash(:sha256, "registry"),
      cost_model_version: catalog_entry.cost_model_version,
      max_projected_row_count: catalog_entry.max_projected_rows,
      max_projected_write_bytes:
        catalog_entry.max_projected_rows * catalog_entry.write_bytes_per_row
    }

    key = IssuerKey.from_seed(:binary.copy(<<0x5B>>, 32))
    production = OutputGrants.production_capability(grant, contract, key, now)
    {:production, claims} = production.claims

    record = %EdgeRecordV1{
      event_id: Ecto.UUID.dump!(ExecutionSlots.mint_id(now)),
      output_contract:
        struct(
          EdgeOutputContractRef,
          Map.take(claims, [
            :contract_id,
            :contract_version,
            :contract_bundle_sha256,
            :registry_epoch,
            :registry_snapshot_sha256,
            :effective_grant_sha256
          ])
        ),
      production_capability: production,
      payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
      compression: :EDGE_RECORD_COMPRESSION_NONE,
      encoded_size: byte_size(payload),
      uncompressed_size: byte_size(payload),
      payload_sha256: :crypto.hash(:sha256, payload),
      producer_context: %EdgeProducerContext{
        origin_kind: :EDGE_ORIGIN_KIND_AGENT,
        origin_principal_id: agent_id,
        producer_instance_id: agent_id,
        producer_assignment_id: claims.producer_assignment_id,
        authority_epoch: claims.authority_epoch,
        run_id: claims.run_id,
        run_shard: 0,
        scope_id: claims.scope_id,
        scope_sha256: claims.scope_sha256,
        package_id: claims.package_id,
        package_sha256: claims.package_sha256
      },
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      network_scope_id: Ecto.UUID.dump!(partition_id),
      projected_row_count: length(items),
      projected_write_bytes: length(items) * 16_384,
      cost_model_version: 1,
      payload: payload
    }

    record = %{record | semantic_envelope_sha256: SemanticDigest.compute(record)}
    record_bytes = EdgeRecordV1.encode(record)
    assert {:ok, _} = RecordValidate.validate_bytes(record_bytes)
    record_sha256 = :crypto.hash(:sha256, record_bytes)

    slot = %{
      network_scope_id: record.network_scope_id,
      authenticated_agent_id: agent_id,
      spool_id: random_uuid(7),
      sequence: System.unique_integer([:positive])
    }

    {:ok, nats_msg_id} =
      PublicationIdentity.nats_msg_id(slot, record.semantic_envelope_sha256, record_sha256)

    {:ok, delivery_id} = PublicationIdentity.delivery_id(slot)

    {:ok, provenance_hdr} =
      PublicationIdentity.transport_provenance(%{
        edge: slot,
        delivery_mode: PublicationIdentity.mode_fresh(),
        delivery_proof: nil,
        record_sha256: record_sha256,
        route_map_version: 1
      })

    headers = %{
      "Nats-Msg-Id" => nats_msg_id,
      "Sr-Edge-Delivery-Id" => delivery_id,
      "Sr-Edge-Transport-Provenance" => provenance_hdr
    }

    nats_headers = Enum.map(headers, fn {k, v} -> {k, v} end)
    %{record_bytes: record_bytes, headers: headers, nats_headers: nats_headers}
  end

  defp publish_frame!(conn, frame) do
    {:ok, %{body: body}} =
      Gnat.request(conn, @source_subject, frame.record_bytes,
        headers: frame.nats_headers,
        receive_timeout: 5_000
      )

    assert %{"stream" => "TELEMETRY_EDGE_RECORD_V1_BULK"} = Jason.decode!(body)
  end

  defp broker_config(port, source_duplicate_window) do
    %Config{
      enabled: true,
      producer_name: :edge_outcome_producer,
      nats: %{
        host: "127.0.0.1",
        port: port,
        tls: false,
        user: nil,
        password: nil,
        jwt: nil,
        nkey_seed: nil,
        creds_file: nil
      },
      consumer_name: "synthetic-outcome-writer",
      max_ack_pending: 8,
      consumer_pull_batch_size: 1,
      workers: 1,
      retired_consumers: [],
      streams: [
        Map.put(
          %{
            Config.edge_record_stream()
            | stream_replicas: 1,
              stream_max_bytes: 16_777_216,
              dead_letter_after_deliveries: 20
          },
          :stream_duplicate_window,
          source_duplicate_window
        ),
        %{
          Config.edge_record_dead_letter_stream()
          | stream_replicas: 1,
            stream_max_bytes: 16_777_216
        }
      ]
    }
  end

  defp await_ready(name, attempts \\ 200) do
    cond do
      Producer.status(name).ready ->
        :ok

      attempts == 0 ->
        flunk("producer not ready: #{inspect(Producer.status(name))}")

      true ->
        Process.sleep(50)
        await_ready(name, attempts - 1)
    end
  end

  defp await_settled(conn, attempts \\ 80) do
    durable = Config.durable_name("synthetic-outcome-writer", "EDGE_RECORD")
    info = api(conn, "CONSUMER.INFO.TELEMETRY_EDGE_RECORD_V1_BULK.#{durable}", "")

    cond do
      match?(%{"num_pending" => 0, "num_ack_pending" => 0}, info) ->
        :ok

      attempts == 0 ->
        flunk("source never settled: #{inspect(info)}")

      true ->
        Process.sleep(50)
        await_settled(conn, attempts - 1)
    end
  end

  defp api(conn, api_name, body) do
    {:ok, %{body: reply}} =
      Gnat.request(conn, "$JS.API." <> api_name, body, receive_timeout: 5_000)

    Jason.decode!(reply)
  end

  defp random_uuid(version) do
    <<b0::binary-6, v::8, b1::8, var::8, b2::binary-7>> = :crypto.strong_rand_bytes(16)
    new_v = Bitwise.bor(Bitwise.bsl(version, 4), Bitwise.band(v, 0x0F))
    new_var = Bitwise.bor(0x80, Bitwise.band(var, 0x3F))
    <<b0::binary, new_v::8, b1::8, new_var::8, b2::binary>>
  end
end
