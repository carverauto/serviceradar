defmodule ServiceRadar.EventWriter.Processors.EdgeRecordDbTest do
  @moduledoc """
  Real-Postgres coverage for the idempotent CNPG transaction (task 0.12 group
  C): a forced redelivery of the same stored frame must be a no-op replay
  (never a duplicate row), and a conflicting frame that reuses the same
  delivery slot with different bytes must fail with a distinct outcome while
  leaving the first binding immutable.

  Synthetic scheduled leases and wire-encoded records drive the EventWriter
  ingestion boundary against a real database, including sweep history,
  execution progress, discovery and availability. The composed transport path
  is owned by integration_tests/edge_record.
  """

  use ServiceRadar.DataCase, async: true

  import ExUnit.CaptureLog

  alias Broadway.Message
  alias ServiceRadar.Actors.SystemActor
  alias Serviceradar.Agent.Addon.V1.OtlpRelayFrame
  alias Serviceradar.Agent.Addon.V1.TelemetryBatch, as: AddonTelemetryBatch
  alias Serviceradar.Agent.Addon.V1.TelemetryCounters
  alias Serviceradar.Agent.Addon.V1.TelemetryRecord
  alias Serviceradar.Agent.Addon.V1.TelemetrySource
  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEvent
  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEventBatch
  alias ServiceRadar.Edge.ContractBundle
  alias ServiceRadar.Edge.ContractCatalog
  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.OutputContract
  alias ServiceRadar.Edge.OutputGrants
  alias ServiceRadar.Edge.ProjectionRows
  alias ServiceRadar.Edge.Projectors.UnleasedSweepResults
  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.RecordValidate
  alias ServiceRadar.Edge.SemanticDigest
  alias Serviceradar.Edge.V1.AgentScheduledMtrTraceBatchV1
  alias Serviceradar.Edge.V1.AgentScheduledMtrTraceV1
  alias Serviceradar.Edge.V1.EdgeOutputContractRef
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.MtrHopReplyDiagnosticsV1
  alias Serviceradar.Edge.V1.MtrMplsLabelV1
  alias Serviceradar.Edge.V1.MtrTcpHandshakeDiagnosticsV1
  alias Serviceradar.Edge.V1.MtrTraceEventV1
  alias Serviceradar.Edge.V1.MtrTraceHopV1
  alias Serviceradar.Edge.V1.PluginResultProvenanceV1
  alias Serviceradar.Edge.V1.SweepHostObservationV1
  alias Serviceradar.Edge.V1.SweepIcmpSummaryV1
  alias Serviceradar.Edge.V1.SweepObservationBatchV1
  alias Serviceradar.Edge.V1.SweepOpenPortV1
  alias Serviceradar.Edge.V1.SweepPortErrorV1
  alias Serviceradar.Edge.V1.SweepTcpSummaryV1
  alias Serviceradar.Edge.V1.SweepTestV1
  alias Serviceradar.Edge.V1.UnleasedSweepHostResultV1
  alias Serviceradar.Edge.V1.UnleasedSweepPortCountV1
  alias Serviceradar.Edge.V1.UnleasedSweepPortResultV1
  alias Serviceradar.Edge.V1.UnleasedSweepResultsBatchV1
  alias Serviceradar.Edge.V1.WasmPluginResultBatchV1
  alias Serviceradar.Edge.V1.WasmPluginResultItemV1
  alias ServiceRadar.EventWriter.EdgeRecordDeadLetter
  alias ServiceRadar.EventWriter.EdgeRecordDeadLetter.Replay
  alias ServiceRadar.EventWriter.Processors.EdgeRecord
  alias ServiceRadar.FlowAttribution
  alias ServiceRadar.FlowAttribution.Observations
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.Ingestion.ResultIngestor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Inventory.ProxmoxEnrichmentIngestor
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias ServiceRadar.NATS.PublishDeniedError
  alias ServiceRadar.Observability.MtrHop
  alias ServiceRadar.Observability.MtrMetricsIngestor
  alias ServiceRadar.Observability.MtrTrace
  alias ServiceRadar.Observability.PluginResultRepairAssignmentSupport
  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Repo
  alias ServiceRadar.StatusHandler
  alias ServiceRadar.SweepJobs.ExecutionSlots
  alias ServiceRadar.SweepJobs.LeaseCapabilities
  alias ServiceRadar.SweepJobs.ProducerAssignments
  alias ServiceRadar.SweepJobs.SweepExecutionSlot
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepGroupExecution
  alias ServiceRadar.SweepJobs.SweepHostResult
  alias ServiceRadar.SweepJobs.SweepProducerAssignment

  require Ecto.Query

  @metrics_contract "serviceradar.metrics.batch"
  @unleased_sweep_contract "serviceradar.sweep.unleased_results"
  @telemetry_contract "serviceradar.telemetry.batch"
  @scheduled_mtr_contract "serviceradar.mtr.scheduled_trace"
  @flow_attribution_contract "serviceradar.netprobe.flow_attribution"
  @otlp_relay_contract "serviceradar.otlp.relay"
  @plugin_results_contract "serviceradar.plugin_results.batch"

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  describe "ingest/3" do
    test "a fresh frame commits one ledger row, one delivery-slot binding, one sweep-batch-slot binding, and its projected rows" do
      %{record_bytes: record_bytes, headers: headers, record: record, batch: batch} =
        build_frame()

      assert {:ok, :inserted} = EdgeRecord.ingest(record_bytes, headers, Repo)

      assert ledger_row(record) == %{
               semantic_envelope_sha256: record.semantic_envelope_sha256,
               record_sha256: :crypto.hash(:sha256, record_bytes)
             }

      assert delivery_slot_count(record) == 1
      assert sweep_batch_slot_count(record, batch) == 1

      rows = projected_row_keys(record)
      expected_rows = ProjectionRows.sweep(batch)
      assert length(rows) == length(expected_rows)
      assert length(Enum.uniq(rows)) == length(rows)

      execution_id = Ecto.UUID.cast!(batch.execution_id)

      assert [%{ip: "192.0.2.1", status: :available, open_ports: [443], scanned_ports: [443]}] =
               Repo.all(
                 Ecto.Query.from(h in SweepHostResult, where: h.execution_id == ^execution_id)
               )

      assert %{status: :completed, hosts_total: 1, hosts_available: 1, hosts_failed: 0} =
               Repo.get!(SweepGroupExecution, execution_id)

      partition = Repo.get!(Partition, Ecto.UUID.cast!(record.network_scope_id)).slug

      device =
        Repo.one!(
          Ecto.Query.from(d in Device, where: d.partition == ^partition and d.ip == "192.0.2.1")
        )

      assert device.is_available
      assert "sweep" in device.discovery_sources

      assert %{is_available: true, open_ports: [443], execution_id: ^execution_id} =
               Repo.one!(
                 Ecto.Query.from(a in DeviceAgentAvailability, where: a.device_uid == ^device.uid)
               )
    end

    test "a batch that commits after the slot was marked missed reopens the slot" do
      %{record_bytes: record_bytes, headers: headers, batch: batch} = build_frame()
      execution_id = Ecto.UUID.cast!(batch.execution_id)
      set_slot_state!(execution_id, "missed_offline")

      assert {:ok, :inserted} = EdgeRecord.ingest(record_bytes, headers, Repo)
      assert Repo.get!(SweepExecutionSlot, execution_id).state == :scheduled
      assert Repo.get!(SweepGroupExecution, execution_id).status == :completed
    end

    # A dropped slot was withdrawn, and a refused slot is the agent's report that it did not
    # run it. Neither reopens the way a missed slot does.
    for state <- ["dropped", "refused"] do
      test "a batch for a #{state} slot is refused" do
        %{record_bytes: record_bytes, headers: headers, batch: batch} = build_frame()
        execution_id = Ecto.UUID.cast!(batch.execution_id)
        set_slot_state!(execution_id, unquote(state))

        assert {:error, :sweep_slot_mismatch} = EdgeRecord.ingest(record_bytes, headers, Repo)
        refute Repo.get(SweepGroupExecution, execution_id)

        assert Repo.get!(SweepExecutionSlot, execution_id).state ==
                 String.to_existing_atom(unquote(state))
      end
    end

    test "a late-fenced batch records its batch coordinate and does not project" do
      frame = build_frame(delivery_mode: PublicationIdentity.mode_late_fenced())
      execution_id = Ecto.UUID.cast!(frame.batch.execution_id)

      assert {:ok, :inserted} = EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)

      assert sweep_batch_slot_count(frame.record, frame.batch) == 1
      refute Repo.get(SweepGroupExecution, execution_id)
      assert Repo.get!(SweepExecutionSlot, execution_id).state == :scheduled
    end

    test "the audit route records a late-fenced batch and refuses one that is not late-fenced" do
      late = build_frame(delivery_mode: PublicationIdentity.mode_late_fenced())

      assert {:ok, :inserted} =
               EdgeRecord.ingest(late.record_bytes, late.headers, Repo, publication: :audit)

      assert ledger_count(late.record) == 1
      refute Repo.get(SweepGroupExecution, Ecto.UUID.cast!(late.batch.execution_id))

      fresh = build_frame()

      assert {:error, :audit_not_late_fenced} =
               EdgeRecord.ingest(fresh.record_bytes, fresh.headers, Repo, publication: :audit)

      assert ledger_count(fresh.record) == 0
      refute Repo.get(SweepGroupExecution, Ecto.UUID.cast!(fresh.batch.execution_id))
    end

    test "a ZSTD-compressed frame passes gateway admission and projects its decoded batch" do
      plain = build_frame()
      body = plain.record.payload
      frame_bytes = body |> :zstd.compress() |> IO.iodata_to_binary()

      compressed =
        encode_frame(
          %{
            plain.record
            | compression: :EDGE_RECORD_COMPRESSION_ZSTD,
              payload: frame_bytes,
              encoded_size: byte_size(frame_bytes),
              uncompressed_size: byte_size(body),
              payload_sha256: :crypto.hash(:sha256, frame_bytes)
          },
          plain.batch,
          plain.slot
        )

      assert {:ok, :inserted} =
               EdgeRecord.ingest(compressed.record_bytes, compressed.headers, Repo)

      assert sweep_batch_slot_count(compressed.record, compressed.batch) == 1

      execution_id = Ecto.UUID.cast!(compressed.batch.execution_id)

      assert [%{ip: "192.0.2.1", status: :available, open_ports: [443]}] =
               Repo.all(
                 Ecto.Query.from(h in SweepHostResult, where: h.execution_id == ^execution_id)
               )
    end

    test "forced redelivery of the exact same stored frame is an idempotent replay: no duplicate rows" do
      %{record_bytes: record_bytes, headers: headers, record: record, batch: batch} =
        build_frame()

      assert {:ok, :inserted} = EdgeRecord.ingest(record_bytes, headers, Repo)
      before_rows = projected_row_keys(record)

      # Force redelivery of the SAME stored bytes twice.
      assert {:ok, :replay} = EdgeRecord.ingest(record_bytes, headers, Repo)
      assert {:ok, :replay} = EdgeRecord.ingest(record_bytes, headers, Repo)

      assert delivery_slot_count(record) == 1
      assert ledger_count(record) == 1
      assert sweep_batch_slot_count(record, batch) == 1
      assert projected_row_keys(record) == before_rows

      assert %{hosts_total: 1, hosts_available: 1, hosts_failed: 0} =
               Repo.get!(SweepGroupExecution, Ecto.UUID.cast!(batch.execution_id))
    end

    test "microbatches finish only after all distinct planned hosts have results" do
      frame = build_frame(targets: ["192.0.2.0/30"])
      execution_id = Ecto.UUID.cast!(frame.batch.execution_id)

      assert {:ok, :inserted} = EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)

      assert %{status: :running, hosts_total: 4, hosts_available: 1} =
               Repo.get!(SweepGroupExecution, execution_id)

      repeated = next_frame(frame, %{frame.batch | batch_sequence: 2})
      assert {:ok, :inserted} = EdgeRecord.ingest(repeated.record_bytes, repeated.headers, Repo)

      assert %{status: :running, hosts_available: 1, hosts_failed: 0} =
               Repo.get!(SweepGroupExecution, execution_id)

      [host] = frame.batch.hosts

      unavailable = %{
        host
        | address: <<192, 0, 2, 2>>,
          icmp: %{
            host.icmp
            | outcome: :SWEEP_MODE_OUTCOME_TIMED_OUT,
              target_reached: false,
              received: 0
          },
          tcp: %{host.tcp | outcome: :SWEEP_MODE_OUTCOME_FAILURE, open_count: 0},
          open_ports: []
      }

      hosts = [
        %{host | address: <<192, 0, 2, 0>>},
        unavailable,
        %{host | address: <<192, 0, 2, 3>>}
      ]

      finished = next_frame(repeated, %{frame.batch | batch_sequence: 3, hosts: hosts})

      assert {:ok, :inserted} = EdgeRecord.ingest(finished.record_bytes, finished.headers, Repo)

      assert %{status: :completed, hosts_total: 4, hosts_available: 3, hosts_failed: 1} =
               Repo.get!(SweepGroupExecution, execution_id)

      assert %{status: :unavailable, open_ports: [], scanned_ports: [443]} =
               Repo.one!(
                 Ecto.Query.from(h in SweepHostResult,
                   where: h.execution_id == ^execution_id and h.ip == "192.0.2.2"
                 )
               )
    end

    test "source correlation and a changed assignment fence reject before domain writes" do
      frame = build_frame()
      mismatched = next_frame(frame, %{frame.batch | execution_id: random_uuid(7)})

      assert {:error, {:correlation, :context_id}} =
               EdgeRecord.ingest(mismatched.record_bytes, mismatched.headers, Repo)

      assert ledger_count(mismatched.record) == 0

      assignment_id = Ecto.UUID.cast!(frame.record.producer_context.producer_assignment_id)

      Repo.update_all(
        Ecto.Query.from(a in SweepProducerAssignment, where: a.id == ^assignment_id),
        inc: [authority_epoch: 1]
      )

      assert {:error, :sweep_assignment_fenced} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)

      assert ledger_count(frame.record) == 0
      assert Repo.get(SweepGroupExecution, Ecto.UUID.cast!(frame.batch.execution_id)) == nil
    end

    test "signed range authority rejects changed targets and checks despite valid envelope hashes" do
      frame = build_frame(targets: ["192.0.2.0/30"])
      [host] = frame.batch.hosts
      [icmp, tcp] = frame.batch.tested_checks

      for {batch, reason} <- [
            {%{frame.batch | hosts: [%{host | address: <<192, 0, 2, 4>>}]},
             :sweep_target_outside_range},
            {%{frame.batch | tested_checks: [icmp, %{tcp | port: 8443}]},
             :sweep_check_set_mismatch}
          ] do
        altered = next_frame(frame, batch)
        assert altered.record.production_capability == frame.record.production_capability
        assert altered.record.source_authorization == frame.record.source_authorization

        assert {:error, ^reason} = EdgeRecord.ingest(altered.record_bytes, altered.headers, Repo)
        assert ledger_count(altered.record) == 0
        assert delivery_slot_count(altered.record) == 0
        assert Repo.get(SweepGroupExecution, Ecto.UUID.cast!(batch.execution_id)) == nil
      end

      # The same persisted authority still admits its actual scheduled work.
      assert {:ok, :inserted} = EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)

      assert %{hosts_total: 4, hosts_available: 1} =
               Repo.get!(SweepGroupExecution, Ecto.UUID.cast!(frame.batch.execution_id))
    end

    test "an ingest failure fails only its own record, with nothing committed, and the redelivery projects once" do
      frame = build_frame()
      other = build_frame()
      execution_id = Ecto.UUID.cast!(frame.batch.execution_id)
      now = DateTime.utc_now()

      # The ingestor refuses an execution another reporter already owns. The
      # signed slot passed, so this stands in for any database-side ingest error.
      Repo.insert_all(SweepGroupExecution, [
        %{
          id: execution_id,
          sweep_group_id: Ecto.UUID.cast!(frame.batch.sweep_group_id),
          agent_id: "agent-other-#{System.unique_integer([:positive])}",
          status: :running,
          inserted_at: now,
          updated_at: now
        }
      ])

      message = %{data: frame.record_bytes, metadata: %{headers: frame.headers}}
      other_message = %{data: other.record_bytes, metadata: %{headers: other.headers}}

      # The record after the failing one is ingested and is not handed back for redelivery.
      assert {:incomplete, 1, [{^message, %RuntimeError{}}]} =
               EdgeRecord.process_batch([message, other_message])

      assert ledger_count(other.record) == 1
      assert ledger_count(frame.record) == 0
      assert delivery_slot_count(frame.record) == 0
      assert sweep_batch_slot_count(frame.record, frame.batch) == 0
      assert projected_row_keys(frame.record) == []

      assert Repo.all(
               Ecto.Query.from(a in DeviceAgentAvailability,
                 where: a.execution_id == ^execution_id
               )
             ) == []

      Repo.delete_all(Ecto.Query.from(e in SweepGroupExecution, where: e.id == ^execution_id))

      assert {:ok, 1} = EdgeRecord.process_batch([message])
      assert ledger_count(frame.record) == 1

      assert %{status: :completed, hosts_total: 1, hosts_available: 1, hosts_failed: 0} =
               Repo.get!(SweepGroupExecution, execution_id)

      assert {:ok, :replay} = EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)

      assert [%{ip: "192.0.2.1"}] =
               Repo.all(
                 Ecto.Query.from(h in SweepHostResult, where: h.execution_id == ^execution_id)
               )
    end

    test "a conflicting frame that reuses the same delivery slot with different bytes fails distinctly and leaves the first binding immutable" do
      %{record_bytes: record_bytes, headers: headers, record: record, slot: slot} =
        build_frame()

      assert {:ok, :inserted} = EdgeRecord.ingest(record_bytes, headers, Repo)
      original_binding = delivery_slot_row(record)

      # Same slot (network scope/agent/spool/sequence), different host content
      # -> different payload -> different semantic digest -> different
      # record_sha256, exactly the "differs only in record content" fixture
      # group C describes.
      %{record_bytes: conflicting_bytes, headers: conflicting_headers} =
        build_frame(slot: slot, host_octet: 42)

      assert {:error, {:delivery_slot_conflict, existing}} =
               EdgeRecord.ingest(conflicting_bytes, conflicting_headers, Repo)

      assert existing.record_sha256 == :crypto.hash(:sha256, record_bytes)
      assert delivery_slot_row(record) == original_binding
      assert delivery_slot_count(record) == 1
      assert ledger_count(record) == 1
    end

    test "a different event_id with a different digest bound to the same event_id fails as an event_id conflict" do
      %{record_bytes: record_bytes, headers: headers, record: record, slot: slot} = build_frame()

      assert {:ok, :inserted} = EdgeRecord.ingest(record_bytes, headers, Repo)

      # A distinct delivery slot (fresh spool/sequence) from the same agent
      # claiming the SAME event_id, but with different content -> different
      # semantic digest.
      %{record_bytes: reused_event_bytes, headers: reused_event_headers} =
        build_frame(
          network_scope_id: record.network_scope_id,
          agent_id: slot.authenticated_agent_id,
          event_id: record.event_id,
          host_octet: 7
        )

      assert {:error, {:event_id_conflict, existing}} =
               EdgeRecord.ingest(reused_event_bytes, reused_event_headers, Repo)

      assert existing.semantic_envelope_sha256 == record.semantic_envelope_sha256
      assert ledger_count(record) == 1
      # The rejected frame's own (fresh) delivery slot is rolled back along
      # with the rest of its transaction -- it never becomes an orphaned
      # binding for content that was never admitted.
      assert delivery_slot_count(record) == 1
    end
  end

  describe "ingest/4 test hook" do
    # The projection records the sweep group's execution and creates the device
    # for an unknown answering host with Ash actions. Their notifications reach
    # the notifiers once the ledger transaction commits, and never from an
    # attempt that rolled back.
    test "a :before_commit hook that raises rolls the whole transaction back, notifications included" do
      %{record_bytes: record_bytes, headers: headers, record: record, batch: batch} =
        build_frame()

      hook = fn
        :before_commit, _event_id, _result -> raise "injected rollback"
        _point, _event_id, _result -> :ok
      end

      test_pid = self()

      notified = fn
        _event, _measurements, %{resource: resource, action: action}, _config
        when self() == test_pid and resource in [SweepGroup, Device] ->
          send(test_pid, {:notified, resource, action, Repo.in_transaction?()})

        _event, _measurements, _metadata, _config ->
          :ok
      end

      with_telemetry([[:ash, :notifier, :stop]], notified, fn ->
        rollback_log =
          capture_log(fn ->
            assert_raise RuntimeError, "injected rollback", fn ->
              EdgeRecord.ingest(record_bytes, headers, Repo, test_hook: hook)
            end
          end)

        refute rollback_log =~ "Missed"
        refute_received {:notified, _resource, _action, _in_transaction?}

        assert ledger_count(record) == 0
        assert delivery_slot_count(record) == 0
        assert sweep_batch_slot_count(record, batch) == 0
        assert projected_row_keys(record) == []
        assert Repo.get(SweepGroupExecution, Ecto.UUID.cast!(batch.execution_id)) == nil

        # Nothing of the rolled-back attempt survives, so a redelivery commits.
        commit_log =
          capture_log(fn ->
            assert {:ok, :inserted} = EdgeRecord.ingest(record_bytes, headers, Repo)
          end)

        refute commit_log =~ "Missed"
        assert_received {:notified, SweepGroup, :record_execution, false}
        assert_received {:notified, Device, :create, false}
      end)

      assert ledger_count(record) == 1

      assert %{last_run_at: %DateTime{}} =
               Repo.get!(SweepGroup, Ecto.UUID.cast!(batch.sweep_group_id))
    end

    test "inside an enclosing Ash transaction, notifications wait for that transaction to commit" do
      %{record_bytes: record_bytes, headers: headers, record: record, batch: batch} =
        build_frame()

      test_pid = self()

      notified = fn
        _event, _measurements, %{resource: resource, action: action}, _config
        when self() == test_pid and resource in [SweepGroup, Device] ->
          send(test_pid, {:notified, resource, action, Repo.in_transaction?()})

        _event, _measurements, _metadata, _config ->
          :ok
      end

      with_telemetry([[:ash, :notifier, :stop]], notified, fn ->
        rollback_log =
          capture_log(fn ->
            # Ash.transact/3 rolls back on {:error, reason} and returns the reason wrapped
            # as an Ash error.
            assert {:error, %Ash.Error.Unknown.UnknownError{error: abort_reason}} =
                     Ash.transact([SweepGroup], fn ->
                       assert {:ok, :inserted} = EdgeRecord.ingest(record_bytes, headers, Repo)
                       refute_received {:notified, _resource, _action, _in_transaction?}
                       {:error, :outer_abort}
                     end)

            assert abort_reason =~ "outer_abort"
          end)

        refute rollback_log =~ "Missed"
        refute rollback_log =~ "dropped"
        refute_received {:notified, _resource, _action, _in_transaction?}
        assert ledger_count(record) == 0

        commit_log =
          capture_log(fn ->
            assert {:ok, _result} =
                     Ash.transact([SweepGroup], fn ->
                       assert {:ok, :inserted} = EdgeRecord.ingest(record_bytes, headers, Repo)
                       refute_received {:notified, _resource, _action, _in_transaction?}
                       {:ok, :committed}
                     end)
          end)

        refute commit_log =~ "Missed"
        refute commit_log =~ "dropped"
        assert_received {:notified, SweepGroup, :record_execution, false}
        assert_received {:notified, Device, :create, false}
      end)

      assert ledger_count(record) == 1
      assert sweep_batch_slot_count(record, batch) == 1
    end

    test "the :transaction_result hook observes the committed outcome and the delivery-slot conflict" do
      %{record_bytes: record_bytes, headers: headers, record: record, slot: slot} = build_frame()
      test_pid = self()

      hook = fn point, event_id, result ->
        send(test_pid, {:edge_record_hook, point, event_id, result})
      end

      assert {:ok, :inserted} = EdgeRecord.ingest(record_bytes, headers, Repo, test_hook: hook)

      event_id = record.event_id
      assert_received {:edge_record_hook, :before_commit, ^event_id, {:ok, :inserted}}
      assert_received {:edge_record_hook, :transaction_result, ^event_id, {:ok, :inserted}}

      %{record_bytes: conflicting_bytes, headers: conflicting_headers, record: conflicting} =
        build_frame(slot: slot, host_octet: 42)

      assert {:error, {:delivery_slot_conflict, _existing}} =
               EdgeRecord.ingest(conflicting_bytes, conflicting_headers, Repo, test_hook: hook)

      conflicting_event_id = conflicting.event_id
      first_sha256 = :crypto.hash(:sha256, record_bytes)

      assert_received {:edge_record_hook, :transaction_result, ^conflicting_event_id,
                       {:error, {:delivery_slot_conflict, %{record_sha256: ^first_sha256}}}}

      refute_received {:edge_record_hook, :before_commit, ^conflicting_event_id, _result}
    end
  end

  defp set_slot_state!(execution_id, state) do
    %{num_rows: 1} =
      Repo.query!(
        """
        UPDATE platform.sweep_execution_slots
        SET state = $2
        WHERE id = $1::uuid
        """,
        [Ecto.UUID.dump!(execution_id), state]
      )
  end

  describe "ingest/4 of metrics batch records" do
    for {source, family} <- [
          {"sysmon-metrics", "sysmon"},
          {"snmp-metrics", "snmp"},
          {"icmp-metrics", "icmp"},
          {"rperf-metrics", "rperf"},
          {"mtr-metrics", "mtr"},
          {"sweep-metrics", "sweep"}
        ] do
      test "a fresh #{source} record is published once to metrics.#{family} under the authenticated agent" do
        frame = with_source(build_metrics_frame(), unquote(source))

        assert {:ok, :inserted} =
                 EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

        assert_received {:metrics_published, subject, body, request_opts}
        assert subject == "metrics.#{unquote(family)}.cpu.cpu_usage_percent"
        assert {"Nats-Msg-Id", Ecto.UUID.load!(frame.record.event_id)} in request_opts[:headers]

        published = MetricBatch.decode(body)
        assert published.resource.agent_id == frame.agent_id
        assert published.ingest_identity.producer_id == frame.agent_id
        assert length(published.metrics) == 2
        assert ledger_count(frame.record) == 1
      end
    end

    test "a redelivered record is a replay and is not published again" do
      frame = build_metrics_frame()

      assert {:ok, :inserted} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      assert_received {:metrics_published, _subject, _body, _opts}

      assert {:ok, :replay} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      refute_received {:metrics_published, _subject, _body, _opts}
    end

    test "a record whose grant was revoked is refused and not published" do
      frame = build_metrics_frame()

      assert {:ok, 1} = OutputGrants.revoke_agent(frame.agent_id)

      assert {:error, :output_grant_not_current} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      refute_received {:metrics_published, _subject, _body, _opts}
      assert ledger_count(frame.record) == 0
    end

    test "a record naming a contract the catalog does not know is refused" do
      frame = build_metrics_frame()
      id = "serviceradar.example.uncataloged"
      {:production, claims} = frame.record.production_capability.claims

      production =
        IssuerKey.sign(
          %{
            frame.record.production_capability
            | claims: {:production, %{claims | contract_id: id}}
          },
          IssuerKey.from_seed(:binary.copy(<<0x5A>>, 32))
        )

      record = %{
        frame.record
        | output_contract: %{frame.record.output_contract | contract_id: id},
          production_capability: production
      }

      refused = encode_frame(record, frame.batch, frame.slot)

      assert {:error, :unsupported_payload_family} =
               EdgeRecord.ingest(refused.record_bytes, refused.headers, Repo,
                 request: stored_ack()
               )

      refute_received {:metrics_published, _subject, _body, _opts}
      assert ledger_count(refused.record) == 0
    end

    test "an unknown source is refused and not published" do
      refused = with_source(build_metrics_frame(), "plugin-metrics")

      assert {:error, :metrics_batch_source} =
               EdgeRecord.ingest(refused.record_bytes, refused.headers, Repo,
                 request: stored_ack()
               )

      refute_received {:metrics_published, _subject, _body, _opts}
      assert ledger_count(refused.record) == 0
    end

    test "a refused publish leaves no ledger row, so the redelivery publishes once" do
      frame = build_metrics_frame()
      refused = fn _subject, _body, _opts -> {:error, :timeout} end

      assert_raise RuntimeError, ~r/edge record publish failed/, fn ->
        EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: refused)
      end

      refute_received {:metrics_published, _subject, _body, _opts}
      assert ledger_count(frame.record) == 0

      assert {:ok, :inserted} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      assert_received {:metrics_published, _subject, _body, _opts}
      refute_received {:metrics_published, _subject, _body, _opts}
      assert ledger_count(frame.record) == 1
    end

    test "a republish the broker denied raises the denial, so the pipeline dead-letters it" do
      frame = build_metrics_frame()
      denied = fn subject, _body, _opts -> {:error, %PublishDeniedError{subject: subject}} end

      assert_raise PublishDeniedError, fn ->
        EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: denied)
      end

      assert ledger_count(frame.record) == 0
    end

    test "a dead-lettered record replays from its dead-letter copy once, through the ledger" do
      frame = build_metrics_frame()
      refused = fn _subject, _body, _opts -> {:error, :timeout} end

      error =
        assert_raise RuntimeError, fn ->
          EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: refused)
        end

      # The delivery as the broker hands it over: lower-cased header names.
      delivered =
        Message.failed(
          %Message{
            data: frame.record_bytes,
            metadata: %{
              subject: "telemetry.edge-record.v1.bulk.p07",
              headers: Enum.map(frame.headers, fn {k, v} -> {String.downcase(k), v} end),
              jetstream_ack: %{
                stream: "TELEMETRY_EDGE_RECORD_V1_BULK",
                stream_sequence: 7,
                delivery_count: 20
              }
            },
            acknowledger: {__MODULE__, :ack_ref, %{}}
          },
          error
        )

      letter = EdgeRecordDeadLetter.build(delivered, DateTime.utc_now())
      event_id = Ecto.UUID.load!(frame.record.event_id)

      assert letter.subject ==
               "telemetry.edge-record-dlq.v1.bulk.p07.serviceradar_metrics_batch.v1"

      failure = Map.new(letter.headers)
      assert failure["Sr-Edge-Dlq-Contract"] == "#{@metrics_contract}/1"
      assert failure["Sr-Edge-Dlq-Event-Id"] == event_id
      assert failure["Sr-Edge-Dlq-Agent-Id"] == frame.agent_id

      # The copy as the dead-letter stream returns it, then as replay republishes it.
      stored =
        Enum.map([{"Nats-Msg-Id", letter.msg_id} | letter.headers], fn {k, v} ->
          {String.downcase(k), v}
        end)

      assert {:ok, republished} = Replay.republication(%{data: letter.body, headers: stored})
      assert republished.subject == "telemetry.edge-record.v1.bulk.p07"
      replayed = [{"Nats-Msg-Id", republished.msg_id} | republished.headers]

      assert {:ok, :inserted} =
               EdgeRecord.ingest(republished.body, replayed, Repo, request: stored_ack())

      assert_received {:metrics_published, _subject, _body, _opts}

      assert {:ok, :replay} =
               EdgeRecord.ingest(republished.body, replayed, Repo, request: stored_ack())

      refute_received {:metrics_published, _subject, _body, _opts}
      assert ledger_count(frame.record) == 1
    end
  end

  describe "ingest/4 of telemetry batch records" do
    setup do
      original = Application.get_env(:serviceradar_core, StatusHandler, [])
      test = self()

      Application.put_env(:serviceradar_core, StatusHandler,
        addon_telemetry_publisher: fn subject, payload ->
          send(test, {:telemetry_routed, subject, payload})
          :ok
        end
      )

      on_exit(fn ->
        if original == [] do
          Application.delete_env(:serviceradar_core, StatusHandler)
        else
          Application.put_env(:serviceradar_core, StatusHandler, original)
        end
      end)

      :ok
    end

    test "a fresh plugin batch publishes its metrics attested to the assignment and routes its OCSF record" do
      frame =
        build_telemetry_frame([
          metrics_telemetry_record(),
          %TelemetryRecord{
            payload_kind: :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
            payload: ~s({"class_uid":4003,"message":"synthetic"})
          }
        ])

      assert {:ok, :inserted} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      assert_received {:metrics_published, subject, body, request_opts}
      assert subject == "metrics.timeseries.dns.dns_rpz_hits_total"
      assert {"Nats-Msg-Id", msg_id} = List.keyfind(request_opts[:headers], "Nats-Msg-Id", 0)
      assert is_binary(msg_id)

      published = MetricBatch.decode(body)
      assert published.resource.agent_id == frame.agent_id
      assert published.resource.gateway_id == ""
      assert published.resource.service_name == "plugin-telemetry"
      assert published.ingest_identity.source == "wasm-plugin"
      assert published.ingest_identity.producer_id == "assignment-telemetry-1"
      assert published.ingest_identity.producer_kind == "plugin"

      assert_received {:telemetry_routed, "events.ocsf.processed", routed}
      assert Jason.decode!(routed)["class_uid"] == 4003
      assert ledger_count(frame.record) == 1

      assert {:ok, :replay} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      refute_received {:metrics_published, _subject, _body, _opts}
      refute_received {:telemetry_routed, _subject, _payload}
    end

    test "an add-on OCSF record routes to the pdns subject" do
      frame =
        build_telemetry_frame(
          [
            %TelemetryRecord{
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
              payload: ~s({"class_uid":4003,"message":"synthetic"})
            }
          ],
          producer_type: "addon",
          producer_id: "powerdns"
        )

      assert {:ok, :inserted} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      assert_received {:telemetry_routed, "pdns.ocsf", _routed}
      refute_received {:metrics_published, _subject, _body, _opts}
    end

    test "a metric record with another schema is dropped, not published" do
      frame = build_telemetry_frame([metrics_telemetry_record("guest.metric.v9")])

      assert {:ok, :inserted} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      refute_received {:metrics_published, _subject, _body, _opts}
      assert ledger_count(frame.record) == 1
    end

    test "a record whose grant was revoked is refused and routes nothing" do
      frame = build_telemetry_frame([metrics_telemetry_record()])

      assert {:ok, 1} = OutputGrants.revoke_agent(frame.agent_id)

      assert {:error, :output_grant_not_current} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      refute_received {:metrics_published, _subject, _body, _opts}
      refute_received {:telemetry_routed, _subject, _payload}
      assert ledger_count(frame.record) == 0
    end

    test "a discovery record stamped as a plugin is refused at decode" do
      frame =
        build_telemetry_frame([
          %TelemetryRecord{
            payload_kind: :TELEMETRY_PAYLOAD_KIND_DISCOVERY_V1,
            payload: ~s({"devices":[]})
          }
        ])

      assert {:error, :telemetry_batch_discovery_producer} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      assert ledger_count(frame.record) == 0
    end

    test "a failed OCSF publish leaves no ledger row and the redelivery commits" do
      frame =
        build_telemetry_frame(
          [
            %TelemetryRecord{
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
              payload: ~s({"class_uid":4003,"message":"synthetic"})
            }
          ],
          counters: %TelemetryCounters{received: 1, emitted: 1}
        )

      handler = "telemetry-ocsf-spool-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:serviceradar, :plugin_metrics, :spool],
        fn _event, measurements, metadata, _config ->
          send(parent, {:plugin_metrics_spool, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Application.put_env(:serviceradar_core, StatusHandler,
        addon_telemetry_publisher: fn _subject, _payload -> {:error, :not_connected} end
      )

      assert_raise RuntimeError, ~r/telemetry_route_failed/, fn ->
        EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())
      end

      refute_received {:telemetry_routed, _subject, _payload}
      refute_received {:plugin_metrics_spool, _measurements, _metadata}
      assert ledger_count(frame.record) == 0

      test = self()

      Application.put_env(:serviceradar_core, StatusHandler,
        addon_telemetry_publisher: fn subject, payload ->
          send(test, {:telemetry_routed, subject, payload})
          :ok
        end
      )

      assert {:ok, :inserted} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      assert_received {:telemetry_routed, "events.ocsf.processed", _routed}
      assert_received {:plugin_metrics_spool, %{received: 1, emitted: 1}, _metadata}
      assert ledger_count(frame.record) == 1
    end

    test "a failed metric publish counts no spool sample and keeps its message id" do
      frame =
        build_telemetry_frame(
          [metrics_telemetry_record()],
          counters: %TelemetryCounters{received: 4, emitted: 4}
        )

      handler = "telemetry-metric-spool-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:serviceradar, :plugin_metrics, :spool],
        fn _event, measurements, metadata, _config ->
          send(parent, {:plugin_metrics_spool, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      failing = fn subject, body, request_opts ->
        send(parent, {:metrics_published, subject, body, request_opts})
        {:error, :not_connected}
      end

      assert_raise RuntimeError, ~r/telemetry_metrics_publish_failed/, fn ->
        EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: failing)
      end

      assert_received {:metrics_published, _subject, _body, failed_opts}
      refute_received {:plugin_metrics_spool, _measurements, _metadata}
      assert ledger_count(frame.record) == 0

      assert {:ok, :inserted} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      assert_received {:metrics_published, _subject, _body, recovered_opts}
      assert_received {:plugin_metrics_spool, %{received: 4, emitted: 4}, _metadata}
      assert ledger_count(frame.record) == 1

      assert {"Nats-Msg-Id", msg_id} = List.keyfind(failed_opts[:headers], "Nats-Msg-Id", 0)
      assert {"Nats-Msg-Id", ^msg_id} = List.keyfind(recovered_opts[:headers], "Nats-Msg-Id", 0)
    end

    test "a batch without a host producer stamp is refused at decode" do
      frame = build_telemetry_frame([metrics_telemetry_record()], stamp: false)

      assert {:error, :telemetry_batch_producer} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      assert ledger_count(frame.record) == 0
    end
  end

  describe "ingest/4 of plugin result batch records" do
    test "a fresh batch ingests under its assignment identity and a replay adds no row" do
      suffix = System.unique_integer([:positive])
      name = "synthetic-edge-check-#{suffix}"
      {agent_id, partition} = plugin_result_agent!()

      status = %{agent_id: agent_id, service_name: name, partition: "default"}
      package = PluginResultRepairAssignmentSupport.create_repair_package!(name)

      assignment =
        PluginResultRepairAssignmentSupport.create_repair_assignment_for_package!(status, package)

      frame =
        build_plugin_result_frame([plugin_result_item(name)],
          agent_id: agent_id,
          partition: partition,
          assignment_id: to_string(assignment.id),
          plugin_id: package.plugin_id
        )

      assert {:ok, :inserted} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      assert ledger_count(frame.record) == 1
      assert [^name] = plugin_service_names(frame.agent_id)
      assert plugin_service_row_count(frame.agent_id) == 1

      assert {:ok, :replay} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      assert ledger_count(frame.record) == 1
      assert [^name] = plugin_service_names(frame.agent_id)
      assert plugin_service_row_count(frame.agent_id) == 1
    end

    test "a coexisting assignment ingests under its disambiguated service identity" do
      suffix = System.unique_integer([:positive])
      name = "synthetic-shared-check-#{suffix}"
      {agent_id, partition} = plugin_result_agent!()

      status = %{agent_id: agent_id, service_name: name, partition: "default"}
      package = PluginResultRepairAssignmentSupport.create_repair_package!(name)
      secondary_package = package

      primary =
        PluginResultRepairAssignmentSupport.create_repair_assignment_for_package!(
          status,
          package,
          source: :policy,
          source_key: "coexist-primary-#{suffix}",
          policy_id: "network-credential-rule:rule-primary-#{suffix}:inventory"
        )

      # The sandbox runs both creates in one transaction, so their
      # inserted_at stamps are identical; the primary was enabled first.
      Repo.query!(
        "UPDATE platform.plugin_assignments SET inserted_at = inserted_at - interval '1 hour' WHERE id = $1",
        [Ecto.UUID.dump!(to_string(primary.id))]
      )

      # Two enabled assignments of one package coexist only under different
      # credential-rule owners.
      secondary =
        PluginResultRepairAssignmentSupport.create_repair_assignment_for_package!(
          status,
          secondary_package,
          source: :policy,
          source_key: "coexist-secondary-#{suffix}",
          policy_id: "network-credential-rule:rule-secondary-#{suffix}:inventory"
        )

      frame =
        build_plugin_result_frame([plugin_result_item(name)],
          agent_id: agent_id,
          partition: partition,
          assignment_id: to_string(secondary.id),
          plugin_id: secondary_package.plugin_id
        )

      assert {:ok, "#{name}##{secondary.id}"} ==
               ServiceRadar.Observability.ServiceStateRegistry.PluginServiceIdentity.service_name_for_assignment(
                 agent_id,
                 to_string(secondary.id)
               )

      assert {:ok, :inserted} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      expected = "#{name}##{secondary.id}"
      assert [^expected] = plugin_service_names(frame.agent_id)
    end

    test "a record whose grant was revoked is refused and ingests nothing" do
      frame = build_plugin_result_frame([plugin_result_item("synthetic-revoked-check")])

      assert {:ok, 1} = OutputGrants.revoke_agent(frame.agent_id)

      assert {:error, :output_grant_not_current} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      assert ledger_count(frame.record) == 0
      assert [] = plugin_service_names(frame.agent_id)
    end

    # The Proxmox source-scope resolver gates on the delivering agent's
    # authenticated capabilities, which the edge path takes from the agent's
    # stored record. With them the resolver moves on to the assignment lookup
    # (absent here); without them it refuses at the capability gate.
    test "a Proxmox result is gated on the authenticated agent's stored capabilities" do
      proxmox_capabilities = [
        "plugin-host-authority:v1",
        "proxmox-semantic-connector:v1",
        "proxmox-identity:v3"
      ]

      for {capabilities, expected} <- [
            {proxmox_capabilities ++ ["synthetic-other:v1"], "plugin_assignment_not_found"},
            {["plugin-host-authority:v1"], "missing_proxmox_identity_delivery_capabilities"}
          ] do
        {agent_id, partition} = plugin_result_agent!(capabilities)

        frame =
          build_plugin_result_frame([proxmox_result_item()],
            agent_id: agent_id,
            partition: partition
          )

        error =
          assert_raise RuntimeError, fn ->
            EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())
          end

        assert error.message =~ "plugin_result_handlers_failed"
        assert error.message =~ inspect(ProxmoxEnrichmentIngestor)
        assert error.message =~ expected
        assert ledger_count(frame.record) == 0
      end
    end

    test "a batch without host provenance is refused at decode" do
      frame =
        build_plugin_result_frame([plugin_result_item("synthetic-bare-check")], provenance: nil)

      assert {:error, :plugin_result_batch_no_provenance} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      assert ledger_count(frame.record) == 0
    end
  end

  describe "ingest/4 of unleased sweep results records" do
    test "a fresh record ingests its hosts through the sweep results ingest under the authenticated agent" do
      frame = build_unleased_sweep_frame(gateway_header: "gw-at-publish")

      assert {:ok, :inserted} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: stored_ack())

      refute_received {:metrics_published, _subject, _body, _opts}
      assert ledger_count(frame.record) == 1

      assert [
               %{
                 ip: "192.0.2.10",
                 status: :available,
                 open_ports: [22],
                 agent_id: agent_id,
                 sweep_group_id: group_id
               },
               %{ip: "192.0.2.11", status: unreached, open_ports: []}
             ] = unleased_host_results(frame.execution_id)

      assert agent_id == frame.agent_id
      assert group_id == frame.group_id
      assert unreached != :available

      assert %{hosts_total: 2, hosts_available: 1} =
               Repo.get!(SweepGroupExecution, frame.execution_id)
    end

    test "a redelivered record is a replay and ingests nothing again" do
      frame = build_unleased_sweep_frame(gateway_header: "gw-at-publish")

      assert {:ok, :inserted} = EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)
      before = Repo.get!(SweepGroupExecution, frame.execution_id)

      assert {:ok, :replay} = EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)

      assert length(unleased_host_results(frame.execution_id)) == 2
      assert Repo.get!(SweepGroupExecution, frame.execution_id) == before
      assert ledger_count(frame.record) == 1
    end

    test "a late-fenced record is recorded and ingests nothing" do
      frame = build_unleased_sweep_frame(delivery_mode: PublicationIdentity.mode_late_fenced())

      assert {:ok, :inserted} = EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)

      assert ledger_count(frame.record) == 1
      assert unleased_host_results(frame.execution_id) == []
      assert Repo.get(SweepGroupExecution, frame.execution_id) == nil
    end

    test "a record whose grant was revoked is refused and ingests nothing" do
      frame = build_unleased_sweep_frame()

      assert {:ok, 1} = OutputGrants.revoke_agent(frame.agent_id)

      assert {:error, :output_grant_not_current} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)

      assert unleased_host_results(frame.execution_id) == []
      assert Repo.get(SweepGroupExecution, frame.execution_id) == nil
      assert ledger_count(frame.record) == 0
    end

    test "a projected row count that disagrees with the hosts is refused" do
      frame = build_unleased_sweep_frame()
      refused = encode_frame(%{frame.record | projected_row_count: 1}, frame.batch, frame.slot)

      assert {:error, :unleased_sweep_row_count} =
               EdgeRecord.ingest(refused.record_bytes, refused.headers, Repo)

      assert unleased_host_results(frame.execution_id) == []
      assert ledger_count(refused.record) == 0
    end

    test "the publishing gateway header is the service state gateway id" do
      frame =
        build_unleased_sweep_frame(gateway?: true, gateway_header: "gw-at-publish")

      assert frame.gateway_id != "gw-at-publish"

      assert {:ok, :inserted} = EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)

      assert network_sweep_gateway(frame.agent_id) == "gw-at-publish"
    end

    test "a record with no publishing gateway header uses the agent gateway column" do
      frame = build_unleased_sweep_frame(gateway?: true)

      assert {:ok, :inserted} = EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)

      assert network_sweep_gateway(frame.agent_id) == frame.gateway_id
    end

    test "a record with no gateway header and no agent gateway is refused" do
      frame = build_unleased_sweep_frame()

      assert {:error, {:refused, :gateway_unknown}} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)

      assert network_sweep_gateway(frame.agent_id) == nil
      assert unleased_host_results(frame.execution_id) == []
      assert Repo.get(SweepGroupExecution, frame.execution_id) == nil
      assert ledger_count(frame.record) == 0
    end
  end

  describe "unleased sweep results fidelity" do
    # The agent test TestUnleasedSweepFidelityFixture writes both fixtures: one legacy results
    # response and the unleased batch the agent converts it to. Its hosts: one ICMP reached with
    # an open and a closed port, one unreached, one TCP-only, and one the agent calls available
    # although no check it reports reached it.
    test "the legacy results JSON and its unleased batch write identical rows" do
      json = File.read!(fidelity_fixture("unleased_sweep_fidelity_results.json"))

      batch =
        UnleasedSweepResultsBatchV1.decode(
          File.read!(fidelity_fixture("unleased_sweep_fidelity_body.bin"))
        )

      assert UnleasedSweepResults.legacy_json(batch) == json

      frame = build_unleased_sweep_frame(batch: batch, gateway?: true)

      legacy =
        fidelity_rows(frame, fn ->
          assert :ok =
                   ResultIngestor.process_and_publish(%{
                     service_name: "network_sweep",
                     service_type: "sweep",
                     available: true,
                     message: json,
                     response_time: 0,
                     agent_id: frame.agent_id,
                     gateway_id: frame.gateway_id,
                     partition: frame.partition_slug,
                     authenticated_partition: frame.partition_slug,
                     source: "results",
                     kv_store_id: "",
                     timestamp: System.os_time(:second),
                     agent_timestamp: 1_780_000_000,
                     chunk_index: 0,
                     total_chunks: 1,
                     is_final: true
                   })
        end)

      edge =
        fidelity_rows(frame, fn ->
          assert {:ok, :inserted} = EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)
        end)

      assert length(legacy.hosts) == 4
      assert [_ | _] = legacy.service_states

      assert %{"192.0.2.12" => :available, "192.0.2.13" => :available} =
               Map.new(legacy.hosts, &{&1.ip, &1.status})

      assert edge == legacy
    end
  end

  describe "ingest/4 of flow attribution records" do
    test "standing grant catalog and output contract bounds match the flow attribution and otlp relay contracts" do
      refs = ContractCatalog.standing_grant_refs()
      assert {@flow_attribution_contract, 1} in refs
      assert {@otlp_relay_contract, 1} in refs

      epoch = %{
        epoch: 1_000_001,
        snapshot_sha256: :binary.copy(<<0xCD>>, 32),
        contracts: ContractBundle.local().contracts
      }

      assert {:ok, flow_contract} =
               OutputContract.from_epoch(epoch, {@flow_attribution_contract, 1})

      assert {:ok, otlp_contract} =
               OutputContract.from_epoch(epoch, {@otlp_relay_contract, 1})

      assert flow_contract.max_projected_row_count == 4_096
      assert flow_contract.max_projected_write_bytes == 4_096 * 983_029

      assert otlp_contract.max_projected_row_count == 1_024
      assert otlp_contract.max_projected_write_bytes == 524_288
    end

    test "a fresh record publishes identical observation rows and emits batch_received after ledger commit like StatusHandler" do
      frame = build_flow_attribution_frame()
      test_pid = self()

      with_telemetry(
        [[:serviceradar, :event_writer, :attributed_flow, :batch_received]],
        fn _event, measurements, metadata, _config ->
          if self() == test_pid do
            send(test_pid, {:flow_batch_received, measurements, metadata})
          end
        end,
        fn ->
          publisher =
            {FlowAttribution, :publish_observations,
             [
               [
                 enabled: true,
                 publish: fn subject, body, msg_id ->
                   send(test_pid, {:legacy_flow_published, subject, body, msg_id})
                   :ok
                 end
               ]
             ]}

          assert {:ok, legacy_committed} =
                   StatusHandler.process_flow_attribution(
                     %{
                       partition: frame.partition_slug,
                       agent_id: frame.agent_id,
                       message: FlowAttributionEventBatch.encode(frame.batch)
                     },
                     flow_attribution_publisher: publisher
                   )

          StatusHandler.emit_flow_attribution_committed(legacy_committed)

          assert_received {:legacy_flow_published, legacy_subject, legacy_body, nil}
          assert_received {:flow_batch_received, legacy_measurements, legacy_metadata}

          assert {:ok, :inserted} =
                   EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo,
                     flow_attribution_publisher:
                       {FlowAttribution, :publish_observations, [[enabled: true]]},
                     request: stored_ack(:edge_flow_published, "flows")
                   )

          assert_received {:edge_flow_published, edge_subject, edge_body, edge_request_opts}
          assert_received {:flow_batch_received, edge_measurements, edge_metadata}

          assert edge_subject == legacy_subject
          assert edge_subject == Observations.subject()
          assert Observations.decode(edge_body) == Observations.decode(legacy_body)
          assert edge_measurements == legacy_measurements
          assert edge_measurements == %{count: 1, event_count: 2, dropped_since_last: 7}
          assert edge_metadata == legacy_metadata
          assert edge_metadata == %{partition_id: frame.partition_slug, agent_id: frame.agent_id}

          expected_msg_id = Ecto.UUID.load!(frame.record.event_id) <> ":0"
          assert {"Nats-Msg-Id", expected_msg_id} in edge_request_opts[:headers]
          assert ledger_count(frame.record) == 1
        end
      )
    end

    test "a redelivered or late-fenced record does not republish observations or emit batch_received" do
      frame = build_flow_attribution_frame()
      test_pid = self()

      with_telemetry(
        [[:serviceradar, :event_writer, :attributed_flow, :batch_received]],
        fn _event, measurements, metadata, _config ->
          if self() == test_pid do
            send(test_pid, {:flow_batch_received, measurements, metadata})
          end
        end,
        fn ->
          opts = [
            flow_attribution_publisher:
              {FlowAttribution, :publish_observations, [[enabled: true]]},
            request: stored_ack(:edge_flow_published, "flows")
          ]

          assert {:ok, :inserted} =
                   EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, opts)

          assert_received {:edge_flow_published, _subject, _body, _opts}
          assert_received {:flow_batch_received, _measurements, _metadata}

          assert {:ok, :replay} =
                   EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, opts)

          refute_received {:edge_flow_published, _subject, _body, _opts}
          refute_received {:flow_batch_received, _measurements, _metadata}

          late_frame =
            build_flow_attribution_frame(delivery_mode: PublicationIdentity.mode_late_fenced())

          assert {:ok, :inserted} =
                   EdgeRecord.ingest(late_frame.record_bytes, late_frame.headers, Repo, opts)

          refute_received {:edge_flow_published, _subject, _body, _opts}
          refute_received {:flow_batch_received, _measurements, _metadata}
          assert ledger_count(late_frame.record) == 1
        end
      )
    end

    test "a rolled-back ledger transaction does not emit batch_received, and a failed publish leaves no ledger row" do
      frame = build_flow_attribution_frame()
      test_pid = self()

      with_telemetry(
        [[:serviceradar, :event_writer, :attributed_flow, :batch_received]],
        fn _event, measurements, metadata, _config ->
          if self() == test_pid do
            send(test_pid, {:flow_batch_received, measurements, metadata})
          end
        end,
        fn ->
          refused_request = fn _subject, _body, _opts -> {:error, :timeout} end

          assert_raise RuntimeError, ~r/edge record publish failed/, fn ->
            EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo,
              flow_attribution_publisher:
                {FlowAttribution, :publish_observations, [[enabled: true]]},
              request: refused_request
            )
          end

          refute_received {:flow_batch_received, _measurements, _metadata}
          assert ledger_count(frame.record) == 0

          rollback_hook = fn
            :before_commit, _event_id, _result -> raise "injected rollback"
            _point, _event_id, _result -> :ok
          end

          assert_raise RuntimeError, "injected rollback", fn ->
            EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo,
              flow_attribution_publisher:
                {FlowAttribution, :publish_observations, [[enabled: true]]},
              request: stored_ack(:edge_flow_published, "flows"),
              test_hook: rollback_hook
            )
          end

          assert_received {:edge_flow_published, _subject, _body, _opts}
          refute_received {:flow_batch_received, _measurements, _metadata}
          assert ledger_count(frame.record) == 0

          assert {:ok, :inserted} =
                   EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo,
                     flow_attribution_publisher:
                       {FlowAttribution, :publish_observations, [[enabled: true]]},
                     request: stored_ack(:edge_flow_published, "flows")
                   )

          assert_received {:edge_flow_published, _subject, _body, _opts}
          assert_received {:flow_batch_received, %{count: 1, event_count: 2}, _metadata}
          assert ledger_count(frame.record) == 1
        end
      )
    end

    test "revoked grants, missing partitions, and malformed batch bounds are refused without publishing" do
      frame = build_flow_attribution_frame()

      assert {:ok, 1} = OutputGrants.revoke_agent(frame.agent_id)

      assert {:error, :output_grant_not_current} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo,
                 flow_attribution_publisher:
                   {FlowAttribution, :publish_observations, [[enabled: true]]},
                 request: stored_ack(:edge_flow_published, "flows")
               )

      refute_received {:edge_flow_published, _subject, _body, _opts}
      assert ledger_count(frame.record) == 0

      missing_partition_frame = build_flow_attribution_frame()

      Repo.query!("DELETE FROM platform.partitions WHERE id = $1::uuid", [
        Ecto.UUID.dump!(missing_partition_frame.partition_id)
      ])

      assert {:error, :flow_attribution_partition_not_found} =
               EdgeRecord.ingest(
                 missing_partition_frame.record_bytes,
                 missing_partition_frame.headers,
                 Repo,
                 flow_attribution_publisher:
                   {FlowAttribution, :publish_observations, [[enabled: true]]},
                 request: stored_ack(:edge_flow_published, "flows")
               )

      refute_received {:edge_flow_published, _subject, _body, _opts}
      assert ledger_count(missing_partition_frame.record) == 0

      bad_rows =
        encode_frame(
          %{frame.record | projected_row_count: 1, projected_write_bytes: 983_029},
          frame.batch,
          frame.slot
        )

      assert {:error, :flow_attribution_row_count} =
               EdgeRecord.ingest(bad_rows.record_bytes, bad_rows.headers, Repo)

      bad_write_bytes =
        encode_frame(
          %{frame.record | projected_write_bytes: 1_024},
          frame.batch,
          frame.slot
        )

      assert {:error, :flow_attribution_write_bytes} =
               EdgeRecord.ingest(bad_write_bytes.record_bytes, bad_write_bytes.headers, Repo)

      inverted_window =
        build_flow_attribution_frame(
          batch_start_unix_nano: 2_000_000_000,
          batch_end_unix_nano: 1_000_000_000
        )

      assert {:error, :flow_attribution_batch_window} =
               EdgeRecord.ingest(inverted_window.record_bytes, inverted_window.headers, Repo)
    end
  end

  describe "ingest/4 of otlp relay records" do
    test "a fresh record routes all four OTLP payload kinds with attested Sr-* headers, Nats-Msg-Id, spool telemetry, and non-duplicate signal telemetry" do
      frame = build_otlp_relay_frame()
      test_pid = self()

      with_telemetry(
        [
          [:serviceradar, :otlp_relay, :spool],
          [:serviceradar, :event_writer, :signal]
        ],
        fn
          [:serviceradar, :otlp_relay, :spool], measurements, metadata, _config ->
            if self() == test_pid do
              send(test_pid, {:otlp_spool, measurements, metadata})
            end

          [:serviceradar, :event_writer, :signal], measurements, metadata, _config ->
            if self() == test_pid and metadata.outcome == :relayed do
              send(test_pid, {:otlp_signal_relayed, metadata.signal, measurements.count})
            end
        end,
        fn ->
          assert {:ok, :inserted} =
                   EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo,
                     request: stored_ack(:otlp_published, "otel")
                   )

          assert_received {:otlp_spool,
                           %{
                             received: 14,
                             filtered: 2,
                             emitted: 12,
                             dropped: 3,
                             queue_depth: 5
                           }, %{partition_id: partition_slug, agent_id: agent_id}}

          assert partition_slug == frame.partition_slug
          assert agent_id == frame.agent_id

          expected_routes = [
            {"otel.traces.raw", "trace-chunk-bytes", "otlp-rec-1", :traces},
            {"logs.otel", "log-chunk-bytes", "otlp-rec-2", :logs},
            {"otel.metrics.raw", "metric-chunk-bytes", "otlp-rec-3", :metric_points},
            {"otel.metrics.derived", "derived-chunk-bytes", "otlp-rec-4", :metrics}
          ]

          for {expected_subject, expected_payload, expected_msg_id, expected_signal} <-
                expected_routes do
            assert_received {:otlp_published, ^expected_subject, ^expected_payload, request_opts}
            headers = Map.new(request_opts[:headers])

            assert headers["Nats-Msg-Id"] == expected_msg_id
            assert headers["Sr-Agent-Id"] == frame.agent_id
            assert headers["Sr-Partition"] == frame.partition_slug
            assert headers["Sr-Ingest-Identity"] == "agent:" <> frame.agent_id

            assert is_binary(headers["Sr-Ingress-Id"]) and
                     byte_size(headers["Sr-Ingress-Id"]) == 36

            assert is_binary(headers["Sr-Ingress-Time-Unix-Nano"])

            assert_received {:otlp_signal_relayed, ^expected_signal, 1}
          end

          assert ledger_count(frame.record) == 1
        end
      )
    end

    test "spool counters are emitted once after ledger commit and not when publish or commit fails" do
      frame = build_otlp_relay_frame()
      test_pid = self()

      with_telemetry(
        [[:serviceradar, :otlp_relay, :spool]],
        fn _event, measurements, metadata, _config ->
          if self() == test_pid do
            send(test_pid, {:otlp_spool, measurements, metadata})
          end
        end,
        fn ->
          refused_request = fn _subject, _body, _opts -> {:error, :timeout} end

          assert_raise RuntimeError, ~r/edge record publish failed/, fn ->
            EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: refused_request)
          end

          refute_received {:otlp_spool, _measurements, _metadata}
          assert ledger_count(frame.record) == 0

          rollback_hook = fn
            :before_commit, _event_id, _result -> raise "injected rollback"
            _point, _event_id, _result -> :ok
          end

          assert_raise RuntimeError, "injected rollback", fn ->
            EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo,
              request: stored_ack(:otlp_published, "otel"),
              test_hook: rollback_hook
            )
          end

          refute_received {:otlp_spool, _measurements, _metadata}
          assert ledger_count(frame.record) == 0

          assert {:ok, :inserted} =
                   EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo,
                     request: stored_ack(:otlp_published, "otel")
                   )

          assert_received {:otlp_spool, %{received: 14, dropped: 3},
                           %{partition_id: partition_slug, agent_id: agent_id}}

          assert partition_slug == frame.partition_slug
          assert agent_id == frame.agent_id
          refute_received {:otlp_spool, _measurements, _metadata}
          assert ledger_count(frame.record) == 1
        end
      )
    end

    test "duplicate PubAck suppresses the relayed signal counter while unroutable payload kinds emit record_rejected without failing the batch" do
      records = [
        %TelemetryRecord{
          event_id: "otlp-dup-1",
          payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
          payload: "trace-dup-bytes"
        },
        %TelemetryRecord{
          event_id: "otlp-unroutable-2",
          payload_kind: :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
          payload: "ocsf-bytes"
        },
        %TelemetryRecord{
          event_id: "otlp-fresh-3",
          payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_LOGS,
          payload: "log-fresh-bytes"
        }
      ]

      frame = build_otlp_relay_frame(records: records)
      test_pid = self()

      with_telemetry(
        [
          [:serviceradar, :otlp_relay, :record_rejected],
          [:serviceradar, :event_writer, :signal]
        ],
        fn
          [:serviceradar, :otlp_relay, :record_rejected], measurements, metadata, _config ->
            if self() == test_pid do
              send(test_pid, {:otlp_rejected, measurements, metadata})
            end

          [:serviceradar, :event_writer, :signal], measurements, metadata, _config ->
            if self() == test_pid and metadata.outcome == :relayed do
              send(test_pid, {:otlp_signal_relayed, metadata.signal, measurements.count})
            end
        end,
        fn ->
          request = fn subject, body, request_opts ->
            send(test_pid, {:otlp_published, subject, body, request_opts})

            if subject == "otel.traces.raw" do
              {:ok, %{body: ~s({"stream":"otel","seq":1,"duplicate":true})}}
            else
              {:ok, %{body: ~s({"stream":"otel","seq":2})}}
            end
          end

          assert {:ok, :inserted} =
                   EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo, request: request)

          assert_received {:otlp_published, "otel.traces.raw", "trace-dup-bytes", _opts}
          assert_received {:otlp_published, "logs.otel", "log-fresh-bytes", _opts}

          refute_received {:otlp_signal_relayed, :traces, _count}
          assert_received {:otlp_signal_relayed, :logs, 1}

          assert_received {:otlp_rejected, %{count: 1},
                           %{partition_id: partition_slug, agent_id: agent_id}}

          assert partition_slug == frame.partition_slug
          assert agent_id == frame.agent_id
          assert ledger_count(frame.record) == 1
        end
      )
    end

    test "replays, late-fenced deliveries, revoked grants, missing partitions, and publish failures follow the edge-record contract" do
      frame = build_otlp_relay_frame()

      assert {:ok, :inserted} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo,
                 request: stored_ack(:otlp_published, "otel")
               )

      for _ <- 1..4, do: assert_received({:otlp_published, _subject, _body, _opts})

      assert {:ok, :replay} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo,
                 request: stored_ack(:otlp_published, "otel")
               )

      refute_received {:otlp_published, _subject, _body, _opts}

      late_frame = build_otlp_relay_frame(delivery_mode: PublicationIdentity.mode_late_fenced())

      assert {:ok, :inserted} =
               EdgeRecord.ingest(late_frame.record_bytes, late_frame.headers, Repo,
                 request: stored_ack(:otlp_published, "otel")
               )

      refute_received {:otlp_published, _subject, _body, _opts}
      assert ledger_count(late_frame.record) == 1

      revoked_frame = build_otlp_relay_frame()

      assert {:ok, 1} = OutputGrants.revoke_agent(revoked_frame.agent_id)

      assert {:error, :output_grant_not_current} =
               EdgeRecord.ingest(revoked_frame.record_bytes, revoked_frame.headers, Repo,
                 request: stored_ack(:otlp_published, "otel")
               )

      refute_received {:otlp_published, _subject, _body, _opts}
      assert ledger_count(revoked_frame.record) == 0

      missing_partition_frame = build_otlp_relay_frame()

      Repo.query!("DELETE FROM platform.partitions WHERE id = $1::uuid", [
        Ecto.UUID.dump!(missing_partition_frame.partition_id)
      ])

      assert {:error, :otlp_relay_partition_not_found} =
               EdgeRecord.ingest(
                 missing_partition_frame.record_bytes,
                 missing_partition_frame.headers,
                 Repo,
                 request: stored_ack(:otlp_published, "otel")
               )

      refute_received {:otlp_published, _subject, _body, _opts}
      assert ledger_count(missing_partition_frame.record) == 0

      retry_frame = build_otlp_relay_frame()
      refused_request = fn _subject, _body, _opts -> {:error, :timeout} end

      assert_raise RuntimeError, ~r/edge record publish failed/, fn ->
        EdgeRecord.ingest(retry_frame.record_bytes, retry_frame.headers, Repo,
          request: refused_request
        )
      end

      assert ledger_count(retry_frame.record) == 0

      assert {:ok, :inserted} =
               EdgeRecord.ingest(retry_frame.record_bytes, retry_frame.headers, Repo,
                 request: stored_ack(:otlp_published, "otel")
               )

      assert ledger_count(retry_frame.record) == 1

      bad_write_bytes =
        encode_frame(
          %{retry_frame.record | projected_write_bytes: retry_frame.record.uncompressed_size + 1},
          retry_frame.batch,
          retry_frame.slot
        )

      assert {:error, :otlp_relay_write_bytes} =
               EdgeRecord.ingest(bad_write_bytes.record_bytes, bad_write_bytes.headers, Repo)
    end
  end

  describe "ingest/4 of scheduled MTR trace records" do
    test "a fresh record ingests its trace and hops under the authenticated agent and updates service state" do
      frame = build_scheduled_mtr_frame(gateway_header: "gw-mtr-publish")

      assert {:ok, :inserted} = EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)

      assert ledger_count(frame.record) == 1
      assert mtr_trace_gateway(frame.agent_id) == "gw-mtr-publish"

      assert [
               %{
                 id: trace_id,
                 agent_id: agent_id,
                 gateway_id: "gw-mtr-publish",
                 check_id: "mtr-check-01",
                 check_name: "Synthetic Edge Core Link",
                 device_id: "sr:0197f8a0-0000-7000-8000-000000000001",
                 target: "target.example.com",
                 target_ip: "192.0.2.10",
                 target_reached: true,
                 total_hops: 2,
                 probed_hops: 4,
                 last_responding_hop: 2,
                 protocol: "tcp",
                 tcp_port: 443,
                 tcp_handshake_ttl: 64,
                 tcp_handshake_attempts: 3,
                 tcp_syn_sent: 4,
                 tcp_synack_received: 3,
                 tcp_server_response_us: 3100
               }
             ] = mtr_traces_for(frame.trace_uuid)

      assert trace_id == frame.trace_uuid
      assert agent_id == frame.agent_id

      assert [
               %{hop_number: 1, addr: "198.51.100.1", reply_time_exceeded: 10, reply_synack: 0},
               %{
                 hop_number: 2,
                 addr: "192.0.2.10",
                 unreachable_code: 3,
                 reply_unreachable: 1,
                 reply_synack: 8
               }
             ] = mtr_hops_for(frame.trace_uuid)
    end

    test "a redelivered record is a replay and ingests no duplicate trace or hop rows" do
      frame = build_scheduled_mtr_frame(gateway_header: "gw-mtr-publish")

      assert {:ok, :inserted} = EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)
      assert {:ok, :replay} = EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)

      assert length(mtr_traces_for(frame.trace_uuid)) == 1
      assert length(mtr_hops_for(frame.trace_uuid)) == 2
      assert ledger_count(frame.record) == 1
    end

    test "a late-fenced record is recorded and ingests nothing" do
      frame = build_scheduled_mtr_frame(delivery_mode: PublicationIdentity.mode_late_fenced())

      assert {:ok, :inserted} = EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)

      assert ledger_count(frame.record) == 1
      assert mtr_traces_for(frame.trace_uuid) == []
      assert mtr_hops_for(frame.trace_uuid) == []
    end

    test "a record whose grant was revoked is refused and ingests nothing" do
      frame = build_scheduled_mtr_frame(gateway_header: "gw-mtr-publish")

      assert {:ok, 1} = OutputGrants.revoke_agent(frame.agent_id)

      assert {:error, :output_grant_not_current} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)

      assert mtr_traces_for(frame.trace_uuid) == []
      assert mtr_hops_for(frame.trace_uuid) == []
      assert ledger_count(frame.record) == 0
    end

    test "a projected row count that disagrees with the traces is refused" do
      frame = build_scheduled_mtr_frame(gateway_header: "gw-mtr-publish")
      refused = encode_frame(%{frame.record | projected_row_count: 2}, frame.batch, frame.slot)

      assert {:error, :scheduled_mtr_row_count} =
               EdgeRecord.ingest(refused.record_bytes, refused.headers, Repo)

      assert mtr_traces_for(frame.trace_uuid) == []
      assert ledger_count(refused.record) == 0
    end

    test "a record with no gateway header and no agent gateway is refused" do
      frame = build_scheduled_mtr_frame()

      assert {:error, {:refused, :gateway_unknown}} =
               EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)

      assert mtr_traces_for(frame.trace_uuid) == []
      assert ledger_count(frame.record) == 0
    end
  end

  describe "scheduled MTR trace fidelity" do
    test "a scheduled MTR trace batch and the legacy JSON ingestor write identical trace and hop rows" do
      frame = build_scheduled_mtr_frame(gateway?: true)

      status = %{
        service_name: "mtr_traces",
        service_type: "mtr",
        available: true,
        message: Jason.encode!(frame.legacy_payload),
        response_time: 0,
        agent_id: frame.agent_id,
        gateway_id: frame.gateway_id,
        partition: frame.partition_slug,
        authenticated_partition: frame.partition_slug,
        source: "results",
        kv_store_id: "",
        timestamp: System.os_time(:second),
        agent_timestamp: 1_780_000_000,
        chunk_index: 0,
        total_chunks: 1,
        is_final: true
      }

      legacy =
        mtr_fidelity_rows(frame, fn ->
          assert :ok =
                   MtrMetricsIngestor.ingest(frame.legacy_payload, status, skip_existing: true)

          assert :ok = ServiceStateRegistry.upsert_from_status_strict(status)
        end)

      edge =
        mtr_fidelity_rows(frame, fn ->
          assert {:ok, :inserted} = EdgeRecord.ingest(frame.record_bytes, frame.headers, Repo)
        end)

      assert length(legacy.traces) == 1
      assert length(legacy.hops) == 2
      assert [_ | _] = legacy.service_states
      assert edge == legacy
    end
  end

  defp mtr_fidelity_rows(frame, ingest) do
    {:error, {:rows, rows}} =
      Repo.transaction(fn ->
        ingest.()
        Repo.rollback({:rows, mtr_fidelity_snapshot(frame)})
      end)

    rows
  end

  defp mtr_fidelity_snapshot(frame) do
    trace_uuid = frame.trace_uuid
    agent_id = frame.agent_id

    %{
      traces: mtr_traces_for(trace_uuid),
      hops: mtr_hops_for(trace_uuid),
      service_states:
        Repo.all(
          Ecto.Query.from(s in ServiceState,
            where: s.agent_id == ^agent_id,
            order_by: [s.service_type, s.service_name],
            select:
              map(s, [
                :agent_id,
                :gateway_id,
                :partition,
                :service_type,
                :service_name,
                :available,
                :state
              ])
          )
        )
    }
  end

  defp mtr_trace_gateway(agent_id) do
    Repo.one(
      Ecto.Query.from(s in ServiceState,
        where:
          s.agent_id == ^agent_id and s.service_type == "mtr" and s.service_name == "mtr_traces",
        select: s.gateway_id
      )
    )
  end

  defp mtr_traces_for(trace_uuid) do
    Repo.all(
      Ecto.Query.from(t in MtrTrace,
        where: t.id == ^trace_uuid,
        select:
          map(t, [
            :id,
            :time,
            :agent_id,
            :gateway_id,
            :check_id,
            :check_name,
            :device_id,
            :target,
            :target_ip,
            :target_reached,
            :total_hops,
            :probed_hops,
            :last_responding_hop,
            :protocol,
            :tcp_port,
            :ip_version,
            :packet_size,
            :partition,
            :error,
            :tcp_handshake_ttl,
            :tcp_handshake_attempts,
            :tcp_syn_sent,
            :tcp_synack_received,
            :tcp_rst_received,
            :tcp_syn_unanswered,
            :tcp_syn_drop_pct,
            :tcp_syn_retransmits,
            :tcp_answered_after_retx,
            :tcp_ack_mismatch,
            :tcp_synack_duplicates,
            :tcp_handshake_rtt_min_us,
            :tcp_handshake_rtt_avg_us,
            :tcp_handshake_rtt_max_us,
            :tcp_server_response_us
          ])
      )
    )
  end

  defp mtr_hops_for(trace_uuid) do
    Repo.all(
      Ecto.Query.from(h in MtrHop,
        where: h.trace_id == ^trace_uuid,
        order_by: h.hop_number,
        select:
          map(h, [
            :id,
            :time,
            :trace_id,
            :target_ip,
            :device_id,
            :hop_number,
            :addr,
            :hostname,
            :ecmp_addrs,
            :asn,
            :asn_org,
            :mpls_labels,
            :sent,
            :received,
            :loss_pct,
            :last_us,
            :avg_us,
            :min_us,
            :max_us,
            :stddev_us,
            :jitter_us,
            :jitter_worst_us,
            :jitter_interarrival_us,
            :unreachable_code,
            :reply_time_exceeded,
            :reply_unreachable,
            :reply_synack,
            :reply_rst
          ])
      )
    )
  end

  defp build_scheduled_mtr_frame(opts \\ []) do
    {gateway?, opts} = Keyword.pop(opts, :gateway?, false)
    actor = SystemActor.system(:edge_record_test)
    partition = partition!(random_uuid(4), actor)
    agent_id = "agent-#{System.unique_integer([:positive])}"
    ensure_agent!(agent_id, partition, actor)
    gateway_id = if gateway?, do: attach_gateway!(agent_id, actor)

    {:ok, grant} =
      OutputGrants.reconcile(agent_id, @scheduled_mtr_contract, partition.id)

    key = IssuerKey.from_seed(:binary.copy(<<0x5A>>, 32))
    now = DateTime.utc_now()

    contract = %{
      contract_id: @scheduled_mtr_contract,
      contract_version: 1,
      contract_bundle_sha256: :crypto.hash(:sha256, "scheduled-mtr-bundle"),
      registry_epoch: 1,
      registry_snapshot_sha256: :crypto.hash(:sha256, "registry"),
      cost_model_version: 1,
      max_projected_row_count: 1_000,
      max_projected_write_bytes: 2_048_000
    }

    production = OutputGrants.production_capability(grant, contract, key, now)
    {:production, claims} = production.claims

    trace_id_bytes = Ecto.UUID.dump!(ExecutionSlots.mint_id(now))
    trace_uuid = Ecto.UUID.load!(trace_id_bytes)
    trace_event_id = Ecto.UUID.dump!(ExecutionSlots.mint_id(now))
    observed_nano = 1_780_000_000_000_000_000

    batch = %AgentScheduledMtrTraceBatchV1{
      traces: [
        %AgentScheduledMtrTraceV1{
          check_id: "mtr-check-01",
          check_name: "Synthetic Edge Core Link",
          device_id: "sr:0197f8a0-0000-7000-8000-000000000001",
          execution_source: :SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK,
          probed_hops: 4,
          last_responding_hop: 2,
          tcp_port: 443,
          tcp_probe_mode: :MTR_TCP_PROBE_MODE_V1_SYN,
          trace: %MtrTraceEventV1{
            trace_id: trace_id_bytes,
            event_id: trace_event_id,
            sweep_host_address: <<192, 0, 2, 10>>,
            device_hint: "sr:0197f8a0-0000-7000-8000-000000000001",
            observed_at_unix_nano: observed_nano,
            attempted: true,
            outcome: :MTR_OUTCOME_REACHED,
            target: "target.example.com",
            resolved_address: <<192, 0, 2, 10>>,
            protocol: :TRANSPORT_PROTOCOL_TCP,
            ip_version: 4,
            packet_size: 64,
            target_reached: true,
            total_hops: 2,
            hops: [
              %MtrTraceHopV1{
                hop_number: 1,
                address: <<198, 51, 100, 1>>,
                hostname: "hop1.example.com",
                ecmp_addresses: [<<198, 51, 100, 2>>],
                mpls_labels: [
                  %MtrMplsLabelV1{
                    label: 24_001,
                    experimental: 0,
                    bottom_of_stack: true,
                    ttl: 63
                  }
                ],
                asn: 64_512,
                asn_org: "Example Transit AS64512",
                sent: 10,
                received: 10,
                loss_pct: 0.0,
                last_micro: 1_200,
                avg_micro: 1_150,
                min_micro: 1_000,
                max_micro: 1_400,
                stddev_micro: 120,
                jitter_micro: 80,
                jitter_worst_micro: 200,
                jitter_interarrival_micro: 95
              },
              %MtrTraceHopV1{
                hop_number: 2,
                address: <<192, 0, 2, 10>>,
                hostname: "target.example.com",
                asn: 64_513,
                asn_org: "Example Edge AS64513",
                sent: 10,
                received: 9,
                loss_pct: 10.0,
                last_micro: 3_400,
                avg_micro: 3_200,
                min_micro: 2_900,
                max_micro: 3_800,
                stddev_micro: 250,
                jitter_micro: 140,
                jitter_worst_micro: 400,
                jitter_interarrival_micro: 160
              }
            ]
          },
          tcp_handshake: %MtrTcpHandshakeDiagnosticsV1{
            ttl: 64,
            attempts: 3,
            syn_sent: 4,
            synack_received: 3,
            rst_received: 0,
            unanswered: 1,
            syn_drop_pct: 25.0,
            syn_retransmits: 1,
            answered_after_retx: 1,
            ack_mismatch: 0,
            synack_duplicates: 0,
            rtt_min_us: 2_900,
            rtt_avg_us: 3_200,
            rtt_max_us: 3_800,
            server_response_us: 3_100,
            has_server_response_us: true
          },
          hop_diagnostics: [
            %MtrHopReplyDiagnosticsV1{
              hop_number: 1,
              reply_time_exceeded: 10
            },
            %MtrHopReplyDiagnosticsV1{
              hop_number: 2,
              has_unreachable_code: true,
              unreachable_code: 3,
              reply_unreachable: 1,
              reply_synack: 8
            }
          ]
        }
      ]
    }

    legacy_payload = %{
      "results" => [
        %{
          "trace_uuid" => trace_uuid,
          "check_id" => "mtr-check-01",
          "check_name" => "Synthetic Edge Core Link",
          "target" => "target.example.com",
          "device_id" => "sr:0197f8a0-0000-7000-8000-000000000001",
          "available" => true,
          "timestamp" => observed_nano,
          "error" => nil,
          "trace" => %{
            "target" => "target.example.com",
            "target_ip" => "192.0.2.10",
            "target_reached" => true,
            "total_hops" => 2,
            "probed_hops" => 4,
            "last_responding_hop" => 2,
            "protocol" => "tcp",
            "tcp_port" => 443,
            "tcp_probe_mode" => "syn",
            "ip_version" => 4,
            "packet_size" => 64,
            "timestamp" => observed_nano,
            "tcp_handshake" => %{
              "ttl" => 64,
              "attempts" => 3,
              "syn_sent" => 4,
              "synack_received" => 3,
              "rst_received" => 0,
              "unanswered" => 1,
              "syn_drop_pct" => 25.0,
              "syn_retransmits" => 1,
              "answered_after_retx" => 1,
              "ack_mismatch" => 0,
              "synack_duplicates" => 0,
              "rtt_min_us" => 2_900,
              "rtt_avg_us" => 3_200,
              "rtt_max_us" => 3_800,
              "server_response_us" => 3_100
            },
            "hops" => [
              %{
                "hop_number" => 1,
                "addr" => "198.51.100.1",
                "hostname" => "hop1.example.com",
                "ecmp_addrs" => ["198.51.100.2"],
                "asn" => %{"asn" => 64_512, "org" => "Example Transit AS64512"},
                "mpls_labels" => [%{"label" => 24_001, "exp" => 0, "s" => true, "ttl" => 63}],
                "sent" => 10,
                "received" => 10,
                "loss_pct" => 0.0,
                "last_us" => 1_200,
                "avg_us" => 1_150,
                "min_us" => 1_000,
                "max_us" => 1_400,
                "stddev_us" => 120,
                "jitter_us" => 80,
                "jitter_worst_us" => 200,
                "jitter_interarrival_us" => 95,
                "reply_time_exceeded" => 10
              },
              %{
                "hop_number" => 2,
                "addr" => "192.0.2.10",
                "hostname" => "target.example.com",
                "ecmp_addrs" => [],
                "asn" => %{"asn" => 64_513, "org" => "Example Edge AS64513"},
                "mpls_labels" => nil,
                "sent" => 10,
                "received" => 9,
                "loss_pct" => 10.0,
                "last_us" => 3_400,
                "avg_us" => 3_200,
                "min_us" => 2_900,
                "max_us" => 3_800,
                "stddev_us" => 250,
                "jitter_us" => 140,
                "jitter_worst_us" => 400,
                "jitter_interarrival_us" => 160,
                "unreachable_code" => 3,
                "reply_unreachable" => 1,
                "reply_synack" => 8
              }
            ]
          }
        }
      ]
    }

    payload = AgentScheduledMtrTraceBatchV1.encode(batch)

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
      network_scope_id: Ecto.UUID.dump!(partition.id),
      projected_row_count: length(batch.traces),
      projected_write_bytes: 0,
      cost_model_version: 1,
      payload: payload
    }

    slot = %{
      network_scope_id: record.network_scope_id,
      authenticated_agent_id: agent_id,
      spool_id: random_uuid(7),
      sequence: 1
    }

    record
    |> encode_frame(batch, slot, opts)
    |> Map.merge(%{
      agent_id: agent_id,
      partition_id: partition.id,
      partition_slug: partition.slug,
      gateway_id: gateway_id,
      trace_uuid: trace_uuid,
      legacy_payload: legacy_payload
    })
  end

  defp fidelity_fixture(name),
    do: Path.expand("../../../../../../proto/edge/v1/testdata/#{name}", __DIR__)

  # Runs one path in a transaction it rolls back, returning the rows it wrote, so both paths
  # start from the same database.
  defp fidelity_rows(frame, ingest) do
    {:error, {:rows, rows}} =
      Repo.transaction(fn ->
        ingest.()
        Repo.rollback({:rows, fidelity_snapshot(frame)})
      end)

    rows
  end

  defp fidelity_snapshot(frame) do
    execution_id = frame.execution_id
    partition = frame.partition_slug
    agent_id = frame.agent_id

    %{
      hosts:
        Repo.all(
          Ecto.Query.from(h in SweepHostResult,
            where: h.execution_id == ^execution_id,
            order_by: h.ip,
            select:
              map(h, [
                :ip,
                :hostname,
                :status,
                :response_time_ms,
                :open_ports,
                :scanned_ports,
                :sweep_modes_results,
                :agent_id,
                :sweep_group_id,
                :error_message
              ])
          )
        ),
      devices:
        Repo.all(
          Ecto.Query.from(d in Device,
            where: d.partition == ^partition and d.ip != "198.51.100.254",
            order_by: d.ip,
            select: map(d, [:ip, :hostname, :is_available, :discovery_sources])
          )
        ),
      availability:
        Repo.all(
          Ecto.Query.from(a in DeviceAgentAvailability,
            join: d in Device,
            on: d.uid == a.device_uid,
            where: a.agent_id == ^agent_id,
            order_by: d.ip,
            select: %{
              ip: d.ip,
              is_available: a.is_available,
              response_time_ms: a.response_time_ms,
              open_ports: a.open_ports,
              sweep_modes_results: a.sweep_modes_results,
              sweep_group_id: a.sweep_group_id,
              execution_id: a.execution_id
            }
          )
        ),
      execution:
        Repo.one(
          Ecto.Query.from(e in SweepGroupExecution,
            where: e.id == ^execution_id,
            select:
              map(e, [
                :status,
                :hosts_total,
                :hosts_available,
                :hosts_failed,
                :error_message,
                :agent_id,
                :sweep_group_id,
                :scanner_metrics,
                :banner_grab_summary
              ])
          )
        ),
      service_states:
        Repo.all(
          Ecto.Query.from(s in ServiceState,
            where: s.agent_id == ^agent_id,
            order_by: [s.service_type, s.service_name],
            select:
              map(s, [
                :agent_id,
                :gateway_id,
                :partition,
                :service_type,
                :service_name,
                :available,
                :message,
                :details,
                :last_observed_at,
                :state
              ])
          )
        )
    }
  end

  defp network_sweep_gateway(agent_id) do
    Repo.one(
      Ecto.Query.from(s in ServiceState,
        where:
          s.agent_id == ^agent_id and s.service_type == "sweep" and
            s.service_name == "network_sweep",
        select: s.gateway_id
      )
    )
  end

  defp unleased_host_results(execution_id) do
    Repo.all(
      Ecto.Query.from(h in SweepHostResult,
        where: h.execution_id == ^execution_id,
        order_by: h.ip
      )
    )
  end

  # An unleased group's results: one host reached by ICMP with SSH open and HTTPS closed, and one
  # host ICMP did not reach, both tested on the same two ports.
  defp build_unleased_sweep_frame(opts \\ []) do
    {batch_override, opts} = Keyword.pop(opts, :batch)
    {gateway?, opts} = Keyword.pop(opts, :gateway?, false)
    actor = SystemActor.system(:edge_record_test)
    partition = partition!(random_uuid(4), actor)
    agent_id = "agent-#{System.unique_integer([:positive])}"
    ensure_agent!(agent_id, partition, actor)

    gateway_id = if gateway?, do: attach_gateway!(agent_id, actor)

    group =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "unleased-#{System.unique_integer([:positive])}",
          partition: partition.slug,
          enabled: false,
          interval: "15m",
          agent_ids: [agent_id],
          static_targets: fixture_targets(batch_override),
          sweep_modes: ["icmp", "tcp_connect"],
          ports: [22, 443]
        },
        actor: actor
      )
      |> fixture_group_id(batch_override)
      |> Ash.create!()

    {:ok, grant} =
      OutputGrants.reconcile(agent_id, @unleased_sweep_contract, partition.id)

    key = IssuerKey.from_seed(:binary.copy(<<0x5A>>, 32))
    now = DateTime.utc_now()

    contract = %{
      contract_id: @unleased_sweep_contract,
      contract_version: 1,
      contract_bundle_sha256: :crypto.hash(:sha256, "unleased-sweep-bundle"),
      registry_epoch: 1,
      registry_snapshot_sha256: :crypto.hash(:sha256, "registry"),
      cost_model_version: 1,
      max_projected_row_count: 10_000,
      max_projected_write_bytes: 20_480_000
    }

    production = OutputGrants.production_capability(grant, contract, key, now)
    {:production, claims} = production.claims
    execution_id = Ecto.UUID.generate()

    batch = %UnleasedSweepResultsBatchV1{
      execution_id: Ecto.UUID.dump!(execution_id),
      sweep_group_id: Ecto.UUID.dump!(group.id),
      network_cidr: "192.0.2.10/31",
      last_sweep_unix_nano: DateTime.to_unix(now, :nanosecond),
      chunk_index: 0,
      total_chunks: 1,
      is_final: true,
      expected_total_hosts: 2,
      available_hosts: 1,
      tested_checks: [
        %SweepTestV1{mode: :SWEEP_MODE_ICMP, protocol: :TRANSPORT_PROTOCOL_ICMP},
        %SweepTestV1{mode: :SWEEP_MODE_TCP_CONNECT, protocol: :TRANSPORT_PROTOCOL_TCP, port: 22},
        %SweepTestV1{mode: :SWEEP_MODE_TCP_CONNECT, protocol: :TRANSPORT_PROTOCOL_TCP, port: 443}
      ],
      port_counts: [
        %UnleasedSweepPortCountV1{port: 22, available: 1},
        %UnleasedSweepPortCountV1{port: 443, available: 0}
      ],
      hosts: [
        %SweepHostObservationV1{
          address: <<192, 0, 2, 10>>,
          icmp: %SweepIcmpSummaryV1{
            target_reached: true,
            round_trip_micro: 1_500,
            packet_loss_pct: 0.0
          },
          open_ports: [
            %SweepOpenPortV1{tested_check_index: 1, response_time_nano: 2_000_000, service: "ssh"}
          ],
          port_errors: [%SweepPortErrorV1{tested_check_index: 2, error_code: "closed"}]
        },
        %SweepHostObservationV1{
          address: <<192, 0, 2, 11>>,
          icmp: %SweepIcmpSummaryV1{target_reached: false, packet_loss_pct: 100.0},
          port_errors: [
            %SweepPortErrorV1{tested_check_index: 1, error_code: "closed"},
            %SweepPortErrorV1{tested_check_index: 2, error_code: "closed"}
          ]
        }
      ],
      host_results: [
        %UnleasedSweepHostResultV1{
          available: true,
          response_time_nano: 1_500_000,
          icmp_round_trip_nano: 1_500_000,
          first_seen: "2026-06-01T11:00:00Z",
          last_seen: "2026-06-01T12:00:00Z",
          port_results: [
            %UnleasedSweepPortResultV1{
              port: 22,
              available: true,
              response_time_nano: 2_000_000,
              service: "ssh"
            },
            %UnleasedSweepPortResultV1{port: 443, response_time_nano: 900_000}
          ]
        },
        %UnleasedSweepHostResultV1{
          first_seen: "2026-06-01T11:00:00Z",
          last_seen: "2026-06-01T12:00:00Z",
          port_results: [
            %UnleasedSweepPortResultV1{port: 22},
            %UnleasedSweepPortResultV1{port: 443}
          ]
        }
      ]
    }

    batch = batch_override || batch
    execution_id = Ecto.UUID.load!(batch.execution_id)
    payload = UnleasedSweepResultsBatchV1.encode(batch)

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
      network_scope_id: Ecto.UUID.dump!(partition.id),
      projected_row_count: length(batch.hosts),
      projected_write_bytes: 0,
      cost_model_version: 1,
      payload: payload
    }

    slot = %{
      network_scope_id: record.network_scope_id,
      authenticated_agent_id: agent_id,
      spool_id: random_uuid(7),
      sequence: 1
    }

    record
    |> encode_frame(batch, slot, opts)
    |> Map.merge(%{
      agent_id: agent_id,
      partition_id: partition.id,
      partition_slug: partition.slug,
      gateway_id: gateway_id,
      group_id: group.id,
      execution_id: execution_id
    })
  end

  # Registers a gateway and connects the agent to it, as the legacy status names it.
  defp attach_gateway!(agent_id, actor) do
    gateway_id = "gateway-#{System.unique_integer([:positive])}"

    ServiceRadar.Infrastructure.Gateway
    |> Ash.Changeset.for_create(:register, %{id: gateway_id}, actor: actor)
    |> Ash.create!(domain: ServiceRadar.Infrastructure)

    Repo.query!("UPDATE platform.ocsf_agents SET gateway_id = $1 WHERE uid = $2", [
      gateway_id,
      agent_id
    ])

    gateway_id
  end

  defp fixture_targets(nil), do: ["192.0.2.10", "192.0.2.11"]

  defp fixture_targets(batch),
    do: Enum.map(batch.hosts, fn %{address: <<a, b, c, d>>} -> "#{a}.#{b}.#{c}.#{d}" end)

  # A fixture batch names its sweep group, so the group is created under that id.
  defp fixture_group_id(changeset, nil), do: changeset

  defp fixture_group_id(changeset, batch),
    do:
      Ash.Changeset.force_change_attribute(changeset, :id, Ecto.UUID.load!(batch.sweep_group_id))

  # Re-encodes a metrics frame with another ingest identity source, keeping its slot.
  defp with_source(frame, source) do
    batch = %{frame.batch | ingest_identity: %{frame.batch.ingest_identity | source: source}}
    payload = MetricBatch.encode(batch)

    record = %{
      frame.record
      | payload: payload,
        encoded_size: byte_size(payload),
        uncompressed_size: byte_size(payload),
        payload_sha256: :crypto.hash(:sha256, payload)
    }

    record
    |> encode_frame(batch, frame.slot)
    |> Map.merge(Map.take(frame, [:agent_id, :partition_id]))
  end

  defp stored_ack(tag \\ :metrics_published, stream \\ "metrics") do
    test = self()

    fn subject, body, request_opts ->
      send(test, {tag, subject, body, request_opts})
      {:ok, %{body: ~s({"stream":"#{stream}","seq":1})}}
    end
  end

  defp build_flow_attribution_frame(opts \\ []) do
    actor = SystemActor.system(:edge_record_test)
    partition = partition!(random_uuid(4), actor)
    agent_id = "agent-#{System.unique_integer([:positive])}"
    ensure_agent!(agent_id, partition, actor)

    {:ok, grant} =
      OutputGrants.reconcile(agent_id, @flow_attribution_contract, partition.id)

    key = IssuerKey.from_seed(:binary.copy(<<0x5A>>, 32))
    now = DateTime.utc_now()

    contract = %{
      contract_id: @flow_attribution_contract,
      contract_version: 1,
      contract_bundle_sha256: :crypto.hash(:sha256, "flow-attribution-bundle"),
      registry_epoch: 1,
      registry_snapshot_sha256: :crypto.hash(:sha256, "registry"),
      cost_model_version: 1,
      max_projected_row_count: 4_096,
      max_projected_write_bytes: 4_096 * 983_029
    }

    production = OutputGrants.production_capability(grant, contract, key, now)
    {:production, claims} = production.claims
    observed = DateTime.to_unix(now, :nanosecond)

    batch = %FlowAttributionEventBatch{
      batch_start_unix_nano: Keyword.get(opts, :batch_start_unix_nano, observed - 1_000_000),
      batch_end_unix_nano: Keyword.get(opts, :batch_end_unix_nano, observed),
      dropped_since_last: Keyword.get(opts, :dropped_since_last, 7),
      events: [
        %FlowAttributionEvent{
          local_ip: "192.0.2.10",
          local_port: 41_234,
          remote_ip: "198.51.100.20",
          remote_port: 443,
          transport_protocol: "tcp",
          pid: 1_234,
          comm: "synthetic-client",
          redacted_cmdline: ["/usr/bin/synthetic-client", "--target", "https://example.com"],
          uid: 1_000,
          observed_at_unix_nano: observed
        },
        %FlowAttributionEvent{
          local_ip: "192.0.2.10",
          local_port: 53_100,
          remote_ip: "198.51.100.53",
          remote_port: 53,
          transport_protocol: "udp",
          pid: 2_345,
          comm: "synthetic-resolver",
          redacted_cmdline: ["/usr/sbin/synthetic-resolver"],
          uid: 101,
          observed_at_unix_nano: observed
        }
      ]
    }

    payload = FlowAttributionEventBatch.encode(batch)
    row_count = length(batch.events)

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
      network_scope_id: Ecto.UUID.dump!(partition.id),
      projected_row_count: row_count,
      projected_write_bytes: row_count * 983_029,
      cost_model_version: 1,
      payload: payload
    }

    slot = %{
      network_scope_id: record.network_scope_id,
      authenticated_agent_id: agent_id,
      spool_id: random_uuid(7),
      sequence: 1
    }

    record
    |> encode_frame(batch, slot, opts)
    |> Map.merge(%{
      agent_id: agent_id,
      partition_id: partition.id,
      partition_slug: partition.slug
    })
  end

  defp build_otlp_relay_frame(opts \\ []) do
    actor = SystemActor.system(:edge_record_test)
    partition = partition!(random_uuid(4), actor)
    agent_id = "agent-#{System.unique_integer([:positive])}"
    ensure_agent!(agent_id, partition, actor)

    {:ok, grant} = OutputGrants.reconcile(agent_id, @otlp_relay_contract, partition.id)
    key = IssuerKey.from_seed(:binary.copy(<<0x5A>>, 32))
    now = DateTime.utc_now()

    contract = %{
      contract_id: @otlp_relay_contract,
      contract_version: 1,
      contract_bundle_sha256: :crypto.hash(:sha256, "otlp-relay-bundle"),
      registry_epoch: 1,
      registry_snapshot_sha256: :crypto.hash(:sha256, "registry"),
      cost_model_version: 1,
      max_projected_row_count: 1_024,
      max_projected_write_bytes: 524_288
    }

    production = OutputGrants.production_capability(grant, contract, key, now)
    {:production, claims} = production.claims

    default_records = [
      %TelemetryRecord{
        event_id: "otlp-rec-1",
        payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
        payload: "trace-chunk-bytes",
        metadata: %{"agent_id" => "spoofed-agent", "partition" => "spoofed-partition"}
      },
      %TelemetryRecord{
        event_id: "otlp-rec-2",
        payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_LOGS,
        payload: "log-chunk-bytes"
      },
      %TelemetryRecord{
        event_id: "otlp-rec-3",
        payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_METRICS,
        payload: "metric-chunk-bytes"
      },
      %TelemetryRecord{
        event_id: "otlp-rec-4",
        payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_DERIVED_METRIC,
        payload: "derived-chunk-bytes"
      }
    ]

    records = Keyword.get(opts, :records, default_records)

    frame = %OtlpRelayFrame{
      relay_id: Keyword.get(opts, :relay_id, 42),
      batch: %AddonTelemetryBatch{
        source: %TelemetrySource{
          source_type: "otlp",
          source_instance: "otel-addon",
          metadata: %{"agent_id" => "spoofed-agent", "partition" => "spoofed-partition"}
        },
        counters: %TelemetryCounters{
          received: 14,
          filtered: 2,
          emitted: 12,
          dropped: 3,
          queue_depth: 5
        },
        records: records
      }
    }

    payload = OtlpRelayFrame.encode(frame)

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
      network_scope_id: Ecto.UUID.dump!(partition.id),
      projected_row_count: length(records),
      projected_write_bytes: byte_size(payload),
      cost_model_version: 1,
      payload: payload
    }

    slot = %{
      network_scope_id: record.network_scope_id,
      authenticated_agent_id: agent_id,
      spool_id: random_uuid(7),
      sequence: 1
    }

    record
    |> encode_frame(frame, slot, opts)
    |> Map.merge(%{
      agent_id: agent_id,
      partition_id: partition.id,
      partition_slug: partition.slug
    })
  end

  defp build_metrics_frame do
    actor = SystemActor.system(:edge_record_test)
    partition = partition!(random_uuid(4), actor)
    agent_id = "agent-#{System.unique_integer([:positive])}"
    ensure_agent!(agent_id, partition, actor)

    {:ok, grant} = OutputGrants.reconcile(agent_id, @metrics_contract, partition.id)
    key = IssuerKey.from_seed(:binary.copy(<<0x5A>>, 32))
    now = DateTime.utc_now()

    contract = %{
      contract_id: @metrics_contract,
      contract_version: 1,
      contract_bundle_sha256: :crypto.hash(:sha256, "metrics-bundle"),
      registry_epoch: 1,
      registry_snapshot_sha256: :crypto.hash(:sha256, "registry"),
      cost_model_version: 1,
      max_projected_row_count: 10_000,
      max_projected_write_bytes: 20_480_000
    }

    production = OutputGrants.production_capability(grant, contract, key, now)
    {:production, claims} = production.claims
    observed = DateTime.to_unix(now, :nanosecond)

    batch = %MetricBatch{
      schema_version: "serviceradar.metric.v1",
      resource: %MetricResource{agent_id: "agent-claimed-by-body", service_name: "sysmon"},
      ingest_identity: %IngestIdentity{source: "sysmon-metrics", producer_kind: "agent-sysmon"},
      metrics: [
        sysmon_metric("cpu_usage_percent", 12.5, observed),
        sysmon_metric("cpu_usage_percent", 13.0, observed)
      ]
    }

    payload = MetricBatch.encode(batch)

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
      network_scope_id: Ecto.UUID.dump!(partition.id),
      projected_row_count: length(batch.metrics),
      projected_write_bytes: 0,
      cost_model_version: 1,
      payload: payload
    }

    slot = %{
      network_scope_id: record.network_scope_id,
      authenticated_agent_id: agent_id,
      spool_id: random_uuid(7),
      sequence: 1
    }

    record
    |> encode_frame(batch, slot)
    |> Map.merge(%{agent_id: agent_id, partition_id: partition.id})
  end

  defp metrics_telemetry_record(schema_version \\ "serviceradar.metric.v1") do
    metric_batch = %MetricBatch{
      schema_version: schema_version,
      resource: %MetricResource{gateway_id: "guest-claimed-gateway"},
      metrics: [
        %Metric{
          name: "dns_rpz_hits_total",
          metric_type: "dns",
          kind: :METRIC_KIND_SUM,
          points: [%MetricPoint{value: 3.0, observed_at_unix_nano: 1_000}]
        }
      ]
    }

    %TelemetryRecord{
      payload_kind: :TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS,
      payload: MetricBatch.encode(metric_batch)
    }
  end

  defp build_telemetry_frame(records, opts \\ []) do
    actor = SystemActor.system(:edge_record_test)
    partition = partition!(random_uuid(4), actor)
    agent_id = "agent-#{System.unique_integer([:positive])}"
    ensure_agent!(agent_id, partition, actor)

    {:ok, grant} = OutputGrants.reconcile(agent_id, @telemetry_contract, partition.id)

    metadata =
      if Keyword.get(opts, :stamp, true) do
        %{
          "serviceradar.producer_type" => Keyword.get(opts, :producer_type, "plugin"),
          "serviceradar.producer_id" => Keyword.get(opts, :producer_id, "assignment-telemetry-1")
        }
      else
        %{}
      end

    batch = %AddonTelemetryBatch{
      source: %TelemetrySource{metadata: metadata},
      records: records,
      counters: Keyword.get(opts, :counters)
    }

    payload = AddonTelemetryBatch.encode(batch)
    key = IssuerKey.from_seed(:binary.copy(<<0x5B>>, 32))
    now = DateTime.shift(DateTime.utc_now(), second: 1)

    contract = %{
      contract_id: @telemetry_contract,
      contract_version: 1,
      contract_bundle_sha256: :crypto.hash(:sha256, "telemetry-bundle"),
      registry_epoch: 1,
      registry_snapshot_sha256: :crypto.hash(:sha256, "registry"),
      cost_model_version: 1,
      max_projected_row_count: 10_000,
      max_projected_write_bytes: 81_920_000
    }

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
      network_scope_id: Ecto.UUID.dump!(partition.id),
      projected_row_count: length(records),
      projected_write_bytes: length(records) * 8_192,
      cost_model_version: 1,
      payload: payload
    }

    slot = %{
      network_scope_id: record.network_scope_id,
      authenticated_agent_id: agent_id,
      spool_id: random_uuid(7),
      sequence: 1
    }

    record
    |> encode_frame(batch, slot)
    |> Map.merge(%{agent_id: agent_id, partition_id: partition.id})
  end

  defp plugin_result_agent!(capabilities \\ []) do
    actor = SystemActor.system(:edge_record_test)
    partition = partition!(random_uuid(4), actor)
    agent_id = "agent-#{System.unique_integer([:positive])}"
    ensure_agent!(agent_id, partition, actor, capabilities)
    {agent_id, partition}
  end

  defp proxmox_result_item do
    details = %{
      "schema" => "serviceradar.proxmox_enrichment.v1",
      "targets" => [
        %{
          "cluster" => [%{"type" => "cluster", "id" => "lab01", "name" => "lab01"}],
          "nodes" => [%{"node" => "pve01", "status" => "online"}],
          "guests" => []
        }
      ]
    }

    %{
      plugin_result_item("proxmox-inventory")
      | details: Jason.encode!(details),
        labels: %{"assignment_id" => Ecto.UUID.generate(), "plugin_id" => "proxmox-inventory"}
    }
  end

  defp plugin_result_item(name) do
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

  defp plugin_service_names(agent_id) do
    List.flatten(
      Repo.query!(
        "SELECT DISTINCT service_name FROM platform.service_status WHERE agent_id = $1 ORDER BY service_name",
        [
          agent_id
        ]
      ).rows
    )
  end

  defp plugin_service_row_count(agent_id) do
    [[count]] =
      Repo.query!("SELECT count(*) FROM platform.service_status WHERE agent_id = $1", [agent_id]).rows

    count
  end

  defp build_plugin_result_frame(items, opts \\ []) do
    partition =
      Keyword.get_lazy(opts, :partition, fn ->
        partition!(random_uuid(4), SystemActor.system(:edge_record_test))
      end)

    agent_id = Keyword.get(opts, :agent_id, "agent-#{System.unique_integer([:positive])}")

    if !Keyword.has_key?(opts, :agent_id) do
      ensure_agent!(agent_id, partition, SystemActor.system(:edge_record_test))
    end

    {:ok, grant} = OutputGrants.reconcile(agent_id, @plugin_results_contract, partition.id)

    provenance =
      case Keyword.get(opts, :provenance, :default) do
        nil ->
          nil

        :default ->
          %PluginResultProvenanceV1{
            assignment_id: Keyword.get(opts, :assignment_id, "assignment-plugin-results-1"),
            plugin_id: Keyword.get(opts, :plugin_id, "synthetic-edge-check"),
            plugin_package_id: "pkg-synthetic-1",
            plugin_version: "1.0.0",
            content_hash: String.duplicate("ab", 32)
          }
      end

    batch = %WasmPluginResultBatchV1{provenance: provenance, results: items}
    payload = WasmPluginResultBatchV1.encode(batch)
    now = DateTime.utc_now()

    contract = %{
      contract_id: @plugin_results_contract,
      contract_version: 1,
      contract_bundle_sha256: :crypto.hash(:sha256, "plugin-results-bundle"),
      registry_epoch: 1,
      registry_snapshot_sha256: :crypto.hash(:sha256, "registry"),
      cost_model_version: 1,
      max_projected_row_count: 10_000,
      max_projected_write_bytes: 163_840_000
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
      network_scope_id: Ecto.UUID.dump!(partition.id),
      projected_row_count: length(items),
      projected_write_bytes: length(items) * 16_384,
      cost_model_version: 1,
      payload: payload
    }

    slot = %{
      network_scope_id: record.network_scope_id,
      authenticated_agent_id: agent_id,
      spool_id: random_uuid(7),
      sequence: 1
    }

    record
    |> encode_frame(batch, slot)
    |> Map.merge(%{agent_id: agent_id, partition_id: partition.id})
  end

  defp sysmon_metric(name, value, observed) do
    %Metric{
      name: name,
      metric_type: "cpu",
      kind: :METRIC_KIND_GAUGE,
      points: [%MetricPoint{value: value, observed_at_unix_nano: observed}]
    }
  end

  defp build_frame(opts \\ []) do
    slot_override = Keyword.get(opts, :slot)

    {network_scope_id, agent_id} =
      case slot_override do
        %{network_scope_id: ns, authenticated_agent_id: agent} ->
          {ns, agent}

        nil ->
          {Keyword.get_lazy(opts, :network_scope_id, fn -> random_uuid(4) end),
           Keyword.get(opts, :agent_id, "agent-#{System.unique_integer([:positive])}")}
      end

    actor = SystemActor.system(:edge_record_test)
    partition = partition!(network_scope_id, actor)
    network_scope_id = Ecto.UUID.dump!(partition.id)
    ensure_agent!(agent_id, partition, actor)

    spool_id =
      case slot_override do
        %{spool_id: spool_id} -> spool_id
        nil -> Keyword.get_lazy(opts, :spool_id, fn -> random_uuid(7) end)
      end

    sequence =
      case slot_override do
        %{sequence: sequence} -> sequence
        nil -> Keyword.get(opts, :sequence, 1)
      end

    slot = %{
      network_scope_id: network_scope_id,
      authenticated_agent_id: agent_id,
      spool_id: spool_id,
      sequence: sequence
    }

    event_id =
      Keyword.get_lazy(opts, :event_id, fn ->
        Ecto.UUID.dump!(ExecutionSlots.mint_id(DateTime.utc_now()))
      end)

    host_octet = Keyword.get(opts, :host_octet, 1)

    group =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "edge-#{System.unique_integer([:positive])}",
          partition: partition.slug,
          enabled: false,
          interval: "15m",
          agent_ids: [agent_id],
          static_targets: Keyword.get(opts, :targets, ["192.0.2.#{host_octet}"]),
          sweep_modes: ["icmp", "tcp_connect"],
          ports: [443]
        },
        actor: actor
      )
      |> Ash.create!()

    {:ok, assignment} = ProducerAssignments.ensure(group.id, agent_id, partition.id)
    <<event_ms::48, _::80>> = event_id
    now = DateTime.from_unix!(event_ms, :millisecond)

    {:ok, execution_slot} =
      ExecutionSlots.schedule(assignment, now, DateTime.shift(now, minute: 15),
        targets: group.static_targets,
        check_set_sha256: HashGrammar.check_set_digest([{1, 1, 0}, {3, 2, 443}]),
        lease_id: Ash.UUID.generate()
      )

    execution_id = Ecto.UUID.dump!(execution_slot.id)
    key = IssuerKey.from_seed(:binary.copy(<<0x5A>>, 32))
    # --- fixture construction -------------------------------------------------
    {:ok, [source]} = LeaseCapabilities.source_authorizations(assignment, execution_slot, key)

    contract = %{
      contract_id: "serviceradar.sweep.observation",
      contract_version: 1,
      contract_bundle_sha256: :crypto.hash(:sha256, "bundle"),
      registry_epoch: 1,
      registry_snapshot_sha256: :crypto.hash(:sha256, "registry"),
      cost_model_version: 1,
      max_projected_row_count: 10_000,
      max_projected_write_bytes: 20_480_000
    }

    {:ok, production} =
      LeaseCapabilities.production_capability(assignment, [execution_slot], contract, key, now)

    {:production, claims} = production.claims

    batch = %SweepObservationBatchV1{
      execution_id: execution_id,
      sweep_group_id: Ecto.UUID.dump!(group.id),
      execution_shard: 0,
      assignment_epoch: 1,
      batch_sequence: 1,
      observed_at_unix_nano: DateTime.to_unix(now, :nanosecond),
      execution_plan_id: Ecto.UUID.dump!(execution_slot.plan_id),
      execution_plan_sha256: execution_slot.plan_sha256,
      target_range_id: source.scope_id,
      target_range_sha256: source.scope_sha256,
      availability_policy_id: "any-success-v1",
      tested_checks: [
        %SweepTestV1{mode: :SWEEP_MODE_ICMP, protocol: :TRANSPORT_PROTOCOL_ICMP, port: 0},
        %SweepTestV1{mode: :SWEEP_MODE_TCP_CONNECT, protocol: :TRANSPORT_PROTOCOL_TCP, port: 443}
      ],
      configured_mode_bits: 5,
      source: :SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP,
      hosts: [
        %SweepHostObservationV1{
          address: <<192, 0, 2, host_octet>>,
          hostname: "host#{host_octet}.example.com",
          result_mode_bits: 5,
          mode_revision: 1,
          icmp: %SweepIcmpSummaryV1{
            outcome: :SWEEP_MODE_OUTCOME_SUCCESS,
            target_reached: true,
            sent: 1,
            received: 1
          },
          tcp: %SweepTcpSummaryV1{
            outcome: :SWEEP_MODE_OUTCOME_SUCCESS,
            tested_count: 1,
            open_count: 1
          },
          open_ports: [
            %SweepOpenPortV1{tested_check_index: 1, service: "https"}
          ]
        }
      ]
    }

    payload = SweepObservationBatchV1.encode(batch)
    payload_sha256 = :crypto.hash(:sha256, payload)

    producer_context = %EdgeProducerContext{
      origin_kind: :EDGE_ORIGIN_KIND_AGENT,
      origin_principal_id: agent_id,
      producer_instance_id: agent_id,
      producer_assignment_id: Ecto.UUID.dump!(assignment.id),
      authority_epoch: assignment.authority_epoch,
      run_id: Ecto.UUID.dump!(execution_slot.lease_id),
      run_shard: 0,
      scope_id: claims.scope_id,
      scope_sha256: claims.scope_sha256,
      package_id: claims.package_id,
      package_sha256: claims.package_sha256
    }

    record = %EdgeRecordV1{
      event_id: event_id,
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
      source_authorization: source,
      production_capability: production,
      payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
      compression: :EDGE_RECORD_COMPRESSION_NONE,
      encoded_size: byte_size(payload),
      uncompressed_size: byte_size(payload),
      payload_sha256: payload_sha256,
      producer_context: producer_context,
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      network_scope_id: network_scope_id,
      projected_row_count: length(ProjectionRows.sweep(batch)),
      projected_write_bytes: 0,
      cost_model_version: 1,
      payload: payload
    }

    encode_frame(record, batch, slot, opts)
  end

  defp next_frame(frame, batch) do
    payload = SweepObservationBatchV1.encode(batch)

    event_id =
      Ecto.UUID.dump!(
        ExecutionSlots.mint_id(DateTime.from_unix!(batch.observed_at_unix_nano, :nanosecond))
      )

    record = %{
      frame.record
      | event_id: event_id,
        payload: payload,
        encoded_size: byte_size(payload),
        uncompressed_size: byte_size(payload),
        payload_sha256: :crypto.hash(:sha256, payload),
        projected_row_count: length(ProjectionRows.sweep(batch))
    }

    encode_frame(record, batch, %{frame.slot | sequence: frame.slot.sequence + 1})
  end

  defp encode_frame(record, batch, slot, opts \\ []) do
    write_bytes =
      if (record.projected_write_bytes || 0) > 0,
        do: record.projected_write_bytes,
        else: record.projected_row_count * 2_048

    record = %{record | projected_write_bytes: write_bytes}
    record = %{record | semantic_envelope_sha256: SemanticDigest.compute(record)}
    record_bytes = EdgeRecordV1.encode(record)
    assert {:ok, _} = RecordValidate.validate_bytes(record_bytes)
    record_sha256 = :crypto.hash(:sha256, record_bytes)

    {:ok, nats_msg_id} =
      PublicationIdentity.nats_msg_id(slot, record.semantic_envelope_sha256, record_sha256)

    {:ok, delivery_id} = PublicationIdentity.delivery_id(slot)

    delivery_mode = Keyword.get(opts, :delivery_mode, PublicationIdentity.mode_fresh())

    delivery_proof =
      if delivery_mode == PublicationIdentity.mode_fresh(),
        do: nil,
        else: :crypto.hash(:sha256, "delivery-proof")

    {:ok, provenance} =
      PublicationIdentity.transport_provenance(%{
        edge: slot,
        delivery_mode: delivery_mode,
        delivery_proof: delivery_proof,
        record_sha256: record_sha256,
        route_map_version: 1
      })

    headers = %{
      "Nats-Msg-Id" => nats_msg_id,
      "Sr-Edge-Delivery-Id" => delivery_id,
      "Sr-Edge-Transport-Provenance" => provenance
    }

    headers =
      case Keyword.get(opts, :gateway_header) do
        id when is_binary(id) and id != "" -> Map.put(headers, "Sr-Edge-Gateway-Id", id)
        _ -> headers
      end

    %{record_bytes: record_bytes, headers: headers, record: record, batch: batch, slot: slot}
  end

  defp partition!(bytes, actor) do
    case Repo.get(Partition, Ecto.UUID.cast!(bytes)) do
      nil ->
        slug = "edge-#{System.unique_integer([:positive])}"

        Partition
        |> Ash.Changeset.for_create(:create, %{name: slug, slug: slug}, actor: actor)
        |> Ash.create!()

      partition ->
        partition
    end
  end

  defp ensure_agent!(agent_id, partition, actor, capabilities \\ []) do
    if !Repo.get(Agent, agent_id) do
      device =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "device-#{agent_id}",
            ip: "198.51.100.254",
            partition: partition.slug,
            hostname: agent_id
          },
          actor: actor
        )
        |> Ash.create!()

      Agent
      |> Ash.Changeset.for_create(
        :register,
        %{uid: agent_id, device_uid: device.uid, capabilities: capabilities},
        actor: actor
      )
      |> Ash.create!()
    end
  end

  # UUID with a canonical version nibble (byte 6) and RFC-variant bits (byte
  # 8) -- the shape ServiceRadar.Edge.PublicationIdentity's slot validators
  # require, without depending on Ecto.UUID (these are raw 16-byte protobuf
  # `bytes`, not string-form UUIDs).
  defp random_uuid(version) do
    <<b0::binary-6, v::8, b1::8, var::8, b2::binary-7>> = :crypto.strong_rand_bytes(16)
    new_v = Bitwise.bor(Bitwise.bsl(version, 4), Bitwise.band(v, 0x0F))
    new_var = Bitwise.bor(0x80, Bitwise.band(var, 0x3F))
    <<b0::binary, new_v::8, b1::8, new_var::8, b2::binary>>
  end

  defp ledger_row(record) do
    %{rows: [[semantic_envelope_sha256, record_sha256]]} =
      Repo.query!(
        "SELECT semantic_envelope_sha256, record_sha256 FROM platform.event_ledger WHERE network_scope_id = $1::uuid AND event_id = $2::uuid",
        [record.network_scope_id, record.event_id]
      )

    %{semantic_envelope_sha256: semantic_envelope_sha256, record_sha256: record_sha256}
  end

  defp ledger_count(record) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.event_ledger WHERE network_scope_id = $1::uuid AND event_id = $2::uuid",
        [record.network_scope_id, record.event_id]
      )

    count
  end

  defp delivery_slot_row(record) do
    %{rows: [[record_sha256]]} =
      Repo.query!(
        "SELECT record_sha256 FROM platform.edge_delivery_slots WHERE network_scope_id = $1::uuid AND event_id = $2::uuid",
        [record.network_scope_id, record.event_id]
      )

    record_sha256
  end

  defp delivery_slot_count(record) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.edge_delivery_slots WHERE network_scope_id = $1::uuid",
        [record.network_scope_id]
      )

    count
  end

  defp sweep_batch_slot_count(record, batch) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM platform.edge_sweep_batch_slots
        WHERE network_scope_id = $1::uuid AND execution_id = $2::uuid
          AND execution_shard = $3::bigint AND assignment_epoch = $4::bigint
          AND batch_sequence = $5::bigint
        """,
        [
          record.network_scope_id,
          batch.execution_id,
          batch.execution_shard,
          batch.assignment_epoch,
          batch.batch_sequence
        ]
      )

    count
  end

  defp projected_row_keys(record) do
    %{rows: rows} =
      Repo.query!(
        "SELECT row_key FROM platform.edge_sweep_projected_rows WHERE network_scope_id = $1::uuid AND event_id = $2::uuid",
        [record.network_scope_id, record.event_id]
      )

    Enum.map(rows, fn [row_key] -> row_key end)
  end

  defp with_telemetry(events, callback, fun) do
    handler_id = "edge-record-telemetry-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach_many(handler_id, events, callback, nil)

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  # --- database assertions ---------------------------------------------------
end
