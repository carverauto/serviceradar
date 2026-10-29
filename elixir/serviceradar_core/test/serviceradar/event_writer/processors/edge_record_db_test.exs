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

  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.ProjectionRows
  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.RecordValidate
  alias ServiceRadar.Edge.SemanticDigest
  alias Serviceradar.Edge.V1.EdgeOutputContractRef
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.SweepHostObservationV1
  alias Serviceradar.Edge.V1.SweepIcmpSummaryV1
  alias Serviceradar.Edge.V1.SweepObservationBatchV1
  alias Serviceradar.Edge.V1.SweepOpenPortV1
  alias Serviceradar.Edge.V1.SweepTcpSummaryV1
  alias Serviceradar.Edge.V1.SweepTestV1
  alias ServiceRadar.EventWriter.Processors.EdgeRecord
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ExecutionSlots
  alias ServiceRadar.SweepJobs.LeaseCapabilities
  alias ServiceRadar.SweepJobs.ProducerAssignments
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepGroupExecution
  alias ServiceRadar.SweepJobs.SweepHostResult
  alias ServiceRadar.SweepJobs.SweepProducerAssignment

  require Ecto.Query

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
      %{record_bytes: record_bytes, headers: headers, record: record} = build_frame()

      assert {:ok, :inserted} = EdgeRecord.ingest(record_bytes, headers, Repo)

      # A distinct delivery slot (fresh spool/sequence) claiming the SAME
      # event_id, but with different content -> different semantic digest.
      %{record_bytes: reused_event_bytes, headers: reused_event_headers} =
        build_frame(
          network_scope_id: record.network_scope_id,
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
    test "a :before_commit hook that raises rolls the whole transaction back" do
      %{record_bytes: record_bytes, headers: headers, record: record, batch: batch} =
        build_frame()

      hook = fn
        :before_commit, _event_id, _result -> raise "injected rollback"
        _point, _event_id, _result -> :ok
      end

      assert_raise RuntimeError, "injected rollback", fn ->
        EdgeRecord.ingest(record_bytes, headers, Repo, test_hook: hook)
      end

      assert ledger_count(record) == 0
      assert delivery_slot_count(record) == 0
      assert sweep_batch_slot_count(record, batch) == 0
      assert projected_row_keys(record) == []
      assert Repo.get(SweepGroupExecution, Ecto.UUID.cast!(batch.execution_id)) == nil

      # Nothing of the rolled-back attempt survives, so a redelivery commits.
      assert {:ok, :inserted} = EdgeRecord.ingest(record_bytes, headers, Repo)
      assert ledger_count(record) == 1
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

  # --- fixture construction -------------------------------------------------

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

    actor = ServiceRadar.Actors.SystemActor.system(:edge_record_test)
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
      ExecutionSlots.schedule(assignment, now, DateTime.add(now, 900),
        targets: group.static_targets,
        check_set_sha256: HashGrammar.check_set_digest([{1, 1, 0}, {3, 2, 443}]),
        lease_id: Ash.UUID.generate()
      )

    execution_id = Ecto.UUID.dump!(execution_slot.id)
    key = IssuerKey.from_seed(:binary.copy(<<0x5A>>, 32))
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

    encode_frame(record, batch, slot)
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

  defp encode_frame(record, batch, slot) do
    record = %{record | projected_write_bytes: record.projected_row_count * 2_048}
    record = %{record | semantic_envelope_sha256: SemanticDigest.compute(record)}
    record_bytes = EdgeRecordV1.encode(record)
    assert {:ok, _} = RecordValidate.validate_bytes(record_bytes)
    record_sha256 = :crypto.hash(:sha256, record_bytes)

    {:ok, nats_msg_id} =
      PublicationIdentity.nats_msg_id(slot, record.semantic_envelope_sha256, record_sha256)

    {:ok, delivery_id} = PublicationIdentity.delivery_id(slot)

    {:ok, provenance} =
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
      "Sr-Edge-Transport-Provenance" => provenance
    }

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

  defp ensure_agent!(agent_id, partition, actor) do
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
      |> Ash.Changeset.for_create(:register, %{uid: agent_id, device_uid: device.uid},
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

  # --- database assertions ---------------------------------------------------

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
end
