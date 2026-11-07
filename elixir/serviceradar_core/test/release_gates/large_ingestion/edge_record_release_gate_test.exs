defmodule ServiceRadar.EdgeRecordLargeIngestionReleaseGateTest do
  @moduledoc """
  Source-separated heavy release gate for edge-record ingestion.

  This suite qualifies the authoritative edge-record path at 50,000 devices in 1,000-device
  chunks across:
  - the gateway ingest server (`ServiceRadarAgentGateway.EdgeRecordIngestServer`),
  - the bounded publisher pipeline and JetStream publisher (`ServiceRadar.Edge.PublishPipeline`,
    `ServiceRadar.Edge.PublisherPool`, `ServiceRadarAgentGateway.JetStreamPublisher`),
  - the EventWriter edge-record consumer (`ServiceRadar.EventWriter.Processors.EdgeRecord`), and
  - the sync, sweep, mapper, and metrics projectors (`ServiceRadar.Edge.Projectors.SyncPage`,
    `ServiceRadar.Edge.Projectors.SweepObservation`,
    `ServiceRadar.Edge.Projectors.UnleasedSweepResults`,
    `ServiceRadar.Edge.Projectors.MapperDevices`,
    `ServiceRadar.Edge.MetricsBatchProjection`).

  Run via `//elixir/serviceradar_core:large_ingestion_release_gate`.
  """

  use ServiceRadar.DataCase, async: false

  alias Broadway.Message
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ContractBundle
  alias ServiceRadar.Edge.ContractRegistry
  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.OutputContract
  alias ServiceRadar.Edge.OutputGrants
  alias ServiceRadar.Edge.ProjectionRows
  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublisherPool
  alias ServiceRadar.Edge.PublishPipeline
  alias ServiceRadar.Edge.RecordTrust
  alias ServiceRadar.Edge.RecordValidate
  alias ServiceRadar.Edge.SemanticDigest
  alias Serviceradar.Edge.V1.EdgeDeliveryAckV1
  alias Serviceradar.Edge.V1.EdgeDeliveryFrameV1
  alias Serviceradar.Edge.V1.EdgeOutputContractRef
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordClientMessage
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpen
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpenAck
  alias Serviceradar.Edge.V1.EdgeRecordServerMessage
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.MapperDeviceBatchV1
  alias Serviceradar.Edge.V1.MapperDeviceRecordV1
  alias Serviceradar.Edge.V1.MapperSnmpFingerprintV1
  alias Serviceradar.Edge.V1.MapperSnmpSystemFingerprintV1
  alias Serviceradar.Edge.V1.SweepHostObservationV1
  alias Serviceradar.Edge.V1.SweepIcmpSummaryV1
  alias Serviceradar.Edge.V1.SweepObservationBatchV1
  alias Serviceradar.Edge.V1.SweepOpenPortV1
  alias Serviceradar.Edge.V1.SweepPortErrorV1
  alias Serviceradar.Edge.V1.SweepTcpSummaryV1
  alias Serviceradar.Edge.V1.SweepTestV1
  alias Serviceradar.Edge.V1.SyncDeviceRecordV1
  alias Serviceradar.Edge.V1.SyncMetaV1
  alias Serviceradar.Edge.V1.SyncPageBatchV1
  alias Serviceradar.Edge.V1.SyncPopulationReportV1
  alias Serviceradar.Edge.V1.UnleasedSweepHostResultV1
  alias Serviceradar.Edge.V1.UnleasedSweepPortCountV1
  alias Serviceradar.Edge.V1.UnleasedSweepPortResultV1
  alias Serviceradar.Edge.V1.UnleasedSweepResultsBatchV1
  alias ServiceRadar.EventWriter.Processors.EdgeRecord
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Gateway
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ExecutionSlots
  alias ServiceRadar.SweepJobs.LeaseCapabilities
  alias ServiceRadar.SweepJobs.ProducerAssignments
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepGroupExecution
  alias ServiceRadar.SweepJobs.SweepHostResult
  alias ServiceRadarAgentGateway.Config, as: GatewayConfig
  alias ServiceRadarAgentGateway.EdgeRecordIngestServer
  alias ServiceRadarAgentGateway.EdgeRecordTrust
  alias ServiceRadarAgentGateway.JetStreamPublisher

  require Ecto.Query

  @moduletag :integration
  @moduletag :large_ingestion

  @sync_contract "serviceradar.sync.page.batch"
  @sweep_observation_contract "serviceradar.sweep.observation"
  @unleased_sweep_contract "serviceradar.sweep.unleased_results"
  @mapper_devices_contract "serviceradar.mapper.devices.batch"
  @metrics_contract "serviceradar.metrics.batch"

  @bulk_stream "TELEMETRY_EDGE_RECORD_V1_BULK"
  @broker_state_key {__MODULE__, :broker_state}
  @publish_timeout_ms to_timeout(minute: 5)

  defmodule InProcessEdgeRecordBroker do
    @moduledoc false

    alias ServiceRadar.EdgeRecordLargeIngestionReleaseGateTest

    def get(name) do
      case PublisherLane.lanes() do
        lanes when is_list(lanes) ->
          valid_names = Enum.map(lanes, &PublisherLane.connection_name/1)

          if name in valid_names do
            {:ok, self()}
          else
            {:error, {:unknown_connection, name}}
          end
      end
    end

    def request(_conn_pid, subject, payload, opts)
        when is_binary(subject) and is_binary(payload) do
      state = EdgeRecordLargeIngestionReleaseGateTest.broker_state()
      headers = Keyword.fetch!(opts, :headers)

      message = %Message{
        data: payload,
        metadata: %{subject: subject, headers: headers},
        acknowledger: Broadway.NoopAcknowledger.init()
      }

      metrics_request = fn metrics_subject, metrics_body, metrics_opts ->
        send(state.test_pid, {:metrics_republished, metrics_subject, metrics_body, metrics_opts})
        {:ok, %{body: ~s({"stream":"metrics","seq":1})}}
      end

      {:ok, record} = RecordValidate.validate_bytes(payload)

      batch_result =
        if record.output_contract.contract_id == "serviceradar.metrics.batch" do
          case EdgeRecord.ingest(payload, headers, Repo, request: metrics_request) do
            {:ok, _outcome} -> {:ok, 1}
            {:error, _reason} -> {:ok, 0}
          end
        else
          EdgeRecord.process_batch([message])
        end

      case batch_result do
        {:ok, 1} ->
          seq = :atomics.add_get(state.seq_counter, 1, 1)
          {:ok, %{body: Jason.encode!(%{"stream" => state.expected_stream, "seq" => seq})}}

        {:ok, 0} ->
          send(state.test_pid, {:edge_record_refused, subject})
          {:error, :event_writer_refused}

        {:incomplete, _succeeded, [{_failed_message, reason} | _]} ->
          send(state.test_pid, {:edge_record_failed, Exception.message(reason)})
          {:error, :event_writer_failed}
      end
    end
  end

  defmodule CertAdapter do
    @moduledoc false

    def get_cert(:release_gate), do: <<1, 2, 3>>
  end

  defmodule IdentityResolver do
    @moduledoc false

    alias ServiceRadar.EdgeRecordLargeIngestionReleaseGateTest

    def resolve_edge_identity(_cert_der, :agent) do
      state = EdgeRecordLargeIngestionReleaseGateTest.broker_state()

      {:ok,
       %{
         component_id: state.agent_id,
         component_type: :agent,
         partition_id: state.partition_slug,
         installation_trust_id: "release-gate-installation",
         gateway_id: state.gateway_id,
         spiffe_id: nil
       }}
    end
  end

  defmodule Capability do
    @moduledoc false

    def id, do: "edge-records:v1"
    def ready?, do: true
  end

  @gateway_ingest_env [
    :edge_record_ingest_pipelines,
    :edge_record_ingest_identity_resolver,
    :edge_record_ingest_capability,
    :edge_record_ingest_task_supervisor,
    :edge_record_ingest_drain_timeout_ms
  ]

  def broker_state do
    :persistent_term.get(@broker_state_key)
  end

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    prev_async = Application.get_env(:serviceradar_core, :sync_ingestor_async)
    prev_coalesce = Application.get_env(:serviceradar_core, :sync_ingestor_coalesce_ms)
    prev_queue_max = Application.get_env(:serviceradar_core, :sync_ingestor_queue_max_chunks)
    prev_batch_conc = Application.get_env(:serviceradar_core, :sync_ingestor_batch_concurrency)

    prev_gateway_ingest =
      Map.new(@gateway_ingest_env, &{&1, Application.get_env(:serviceradar_agent_gateway, &1)})

    Application.put_env(:serviceradar_core, :sync_ingestor_async, false)

    on_exit(fn ->
      restore_env(:serviceradar_core, :sync_ingestor_async, prev_async)
      restore_env(:serviceradar_core, :sync_ingestor_coalesce_ms, prev_coalesce)
      restore_env(:serviceradar_core, :sync_ingestor_queue_max_chunks, prev_queue_max)
      restore_env(:serviceradar_core, :sync_ingestor_batch_concurrency, prev_batch_conc)

      Enum.each(prev_gateway_ingest, fn {key, value} ->
        restore_env(:serviceradar_agent_gateway, key, value)
      end)

      EdgeRecordTrust.clear()
      ContractRegistry.invalidate()
      :persistent_term.erase({IssuerKey, :key})
      :persistent_term.erase(@broker_state_key)
    end)

    :ok
  end

  @tag timeout: to_timeout(minute: 30), sandbox: :unboxed
  test "large Armis sync pages and companion sweep, mapper, and metrics edge records route through EdgeRecordIngestServer and EventWriter into inventory" do
    Application.put_env(:serviceradar_core, :sync_ingestor_batch_concurrency, 1)

    actor = system_actor()
    now = DateTime.utc_now()
    {key, active_epoch} = ensure_issuer_and_epoch!(now)

    partition = ensure_partition!("default", actor)
    network_scope_id = Ecto.UUID.dump!(partition.id)
    agent_id = "agent-large-ingestion-#{System.unique_integer([:positive])}"
    gateway_id = "gateway-large-ingestion-#{System.unique_integer([:positive])}"
    ensure_agent_and_gateway!(agent_id, gateway_id, actor)

    sync_source = create_armis_source!(partition.slug, agent_id, gateway_id, actor)
    sync_service_id = to_string(sync_source.id)
    sync_run_id = Ecto.UUID.generate()

    {:ok, sync_grant} = OutputGrants.reconcile(agent_id, @sync_contract, partition.id)

    {:ok, unleased_grant} =
      OutputGrants.reconcile(agent_id, @unleased_sweep_contract, partition.id)

    {:ok, mapper_grant} = OutputGrants.reconcile(agent_id, @mapper_devices_contract, partition.id)
    {:ok, metrics_grant} = OutputGrants.reconcile(agent_id, @metrics_contract, partition.id)

    scheduled_sweep =
      setup_scheduled_sweep!(
        partition,
        agent_id,
        [large_ingestion_ip(1), large_ingestion_ip(2)],
        active_epoch,
        key,
        now,
        actor
      )

    install_trust_snapshot!(key)

    harness =
      start_edge_pipeline_harness!(
        agent_id: agent_id,
        partition_slug: partition.slug,
        gateway_id: gateway_id
      )

    total_devices = large_ingestion_device_count()
    chunk_size = large_ingestion_chunk_size()
    total_chunks = ceil_div(total_devices, chunk_size)

    baseline_devices = scalar_count!("SELECT count(*) FROM platform.ocsf_devices", [])
    baseline_ledger_rows = ledger_rows_for_scope(network_scope_id)
    baseline_delivery_slots = delivery_slots_for_scope(network_scope_id)

    baseline_advisory_locks =
      scalar_count!(
        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND database = (SELECT oid FROM pg_database WHERE datname = current_database())",
        []
      )

    sync_spool_id = random_uuid(7)
    {:ok, sync_contract} = OutputContract.from_epoch(active_epoch, {@sync_contract, 1})

    chunk_metrics =
      Enum.map(1..total_chunks, fn chunk_number ->
        start_device = (chunk_number - 1) * chunk_size + 1
        end_device = min(chunk_number * chunk_size, total_devices)

        frame =
          build_sync_page_delivery_frame(
            start_device..end_device,
            chunk_number - 1,
            total_chunks,
            total_devices,
            sync_service_id,
            sync_run_id,
            agent_id,
            gateway_id,
            partition,
            sync_grant,
            sync_contract,
            sync_spool_id,
            chunk_number,
            key,
            now
          )

        acks = stream_single_frame!(frame, sync_spool_id, chunk_number)

        advisory_locks_after_chunk =
          scalar_count!(
            "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND database = (SELECT oid FROM pg_database WHERE datname = current_database())",
            []
          )

        current_devices = scalar_count!("SELECT count(*) FROM platform.ocsf_devices", [])
        expected_devices = baseline_devices + end_device

        assert advisory_locks_after_chunk <= baseline_advisory_locks
        assert current_devices == expected_devices

        %{
          chunk_number: chunk_number,
          advisory_locks: advisory_locks_after_chunk,
          current_devices: current_devices,
          acks: acks
        }
      end)

    # Companion edge-record contracts on the same partition and fleet:
    # 1. Leased scheduled sweep observation (`serviceradar.sweep.observation`)
    sweep_spool_id = random_uuid(7)

    scheduled_sweep_frame =
      build_scheduled_sweep_delivery_frame(
        scheduled_sweep,
        sweep_spool_id,
        1,
        now
      )

    scheduled_sweep_acks = stream_single_frame!(scheduled_sweep_frame, sweep_spool_id, 1)

    # 2. Unleased sweep results (`serviceradar.sweep.unleased_results`)
    {:ok, unleased_contract} =
      OutputContract.from_epoch(active_epoch, {@unleased_sweep_contract, 1})

    unleased_spool_id = random_uuid(7)

    {unleased_frame, unleased_execution_id} =
      build_unleased_sweep_delivery_frame(
        partition,
        agent_id,
        [large_ingestion_ip(3), large_ingestion_ip(4)],
        unleased_grant,
        unleased_contract,
        unleased_spool_id,
        1,
        key,
        now,
        actor
      )

    unleased_acks = stream_single_frame!(unleased_frame, unleased_spool_id, 1)

    # 3. Mapper device discovery batch (`serviceradar.mapper.devices.batch`)
    {:ok, mapper_contract} =
      OutputContract.from_epoch(active_epoch, {@mapper_devices_contract, 1})

    mapper_spool_id = random_uuid(7)

    mapper_frame =
      build_mapper_devices_delivery_frame(
        partition,
        agent_id,
        gateway_id,
        [large_ingestion_ip(5), large_ingestion_ip(6)],
        mapper_grant,
        mapper_contract,
        mapper_spool_id,
        1,
        key,
        now
      )

    mapper_acks = stream_single_frame!(mapper_frame, mapper_spool_id, 1)

    # 4. Agent telemetry metric batch (`serviceradar.metrics.batch`)
    {:ok, metrics_contract} = OutputContract.from_epoch(active_epoch, {@metrics_contract, 1})
    metrics_spool_id = random_uuid(7)

    {metrics_frame, metrics_event_id} =
      build_metrics_delivery_frame(
        partition,
        agent_id,
        metrics_grant,
        metrics_contract,
        metrics_spool_id,
        1,
        key,
        now
      )

    metrics_acks = stream_single_frame!(metrics_frame, metrics_spool_id, 1)

    assert_receive {:metrics_republished, "metrics.sysmon.cpu.cpu_usage_percent", metrics_payload,
                    metrics_opts}

    decoded_metrics = MetricBatch.decode(metrics_payload)
    assert decoded_metrics.resource.agent_id == agent_id
    assert decoded_metrics.ingest_identity.producer_id == agent_id
    assert decoded_metrics.ingress_id == Ecto.UUID.load!(metrics_event_id)

    total_devices_in_db = scalar_count!("SELECT count(*) FROM platform.ocsf_devices", [])

    armis_identifiers =
      scalar_count!(
        "SELECT count(*) FROM platform.device_identifiers WHERE id_type = 'armis_device_id'",
        []
      )

    ip_identifiers =
      scalar_count!(
        "SELECT count(*) FROM platform.ocsf_devices WHERE ip IS NOT NULL AND ip <> ''",
        []
      )

    active_snapshot_records =
      scalar_count!(
        "SELECT COALESCE(sum(device_count), 0)::bigint FROM platform.device_source_snapshots WHERE source_id = $1::uuid AND active = TRUE",
        [Ecto.UUID.dump!(sync_source.id)]
      )

    completed_sync_runs =
      scalar_count!(
        "SELECT count(*) FROM platform.sync_ingest_runs WHERE sync_service_id = $1 AND sync_run_id = $2 AND status = 'completed' AND total_chunks = $3",
        [sync_service_id, sync_run_id, total_chunks]
      )

    scheduled_execution = Repo.get!(SweepGroupExecution, scheduled_sweep.execution_slot.id)
    unleased_execution = Repo.get!(SweepGroupExecution, unleased_execution_id)

    scheduled_host_count =
      scalar_count!(
        "SELECT count(*) FROM platform.sweep_host_results WHERE execution_id = $1::uuid",
        [Ecto.UUID.dump!(scheduled_sweep.execution_slot.id)]
      )

    unleased_host_count =
      scalar_count!(
        "SELECT count(*) FROM platform.sweep_host_results WHERE execution_id = $1::uuid",
        [Ecto.UUID.dump!(unleased_execution_id)]
      )

    mapper_enriched_count =
      scalar_count!(
        "SELECT count(*) FROM platform.ocsf_devices WHERE ip = ANY($1::text[]) AND 'mapper' = ANY(discovery_sources)",
        [[large_ingestion_ip(5), large_ingestion_ip(6)]]
      )

    availability_rows =
      Repo.all(
        Ecto.Query.from(a in DeviceAgentAvailability,
          where: a.agent_id == ^agent_id
        )
      )

    service_state_gateway =
      Repo.one(
        Ecto.Query.from(s in ServiceState,
          where:
            s.agent_id == ^agent_id and s.service_type == "sweep" and
              s.service_name == "network_sweep",
          select: s.gateway_id
        )
      )

    pool_capacity = PublisherPool.capacity(harness.pool)
    expected_records = total_chunks + 4

    summary = %{
      baseline_devices: baseline_devices,
      total_devices: total_devices,
      total_devices_in_db: total_devices_in_db,
      armis_identifiers: armis_identifiers,
      ip_identifiers: ip_identifiers,
      baseline_advisory_locks: baseline_advisory_locks,
      max_advisory_locks: Enum.max(Enum.map(chunk_metrics, & &1.advisory_locks)),
      total_chunks: total_chunks,
      sync_acks: Enum.flat_map(chunk_metrics, & &1.acks),
      companion_acks: scheduled_sweep_acks ++ unleased_acks ++ mapper_acks ++ metrics_acks,
      active_snapshot_records: active_snapshot_records,
      completed_sync_runs: completed_sync_runs,
      ledger_rows_committed: ledger_rows_for_scope(network_scope_id) - baseline_ledger_rows,
      delivery_slots_committed:
        delivery_slots_for_scope(network_scope_id) - baseline_delivery_slots,
      expected_records: expected_records,
      scheduled_execution_status: scheduled_execution.status,
      scheduled_host_count: scheduled_host_count,
      unleased_execution_status: unleased_execution.status,
      unleased_host_count: unleased_host_count,
      mapper_enriched_count: mapper_enriched_count,
      availability_count: length(availability_rows),
      service_state_gateway: service_state_gateway,
      expected_gateway_id: gateway_id,
      outstanding_frames: pool_capacity.outstanding_frames,
      outstanding_bytes: pool_capacity.outstanding_bytes,
      metrics_headers: Keyword.get(metrics_opts, :headers, [])
    }

    assert :ok = qualify_edge_ingestion_run!(summary)
  end

  test "release gate qualification fails closed on rejected records, revoked grants, incomplete sync runs, missed sweep projections, and threshold breaches" do
    actor = system_actor()
    now = DateTime.utc_now()
    {key, active_epoch} = ensure_issuer_and_epoch!(now)

    partition = ensure_partition!("edge-fail-closed-#{System.unique_integer([:positive])}", actor)
    network_scope_id = Ecto.UUID.dump!(partition.id)
    agent_id = "agent-fail-closed-#{System.unique_integer([:positive])}"
    gateway_id = "gateway-fail-closed-#{System.unique_integer([:positive])}"
    ensure_agent_and_gateway!(agent_id, gateway_id, actor)

    sync_source = create_armis_source!(partition.slug, agent_id, gateway_id, actor)
    sync_service_id = to_string(sync_source.id)

    {:ok, sync_grant} = OutputGrants.reconcile(agent_id, @sync_contract, partition.id)

    {:ok, unleased_grant} =
      OutputGrants.reconcile(agent_id, @unleased_sweep_contract, partition.id)

    install_trust_snapshot!(key)

    _harness =
      start_edge_pipeline_harness!(
        agent_id: agent_id,
        partition_slug: partition.slug,
        gateway_id: gateway_id
      )

    {:ok, sync_contract} = OutputContract.from_epoch(active_epoch, {@sync_contract, 1})

    {:ok, unleased_contract} =
      OutputContract.from_epoch(active_epoch, {@unleased_sweep_contract, 1})

    # 1. Permanent rejection at EdgeRecordIngestServer (tampered record_sha256):
    bad_digest_spool = random_uuid(7)

    {valid_unleased_frame, bad_digest_exec_id} =
      build_unleased_sweep_delivery_frame(
        partition,
        agent_id,
        ["192.0.2.20", "192.0.2.21"],
        unleased_grant,
        unleased_contract,
        bad_digest_spool,
        1,
        key,
        now,
        actor
      )

    tampered_frame = %{valid_unleased_frame | record_sha256: :binary.copy(<<0xFF>>, 32)}
    tampered_acks = stream_raw_frame!(tampered_frame, bad_digest_spool, 1)

    assert [
             %EdgeDeliveryAckV1{
               resolved_through_sequence: 1,
               dispositions: [
                 %{
                   sequence: 1,
                   kind: :EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT
                 }
               ]
             }
           ] = tampered_acks

    assert Repo.get(SweepGroupExecution, bad_digest_exec_id) == nil

    assert_raise ExUnit.AssertionError, fn ->
      assert_all_dispositions_authoritative!(tampered_acks, 1)
    end

    # 2. Incomplete Armis sync run (chunk 0 dropped, final chunk 1 arrives alone):
    # ArmisSourceSnapshot.activate fails with :sync_run_incomplete, rolling back the
    # EventWriter ledger commit; the retryable outcome leaves the sequence unacked.
    incomplete_run_id = Ecto.UUID.generate()
    incomplete_spool = random_uuid(7)
    ledger_before_incomplete = ledger_rows_for_scope(network_scope_id)

    incomplete_final_frame =
      build_sync_page_delivery_frame(
        1..2,
        1,
        2,
        4,
        sync_service_id,
        incomplete_run_id,
        agent_id,
        gateway_id,
        partition,
        sync_grant,
        sync_contract,
        incomplete_spool,
        1,
        key,
        now
      )

    incomplete_acks = stream_raw_frame!(incomplete_final_frame, incomplete_spool, 1)

    assert_receive {:edge_record_failed, failure_message}
    assert failure_message =~ ":sync_run_incomplete"

    assert [] = incomplete_acks
    assert ledger_rows_for_scope(network_scope_id) == ledger_before_incomplete

    active_snapshots =
      scalar_count!(
        "SELECT count(*) FROM platform.device_source_snapshots WHERE source_id = $1::uuid AND active = TRUE",
        [Ecto.UUID.dump!(sync_source.id)]
      )

    assert active_snapshots == 0

    assert_raise ExUnit.AssertionError, fn ->
      assert_all_dispositions_authoritative!(incomplete_acks, 1)
    end

    # 3. Late-fenced sweep record projects zero authoritative host rows:
    {late_frame, late_exec_id} =
      build_unleased_sweep_delivery_frame(
        partition,
        agent_id,
        ["192.0.2.30", "192.0.2.31"],
        unleased_grant,
        unleased_contract,
        random_uuid(7),
        1,
        key,
        now,
        actor
      )

    late_headers =
      build_test_headers(
        late_frame,
        network_scope_id,
        agent_id,
        gateway_id,
        PublicationIdentity.mode_late_fenced()
      )

    assert {:ok, :inserted} = EdgeRecord.ingest(late_frame.record_bytes, late_headers, Repo)
    assert Repo.get(SweepGroupExecution, late_exec_id) == nil

    # 4. Revoked standing grant at EventWriter is refused with :output_grant_not_current
    # and its sequence is left unacked by EdgeRecordIngestServer:
    revoked_spool = random_uuid(7)

    {revoked_frame, revoked_exec_id} =
      build_unleased_sweep_delivery_frame(
        partition,
        agent_id,
        ["192.0.2.40", "192.0.2.41"],
        unleased_grant,
        unleased_contract,
        revoked_spool,
        1,
        key,
        now,
        actor
      )

    assert {:ok, _revoked_count} = OutputGrants.revoke_agent(agent_id)
    ledger_before_revoked = ledger_rows_for_scope(network_scope_id)
    revoked_acks = stream_raw_frame!(revoked_frame, revoked_spool, 1)

    assert_receive {:edge_record_refused, revoked_subject}
    assert revoked_subject =~ ~r/\Atelemetry\.edge-record\.v1\.bulk\.p\d{2}\z/

    assert [] = revoked_acks
    assert ledger_rows_for_scope(network_scope_id) == ledger_before_revoked
    assert Repo.get(SweepGroupExecution, revoked_exec_id) == nil

    assert scalar_count!(
             "SELECT count(*) FROM platform.sweep_host_results WHERE execution_id = $1::uuid",
             [Ecto.UUID.dump!(revoked_exec_id)]
           ) == 0

    # 5. Threshold and invariant breaches fail qualify_edge_ingestion_run!/1:
    passing_ack = %EdgeDeliveryAckV1{
      spool_id: random_uuid(7),
      resolved_through_sequence: 1,
      dispositions: [
        %{
          sequence: 1,
          kind: :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE
        }
      ]
    }

    valid_summary = %{
      baseline_devices: 0,
      total_devices: 50_000,
      total_devices_in_db: 50_000,
      armis_identifiers: 50_000,
      ip_identifiers: 50_000,
      baseline_advisory_locks: 0,
      max_advisory_locks: 0,
      total_chunks: 1,
      sync_acks: [passing_ack],
      companion_acks: [passing_ack, passing_ack, passing_ack, passing_ack],
      active_snapshot_records: 50_000,
      completed_sync_runs: 1,
      ledger_rows_committed: 5,
      delivery_slots_committed: 5,
      expected_records: 5,
      scheduled_execution_status: :completed,
      scheduled_host_count: 2,
      unleased_execution_status: :completed,
      unleased_host_count: 2,
      mapper_enriched_count: 2,
      availability_count: 4,
      service_state_gateway: gateway_id,
      expected_gateway_id: gateway_id,
      outstanding_frames: 0,
      outstanding_bytes: 0,
      metrics_headers: [{"Nats-Msg-Id", "0197f8a0-0000-7000-8000-000000000001"}]
    }

    assert :ok = qualify_edge_ingestion_run!(valid_summary)

    for mutation <- [
          %{total_devices_in_db: 49_999},
          %{armis_identifiers: 49_999},
          %{ip_identifiers: 49_999},
          %{max_advisory_locks: 1},
          %{active_snapshot_records: 0},
          %{completed_sync_runs: 0},
          %{ledger_rows_committed: 4},
          %{delivery_slots_committed: 4},
          %{scheduled_execution_status: :running},
          %{scheduled_host_count: 0},
          %{unleased_execution_status: :failed},
          %{unleased_host_count: 0},
          %{mapper_enriched_count: 0},
          %{availability_count: 0},
          %{service_state_gateway: nil},
          %{outstanding_frames: 1},
          %{outstanding_bytes: 1_024},
          %{metrics_headers: []}
        ] do
      assert_raise ExUnit.AssertionError, fn ->
        qualify_edge_ingestion_run!(Map.merge(valid_summary, mutation))
      end
    end
  end

  defp qualify_edge_ingestion_run!(summary) do
    assert summary.max_advisory_locks <= summary.baseline_advisory_locks
    assert summary.total_devices_in_db == summary.baseline_devices + summary.total_devices
    assert summary.armis_identifiers == summary.total_devices
    assert summary.ip_identifiers >= summary.total_devices
    assert summary.active_snapshot_records == summary.total_devices
    assert summary.completed_sync_runs == 1
    assert summary.ledger_rows_committed == summary.expected_records
    assert summary.delivery_slots_committed == summary.expected_records
    assert summary.scheduled_execution_status == :completed
    assert summary.scheduled_host_count >= 2
    assert summary.unleased_execution_status == :completed
    assert summary.unleased_host_count >= 2
    assert summary.mapper_enriched_count >= 2
    assert summary.availability_count >= 2
    assert summary.service_state_gateway == summary.expected_gateway_id
    assert summary.outstanding_frames == 0
    assert summary.outstanding_bytes == 0
    assert List.keyfind(summary.metrics_headers, "Nats-Msg-Id", 0)

    assert_all_dispositions_authoritative!(summary.sync_acks, summary.total_chunks)
    assert_all_dispositions_authoritative!(summary.companion_acks, 4)

    :ok
  end

  defp assert_all_dispositions_authoritative!(acks, expected_count) do
    assert length(acks) == expected_count

    Enum.each(acks, fn %EdgeDeliveryAckV1{} = ack ->
      assert ack.resolved_through_sequence >= 1
      assert ack.dispositions != []

      Enum.each(ack.dispositions, fn disposition ->
        assert disposition.kind == :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE
      end)
    end)
  end

  defp start_edge_pipeline_harness!(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    partition_slug = Keyword.fetch!(opts, :partition_slug)
    gateway_id = Keyword.fetch!(opts, :gateway_id)

    GatewayConfig.setup(gateway_id: gateway_id, domain: partition_slug)

    :persistent_term.put(@broker_state_key, %{
      test_pid: self(),
      seq_counter: :atomics.new(1, signed: false),
      expected_stream: @bulk_stream,
      agent_id: agent_id,
      partition_slug: partition_slug,
      gateway_id: gateway_id
    })

    pool =
      start_supervised!(
        {PublisherPool,
         name: nil, class: :bulk, frame_credits: 64, byte_credits: 64 * 1_024 * 1_024},
        id: make_ref()
      )

    assert {:ok, _generation} = PublisherPool.register_transport(pool, self())

    publish_tasks = start_supervised!({Task.Supervisor, []}, id: make_ref())
    stream_tasks = start_supervised!({Task.Supervisor, []}, id: make_ref())

    pipeline =
      start_supervised!(
        {PublishPipeline,
         name: nil,
         class: :bulk,
         pool: pool,
         task_supervisor: publish_tasks,
         publisher: &JetStreamPublisher.publish_record/2,
         publish_opts: [
           connection: InProcessEdgeRecordBroker,
           receive_timeout: @publish_timeout_ms
         ],
         max_inflight: 1,
         max_queue: 256},
        id: make_ref()
      )

    put_gateway_env(:edge_record_ingest_pipelines, %{bulk: pipeline})
    put_gateway_env(:edge_record_ingest_identity_resolver, IdentityResolver)
    put_gateway_env(:edge_record_ingest_capability, Capability)
    put_gateway_env(:edge_record_ingest_task_supervisor, stream_tasks)
    put_gateway_env(:edge_record_ingest_drain_timeout_ms, @publish_timeout_ms)

    %{pool: pool, pipeline: pipeline}
  end

  defp put_gateway_env(key, value),
    do: Application.put_env(:serviceradar_agent_gateway, key, value)

  defp stream_single_frame!(%EdgeDeliveryFrameV1{} = frame, spool_id, sequence) do
    acks = stream_raw_frame!(frame, spool_id, sequence)

    assert [
             %EdgeDeliveryAckV1{
               spool_id: ^spool_id,
               resolved_through_sequence: ^sequence,
               dispositions: [
                 %{
                   sequence: ^sequence,
                   kind: :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE
                 }
               ]
             }
           ] = acks

    acks
  end

  defp stream_raw_frame!(%EdgeDeliveryFrameV1{} = frame, spool_id, sequence) do
    messages = [
      %EdgeRecordClientMessage{
        payload:
          {:lane_open,
           %EdgeRecordLaneOpen{
             spool_id: spool_id,
             route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
             traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
             first_unresolved_sequence: sequence,
             requested_frame_credits: 1,
             requested_byte_credits: byte_size(frame.record_bytes)
           }}
      },
      %EdgeRecordClientMessage{payload: {:delivery_frame, frame}}
    ]

    stream = %{adapter: CertAdapter, payload: :release_gate, test_pid: self()}
    assert :ok = EdgeRecordIngestServer.stream(messages, stream)

    assert [
             %EdgeRecordServerMessage{
               payload: {:lane_open_ack, %EdgeRecordLaneOpenAck{spool_id: ^spool_id}}
             }
             | rest
           ] = drain_server_messages()

    for %EdgeRecordServerMessage{payload: {:ack, ack}} <- rest, do: ack
  end

  defp drain_server_messages(acc \\ []) do
    receive do
      {:edge_record_stream_reply, msg} -> drain_server_messages([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp build_sync_page_delivery_frame(
         device_range,
         chunk_index,
         total_chunks,
         total_devices,
         sync_service_id,
         sync_run_id,
         agent_id,
         gateway_id,
         partition,
         grant,
         contract,
         spool_id,
         sequence,
         key,
         now
       ) do
    observed_nano = DateTime.to_unix(now, :nanosecond)
    is_final = chunk_index == total_chunks - 1

    population =
      if is_final do
        %SyncPopulationReportV1{
          raw_rows: total_devices,
          excluded_rows: 0,
          invalid_rows: 0,
          valid_occurrences: total_devices,
          distinct_source_ids: total_devices,
          duplicate_occurrences: 0,
          conflicting_duplicate_ids: 0
        }
      end

    devices =
      Enum.map(device_range, fn device_number ->
        source_device_id = Integer.to_string(device_number)

        %SyncDeviceRecordV1{
          uid: source_device_id,
          ip: large_ingestion_ip(device_number),
          hostname: "armis-host-#{device_number}.example.com",
          source: "armis",
          timestamp_unix_nano: observed_nano,
          is_available: true,
          agent_id: agent_id,
          gateway_id: gateway_id,
          partition: partition.slug,
          metadata: %{
            "source_device_id" => source_device_id,
            "armis_device_id" => source_device_id,
            "integration_id" => source_device_id,
            "integration_type" => "armis",
            "sync_service_id" => sync_service_id
          }
        }
      end)

    batch = %SyncPageBatchV1{
      sync_meta: %SyncMetaV1{
        sync_service_id: sync_service_id,
        sync_run_id: sync_run_id,
        chunk_index: chunk_index,
        total_chunks: total_chunks,
        is_final: is_final,
        total_devices: total_devices,
        population: population
      },
      devices: devices
    }

    payload = SyncPageBatchV1.encode(batch)
    production = OutputGrants.production_capability(grant, contract, key, now)

    record =
      build_standing_grant_record(
        production,
        agent_id,
        Ecto.UUID.dump!(partition.id),
        payload,
        length(devices),
        now
      )

    wrap_delivery_frame(record, spool_id, sequence)
  end

  defp setup_scheduled_sweep!(partition, agent_id, targets, active_epoch, key, now, actor) do
    group =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "edge-release-gate-scheduled-#{System.unique_integer([:positive])}",
          partition: partition.slug,
          enabled: false,
          interval: "15m",
          agent_ids: [agent_id],
          static_targets: targets,
          sweep_modes: ["icmp", "tcp_connect"],
          ports: [443]
        },
        actor: actor
      )
      |> Ash.create!()

    {:ok, assignment} = ProducerAssignments.ensure(group.id, agent_id, partition.id)

    {:ok, execution_slot} =
      ExecutionSlots.schedule(assignment, now, DateTime.shift(now, minute: 15),
        targets: targets,
        check_set_sha256: HashGrammar.check_set_digest([{1, 1, 0}, {3, 2, 443}]),
        lease_id: Ash.UUID.generate()
      )

    {:ok, contract} = OutputContract.from_epoch(active_epoch, {@sweep_observation_contract, 1})
    {:ok, [source]} = LeaseCapabilities.source_authorizations(assignment, execution_slot, key)

    {:ok, production} =
      LeaseCapabilities.production_capability(assignment, [execution_slot], contract, key, now)

    %{
      group: group,
      assignment: assignment,
      execution_slot: execution_slot,
      source: source,
      production: production,
      targets: targets
    }
  end

  defp build_scheduled_sweep_delivery_frame(scheduled_sweep, spool_id, sequence, now) do
    %{
      group: group,
      assignment: assignment,
      execution_slot: execution_slot,
      source: source,
      production: production,
      targets: targets
    } = scheduled_sweep

    {:production, claims} = production.claims

    hosts =
      targets
      |> Enum.with_index(1)
      |> Enum.map(fn {ip_string, index} ->
        %SweepHostObservationV1{
          address: ipv4_bytes!(ip_string),
          hostname: "scheduled-host-#{index}.example.com",
          result_mode_bits: 5,
          mode_revision: 1,
          icmp: %SweepIcmpSummaryV1{
            outcome: :SWEEP_MODE_OUTCOME_SUCCESS,
            target_reached: true,
            sent: 1,
            received: 1,
            round_trip_micro: 1_200
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
      end)

    batch = %SweepObservationBatchV1{
      execution_id: Ecto.UUID.dump!(execution_slot.id),
      sweep_group_id: Ecto.UUID.dump!(group.id),
      execution_shard: 0,
      assignment_epoch: assignment.authority_epoch,
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
      hosts: hosts
    }

    payload = SweepObservationBatchV1.encode(batch)
    row_count = length(ProjectionRows.sweep(batch))

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
      source_authorization: source,
      production_capability: production,
      payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
      compression: :EDGE_RECORD_COMPRESSION_NONE,
      encoded_size: byte_size(payload),
      uncompressed_size: byte_size(payload),
      payload_sha256: :crypto.hash(:sha256, payload),
      producer_context: %EdgeProducerContext{
        origin_kind: :EDGE_ORIGIN_KIND_AGENT,
        origin_principal_id: assignment.agent_id,
        producer_instance_id: assignment.agent_id,
        producer_assignment_id: Ecto.UUID.dump!(assignment.id),
        authority_epoch: assignment.authority_epoch,
        run_id: Ecto.UUID.dump!(execution_slot.lease_id),
        run_shard: 0,
        scope_id: claims.scope_id,
        scope_sha256: claims.scope_sha256,
        package_id: claims.package_id,
        package_sha256: claims.package_sha256
      },
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      network_scope_id: Ecto.UUID.dump!(assignment.network_scope_id),
      projected_row_count: row_count,
      projected_write_bytes: row_count * 2_048,
      cost_model_version: 1,
      payload: payload
    }

    wrap_delivery_frame(record, spool_id, sequence)
  end

  defp build_unleased_sweep_delivery_frame(
         partition,
         agent_id,
         targets,
         grant,
         contract,
         spool_id,
         sequence,
         key,
         now,
         actor
       ) do
    group =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "edge-release-gate-unleased-#{System.unique_integer([:positive])}",
          partition: partition.slug,
          enabled: false,
          interval: "15m",
          agent_ids: [agent_id],
          static_targets: targets,
          sweep_modes: ["icmp", "tcp_connect"],
          ports: [22, 443]
        },
        actor: actor
      )
      |> Ash.create!()

    execution_id = Ecto.UUID.generate()
    production = OutputGrants.production_capability(grant, contract, key, now)

    [first_ip, second_ip] = Enum.map(targets, &ipv4_bytes!/1)

    batch = %UnleasedSweepResultsBatchV1{
      execution_id: Ecto.UUID.dump!(execution_id),
      sweep_group_id: Ecto.UUID.dump!(group.id),
      network_cidr: "10.250.0.0/24",
      last_sweep_unix_nano: DateTime.to_unix(now, :nanosecond),
      batch_completed_at_unix_nano: DateTime.to_unix(now, :nanosecond),
      chunk_index: 0,
      total_chunks: 1,
      is_final: true,
      expected_total_hosts: 2,
      available_hosts: 2,
      tested_checks: [
        %SweepTestV1{mode: :SWEEP_MODE_ICMP, protocol: :TRANSPORT_PROTOCOL_ICMP},
        %SweepTestV1{mode: :SWEEP_MODE_TCP_CONNECT, protocol: :TRANSPORT_PROTOCOL_TCP, port: 22},
        %SweepTestV1{mode: :SWEEP_MODE_TCP_CONNECT, protocol: :TRANSPORT_PROTOCOL_TCP, port: 443}
      ],
      port_counts: [
        %UnleasedSweepPortCountV1{port: 22, available: 2},
        %UnleasedSweepPortCountV1{port: 443, available: 1}
      ],
      hosts: [
        %SweepHostObservationV1{
          address: first_ip,
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
          address: second_ip,
          icmp: %SweepIcmpSummaryV1{
            target_reached: true,
            round_trip_micro: 1_800,
            packet_loss_pct: 0.0
          },
          open_ports: [
            %SweepOpenPortV1{
              tested_check_index: 1,
              response_time_nano: 2_100_000,
              service: "ssh"
            },
            %SweepOpenPortV1{
              tested_check_index: 2,
              response_time_nano: 2_400_000,
              service: "https"
            }
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
          available: true,
          response_time_nano: 1_800_000,
          icmp_round_trip_nano: 1_800_000,
          first_seen: "2026-06-01T11:00:00Z",
          last_seen: "2026-06-01T12:00:00Z",
          port_results: [
            %UnleasedSweepPortResultV1{
              port: 22,
              available: true,
              response_time_nano: 2_100_000,
              service: "ssh"
            },
            %UnleasedSweepPortResultV1{
              port: 443,
              available: true,
              response_time_nano: 2_400_000,
              service: "https"
            }
          ]
        }
      ]
    }

    payload = UnleasedSweepResultsBatchV1.encode(batch)

    record =
      build_standing_grant_record(
        production,
        agent_id,
        Ecto.UUID.dump!(partition.id),
        payload,
        length(batch.hosts),
        now
      )

    {wrap_delivery_frame(record, spool_id, sequence), execution_id}
  end

  defp build_mapper_devices_delivery_frame(
         partition,
         agent_id,
         gateway_id,
         ips,
         grant,
         contract,
         spool_id,
         sequence,
         key,
         now
       ) do
    observed_nano = DateTime.to_unix(now, :nanosecond)

    devices =
      ips
      |> Enum.with_index(1)
      |> Enum.map(fn {ip, index} ->
        %MapperDeviceRecordV1{
          ip: ip,
          hostname: "mapper-enriched-#{index}.example.com",
          source: "mapper",
          timestamp_unix_nano: observed_nano,
          is_available: true,
          agent_id: agent_id,
          gateway_id: gateway_id,
          partition: partition.slug,
          metadata: %{"sys_descr" => "Synthetic Edge SwitchOS"},
          snmp_fingerprint: %MapperSnmpFingerprintV1{
            system: %MapperSnmpSystemFingerprintV1{
              sys_name: "mapper-enriched-#{index}",
              sys_descr: "Synthetic Edge SwitchOS",
              sys_object_id: ".1.3.6.1.4.1.55555.1",
              ip_forwarding: 1
            }
          }
        }
      end)

    batch = %MapperDeviceBatchV1{
      agent_id: agent_id,
      partition: partition.slug,
      devices: devices
    }

    payload = MapperDeviceBatchV1.encode(batch)
    production = OutputGrants.production_capability(grant, contract, key, now)

    record =
      build_standing_grant_record(
        production,
        agent_id,
        Ecto.UUID.dump!(partition.id),
        payload,
        length(devices),
        now
      )

    wrap_delivery_frame(record, spool_id, sequence)
  end

  defp build_metrics_delivery_frame(
         partition,
         agent_id,
         grant,
         contract,
         spool_id,
         sequence,
         key,
         now
       ) do
    observed_nano = DateTime.to_unix(now, :nanosecond)

    batch = %MetricBatch{
      schema_version: "serviceradar.metric.v1",
      resource: %MetricResource{agent_id: "spoofed-agent", service_name: "sysmon"},
      ingest_identity: %IngestIdentity{source: "sysmon-metrics", producer_kind: "agent-sysmon"},
      metrics: [
        %Metric{
          name: "cpu_usage_percent",
          metric_type: "cpu",
          kind: :METRIC_KIND_GAUGE,
          points: [%MetricPoint{value: 14.5, observed_at_unix_nano: observed_nano}]
        },
        %Metric{
          name: "cpu_usage_percent",
          metric_type: "cpu",
          kind: :METRIC_KIND_GAUGE,
          points: [%MetricPoint{value: 18.0, observed_at_unix_nano: observed_nano}]
        }
      ]
    }

    payload = MetricBatch.encode(batch)
    production = OutputGrants.production_capability(grant, contract, key, now)

    record =
      build_standing_grant_record(
        production,
        agent_id,
        Ecto.UUID.dump!(partition.id),
        payload,
        length(batch.metrics),
        now
      )

    {wrap_delivery_frame(record, spool_id, sequence), record.event_id}
  end

  defp build_standing_grant_record(
         production,
         agent_id,
         network_scope_id,
         payload,
         row_count,
         now
       ) do
    {:production, claims} = production.claims

    %EdgeRecordV1{
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
      network_scope_id: network_scope_id,
      projected_row_count: row_count,
      projected_write_bytes: max(row_count * 2_048, byte_size(payload)),
      cost_model_version: 1,
      payload: payload
    }
  end

  defp wrap_delivery_frame(%EdgeRecordV1{} = record, spool_id, sequence) do
    record = %{record | semantic_envelope_sha256: SemanticDigest.compute(record)}
    record_bytes = EdgeRecordV1.encode(record)
    assert {:ok, _validated} = RecordValidate.validate_bytes(record_bytes)

    %EdgeDeliveryFrameV1{
      spool_id: spool_id,
      sequence: sequence,
      record_bytes: record_bytes,
      record_sha256: :crypto.hash(:sha256, record_bytes)
    }
  end

  defp build_test_headers(
         %EdgeDeliveryFrameV1{} = frame,
         network_scope_id,
         agent_id,
         gateway_id,
         delivery_mode
       ) do
    {:ok, decoded} = RecordValidate.validate_bytes(frame.record_bytes)

    slot = %{
      network_scope_id: network_scope_id,
      authenticated_agent_id: agent_id,
      spool_id: frame.spool_id,
      sequence: frame.sequence
    }

    {:ok, nats_msg_id} =
      PublicationIdentity.nats_msg_id(slot, decoded.semantic_envelope_sha256, frame.record_sha256)

    {:ok, delivery_id} = PublicationIdentity.delivery_id(slot)

    delivery_proof =
      if delivery_mode == PublicationIdentity.mode_fresh() do
        nil
      else
        :crypto.hash(:sha256, "late-fenced-delivery-proof")
      end

    {:ok, provenance} =
      PublicationIdentity.transport_provenance(%{
        edge: slot,
        delivery_mode: delivery_mode,
        delivery_proof: delivery_proof,
        record_sha256: frame.record_sha256,
        route_map_version: 1
      })

    %{
      "Nats-Msg-Id" => nats_msg_id,
      "Sr-Edge-Delivery-Id" => delivery_id,
      "Sr-Edge-Transport-Provenance" => provenance,
      "Sr-Edge-Gateway-Id" => gateway_id
    }
  end

  defp install_trust_snapshot!(key) do
    {:ok, trust_doc} = RecordTrust.snapshot(key)
    assert :ok = EdgeRecordTrust.install(trust_doc)
  end

  defp ensure_issuer_and_epoch!(now) do
    {:ok, key} = IssuerKey.ensure_stored()
    :persistent_term.put({IssuerKey, :key}, key)
    ContractRegistry.invalidate()
    {:ok, %{role: :active}} = ContractRegistry.ensure_epoch(ContractBundle.local(), key, now)
    {:ok, registry_view} = ContractRegistry.view(key)
    {:ok, active_epoch} = ContractRegistry.active_epoch(registry_view)
    {key, active_epoch}
  end

  defp ensure_partition!(slug, actor) do
    case Partition.get_by_slug(slug, actor: actor) do
      {:ok, %Partition{} = partition} ->
        partition

      _ ->
        Partition
        |> Ash.Changeset.for_create(:create, %{name: slug, slug: slug}, actor: actor)
        |> Ash.create!()
    end
  end

  defp ensure_agent_and_gateway!(agent_id, gateway_id, actor) do
    Gateway
    |> Ash.Changeset.for_create(:register, %{id: gateway_id}, actor: actor)
    |> Ash.create!(domain: ServiceRadar.Infrastructure)

    Agent
    |> Ash.Changeset.for_create(:register, %{uid: agent_id, name: agent_id}, actor: actor)
    |> Ash.create!()

    Repo.query!("UPDATE platform.ocsf_agents SET gateway_id = $1 WHERE uid = $2", [
      gateway_id,
      agent_id
    ])
  end

  defp create_armis_source!(partition_slug, agent_id, gateway_id, actor) do
    IntegrationSource
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "armis-edge-release-gate-#{System.unique_integer([:positive])}",
        source_type: :armis,
        endpoint: "https://armis.example.com/api/v1",
        partition: partition_slug,
        agent_id: agent_id,
        gateway_id: gateway_id
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp system_actor do
    SystemActor.system(:edge_record_large_ingestion_release_gate_test)
  end

  defp large_ingestion_device_count do
    env_positive_integer("SERVICERADAR_LARGE_INGESTION_DEVICE_COUNT", 50_000)
  end

  defp large_ingestion_chunk_size do
    env_positive_integer("SERVICERADAR_LARGE_INGESTION_CHUNK_SIZE", 1_000)
  end

  defp env_positive_integer(var, default) do
    case System.get_env(var) do
      nil ->
        default

      raw ->
        case Integer.parse(String.trim(raw)) do
          {value, ""} when value > 0 -> value
          _ -> default
        end
    end
  end

  defp ceil_div(left, right) when is_integer(left) and is_integer(right) and right > 0 do
    div(left + right - 1, right)
  end

  defp large_ingestion_ip(device_number) when is_integer(device_number) and device_number > 0 do
    zero_based = device_number - 1
    second_octet = 250 + div(zero_based, 65_025)
    rem_after_second = rem(zero_based, 65_025)
    third_octet = div(rem_after_second, 255)
    fourth_octet = rem(rem_after_second, 255) + 1
    "10.#{second_octet}.#{third_octet}.#{fourth_octet}"
  end

  defp ipv4_bytes!(ip) when is_binary(ip) do
    {:ok, {a, b, c, d}} = :inet.parse_ipv4strict_address(String.to_charlist(ip))
    <<a, b, c, d>>
  end

  defp random_uuid(version) do
    <<b0::binary-6, v::8, b1::8, var::8, b2::binary-7>> = :crypto.strong_rand_bytes(16)
    new_v = Bitwise.bor(Bitwise.bsl(version, 4), Bitwise.band(v, 0x0F))
    new_var = Bitwise.bor(0x80, Bitwise.band(var, 0x3F))
    <<b0::binary, new_v::8, b1::8, new_var::8, b2::binary>>
  end

  defp ledger_rows_for_scope(network_scope_id) do
    scalar_count!(
      "SELECT count(*) FROM platform.event_ledger WHERE network_scope_id = $1::uuid",
      [network_scope_id]
    )
  end

  defp delivery_slots_for_scope(network_scope_id) do
    scalar_count!(
      "SELECT count(*) FROM platform.edge_delivery_slots WHERE network_scope_id = $1::uuid",
      [network_scope_id]
    )
  end

  defp scalar_count!(sql, params) do
    %Postgrex.Result{rows: [[count]]} = Repo.query!(sql, params)
    count
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
