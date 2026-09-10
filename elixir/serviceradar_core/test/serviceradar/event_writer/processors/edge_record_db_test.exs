defmodule ServiceRadar.EventWriter.Processors.EdgeRecordDbTest do
  @moduledoc """
  Real-Postgres coverage for the idempotent CNPG transaction (task 0.12 group
  C): a forced redelivery of the same stored frame must be a no-op replay
  (never a duplicate row), and a conflicting frame that reuses the same
  delivery slot with different bytes must fail with a distinct outcome while
  leaving the first binding immutable.

  Every fixture here is synthetic/invented (random UUIDs, `192.0.2.0/24`
  TEST-NET-1 addresses, made-up ASCII identifiers) -- there is no live
  gRPC/JetStream path yet (separate, parallel tasks), so this drives
  `EdgeRecord.ingest/3` directly with a real wire-encoded `EdgeRecordV1`
  frame and real transport-provenance headers, the same way every other
  EventWriter processor is unit-tested directly against `parse_message/1`.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Edge.ProjectionRows
  alias ServiceRadar.Edge.PublicationIdentity
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.SweepHostObservationV1
  alias Serviceradar.Edge.V1.SweepIcmpSummaryV1
  alias Serviceradar.Edge.V1.SweepObservationBatchV1
  alias Serviceradar.Edge.V1.SweepOpenPortV1
  alias Serviceradar.Edge.V1.SweepTestV1
  alias ServiceRadar.EventWriter.Processors.EdgeRecord
  alias ServiceRadar.Repo

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

  # --- fixture construction -------------------------------------------------

  defp build_frame(opts \\ []) do
    slot_override = Keyword.get(opts, :slot)

    {network_scope_id, agent_id} =
      case slot_override do
        %{network_scope_id: ns, authenticated_agent_id: agent} ->
          {ns, agent}

        nil ->
          {Keyword.get_lazy(opts, :network_scope_id, fn -> random_uuid(4) end),
           Keyword.get(opts, :agent_id, "agent-01")}
      end

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

    event_id = Keyword.get_lazy(opts, :event_id, fn -> random_uuid(7) end)
    execution_id = Keyword.get_lazy(opts, :execution_id, fn -> random_uuid(7) end)
    host_octet = Keyword.get(opts, :host_octet, 1)

    batch = %SweepObservationBatchV1{
      execution_id: execution_id,
      sweep_group_id: random_uuid(7),
      execution_shard: 0,
      assignment_epoch: 1,
      batch_sequence: 1,
      observed_at_unix_nano: 1_757_000_000_000_000_000,
      tested_checks: [
        %SweepTestV1{mode: :SWEEP_MODE_ICMP, protocol: :TRANSPORT_PROTOCOL_ICMP, port: 0}
      ],
      configured_mode_bits: 1,
      source: :SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP,
      hosts: [
        %SweepHostObservationV1{
          address: <<192, 0, 2, host_octet>>,
          hostname: "host#{host_octet}.example.com",
          result_mode_bits: 1,
          mode_revision: 1,
          icmp: %SweepIcmpSummaryV1{
            outcome: :SWEEP_MODE_OUTCOME_SUCCESS,
            target_reached: true,
            sent: 1,
            received: 1
          },
          open_ports: [
            %SweepOpenPortV1{tested_check_index: 0, service: "test"}
          ]
        }
      ]
    }

    payload = SweepObservationBatchV1.encode(batch)
    payload_sha256 = :crypto.hash(:sha256, payload)
    semantic_envelope_sha256 = :crypto.hash(:sha256, [payload, event_id])

    producer_context = %EdgeProducerContext{
      origin_kind: :EDGE_ORIGIN_KIND_AGENT,
      origin_principal_id: agent_id,
      producer_instance_id: random_uuid(7),
      run_id: random_uuid(7),
      run_shard: 0,
      scope_id: network_scope_id,
      package_id: "edge-record-db-test"
    }

    record = %EdgeRecordV1{
      event_id: event_id,
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
      semantic_envelope_sha256: semantic_envelope_sha256,
      payload: payload
    }

    record_bytes = EdgeRecordV1.encode(record)
    record_sha256 = :crypto.hash(:sha256, record_bytes)

    {:ok, nats_msg_id} =
      PublicationIdentity.nats_msg_id(slot, semantic_envelope_sha256, record_sha256)

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
