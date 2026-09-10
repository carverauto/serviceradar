defmodule ServiceRadar.EventWriter.Processors.EdgeRecord do
  @moduledoc """
  EventWriter processor for the durable edge-record wire format (task 0.12 /
  5.2, minimum slice only).

  This is the CNPG side of the idempotent-transaction acceptance group: given
  an already wire-decoded `EdgeRecordV1` frame (received via
  `EdgeRecordIngestService.Stream` -> gateway -> JetStream, none of which
  exist yet in this repository -- that gRPC server and Go sender are separate,
  parallel tasks), it runs ONE database transaction that:

    1. binds the frozen `edge_slot` coordinate immutably to `record_sha256`
       (`ServiceRadar.Edge.PublicationIdentity`'s already-tested slot/header
       codec) -- a TRANSPORT-integrity check, first, per
       design.md's ordered EventWriter pipeline (slot binding precedes every
       terminal decision);
    2. looks up the `event_ledger` row for `(network_scope_id, event_id)` and
       classifies the delivery as a fresh insert, a replay (same
       `semantic_envelope_sha256`), or `EVENT_ID_CONFLICT` (different digest);
    3. does the same replay/conflict classification for the
       `SweepObservationBatchV1` batch coordinate already carried on the wire
       (`execution_id`, `execution_shard`, `assignment_epoch`,
       `batch_sequence`) against `edge_sweep_batch_slots`;
    4. projects the minimal atomic domain-row artifact by calling the two
       already-existing pure functions -- `ServiceRadar.Edge.ProjectionRows.sweep/1`
       (row-coordinate enumeration) and `.row_key/2` (the Elixir twin of
       `go/pkg/edge/projection/projection.go`'s `RowKey/2`) -- and upserting
       one row per coordinate keyed on the derived idempotency key, so a
       redelivered frame never duplicates a domain row.

  A genuine conflict at either the delivery-slot or ledger layer rolls back
  the WHOLE transaction: no ledger row, no batch-slot row, no domain rows for
  a rejected frame. The first-accepted binding is therefore left immutable by
  construction (nothing in this module ever `UPDATE`s a mismatched digest).

  ## Deliberately out of scope here (see `openspec/changes/unify-sweep-results-proto/`)

  This module does NOT implement: hash-subshard/time-bucket partitioning
  (task 5.2's full design), the `EdgeRecordIngestService` gRPC server or Go
  sender (separate tasks), full trust/authorization evaluation (steps 3/4/6/7
  of design.md's ordered EventWriter pipeline -- historical collection proof,
  readiness, body-to-claim, transactional fence against a live consumer
  registry), MTR payloads, or the full OCSF sweep domain schema (task 5.1's
  decoder owns turning a row coordinate into a queryable
  reachability/open-port/port-error/mtr-summary fact; this module only proves
  the coordinate was durably and idempotently claimed).

  Payload-family dispatch is deliberately coarse: any
  `EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1` payload is attempted as a
  `SweepObservationBatchV1` (the one payload type this epic has projection
  logic for today; MTR decode intentionally is not wired here, per 0.12's own
  scope freeze). A real per-`output_contract.contract_id` registry does not
  exist yet in this repository, so this is not a shortcut around one.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Edge.ProjectionRows
  alias ServiceRadar.Edge.PublicationIdentity
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.SweepObservationBatchV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.EventWriter.BulkInsert
  alias ServiceRadar.Repo

  require Logger

  @impl true
  def table_name, do: "event_ledger"

  @impl true
  def process_batch(messages) do
    count =
      Enum.reduce(messages, 0, fn message, acc ->
        acc + process_one(message)
      end)

    {:ok, count}
  rescue
    e ->
      Logger.error("Edge record batch failed: #{inspect(e)}")
      {:error, e}
  end

  defp process_one(%{data: data, metadata: metadata}) when is_binary(data) do
    headers = Map.get(metadata || %{}, :headers, %{})

    case ingest(data, headers) do
      {:ok, outcome} ->
        :telemetry.execute(
          [:serviceradar, :event_writer, :edge_record, :ingested],
          %{count: 1},
          %{outcome: outcome}
        )

        1

      {:error, reason} ->
        :telemetry.execute(
          [:serviceradar, :event_writer, :edge_record, :rejected],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        Logger.warning("Edge record rejected", reason: inspect(reason))
        0
    end
  end

  defp process_one(_message), do: 0

  @doc """
  Decodes one raw edge-record frame (`record_bytes`, exactly what a gateway
  publishes to JetStream per design.md) plus its transport headers, and runs
  the idempotent ledger/delivery-slot/sweep-batch-slot/domain-projection
  transaction described in the moduledoc.

  Public -- and taking a plain repo argument -- so tests can drive it
  directly with a real wire-decoded frame and force redelivery/conflict
  scenarios against a real database, the same way every other EventWriter
  processor's `parse_message/1` is unit-tested directly, without depending on
  a live gRPC/JetStream path (out of scope for this task).

  Returns `{:ok, :inserted | :replay}` or `{:error, reason}`, where `reason`
  is `{:delivery_slot_conflict, existing}`, `{:event_id_conflict, existing}`,
  `{:sweep_batch_slot_conflict, existing}`, a header/slot decode reason, or a
  wire-decode reason from `ServiceRadar.Edge.WireDecode`.
  """
  @spec ingest(binary(), map() | list(), module()) ::
          {:ok, :inserted | :replay} | {:error, term()}
  def ingest(record_bytes, headers, repo \\ Repo) when is_binary(record_bytes) do
    with {:ok, header_set} <- PublicationIdentity.extract_header_set(headers),
         {:ok, provenance} <-
           PublicationIdentity.decode_transport_provenance(header_set.provenance),
         {:edge, slot} <- {provenance.kind, provenance.slot},
         {:ok, %EdgeRecordV1{} = record} <- WireDecode.decode_record(record_bytes),
         :ok <- check_slot_matches_record(slot, record),
         {:ok, %SweepObservationBatchV1{} = batch} <- decode_payload(record) do
      record_sha256 = :crypto.hash(:sha256, record_bytes)
      run_transaction(repo, slot, record, batch, record_sha256)
    else
      {:service, _slot} -> {:error, :unsupported_slot_kind}
      {:error, _reason} = err -> err
    end
  end

  defp check_slot_matches_record(slot, %EdgeRecordV1{producer_context: producer_context} = record) do
    cond do
      slot.network_scope_id != record.network_scope_id ->
        {:error, :network_scope_mismatch}

      is_nil(producer_context) or
          slot.authenticated_agent_id != producer_context.origin_principal_id ->
        {:error, :agent_mismatch}

      true ->
        :ok
    end
  end

  defp decode_payload(%EdgeRecordV1{
         payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
         payload: payload
       }) do
    WireDecode.decode_sweep_batch(payload)
  end

  defp decode_payload(_record), do: {:error, :unsupported_payload_family}

  defp run_transaction(repo, slot, record, batch, record_sha256) do
    network_scope_id = record.network_scope_id
    event_id = record.event_id
    semantic_digest = record.semantic_envelope_sha256

    repo.transaction(fn ->
      with {:ok, _slot_outcome} <-
             upsert_delivery_slot(repo, slot, record_sha256, event_id, semantic_digest),
           {:ok, ledger_outcome} <-
             upsert_ledger(repo, network_scope_id, event_id, semantic_digest, record_sha256),
           {:ok, _batch_outcome} <-
             upsert_sweep_batch_slot(
               repo,
               network_scope_id,
               batch,
               event_id,
               semantic_digest,
               record.projected_row_count
             ) do
        project_domain_rows(repo, network_scope_id, event_id, semantic_digest, batch)
        ledger_outcome
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  defp upsert_delivery_slot(repo, slot, record_sha256, event_id, semantic_digest) do
    sql = """
    INSERT INTO platform.edge_delivery_slots
      (network_scope_id, authenticated_agent_id, spool_id, sequence, record_sha256, event_id, semantic_envelope_sha256)
    VALUES ($1::uuid, $2::bytea, $3::uuid, $4::bigint, $5::bytea, $6::uuid, $7::bytea)
    ON CONFLICT (network_scope_id, authenticated_agent_id, spool_id, sequence) DO UPDATE
      SET record_sha256 = platform.edge_delivery_slots.record_sha256
    WHERE platform.edge_delivery_slots.record_sha256 = EXCLUDED.record_sha256
    RETURNING (xmax = 0) AS fresh_insert
    """

    params = [
      slot.network_scope_id,
      slot.authenticated_agent_id,
      slot.spool_id,
      slot.sequence,
      record_sha256,
      event_id,
      semantic_digest
    ]

    case repo.query!(sql, params) do
      %{rows: [[true]]} ->
        {:ok, :inserted}

      %{rows: [[false]]} ->
        {:ok, :replay}

      %{rows: []} ->
        {:error, {:delivery_slot_conflict, fetch_delivery_slot(repo, slot)}}
    end
  end

  defp fetch_delivery_slot(repo, slot) do
    sql = """
    SELECT record_sha256, event_id, semantic_envelope_sha256
    FROM platform.edge_delivery_slots
    WHERE network_scope_id = $1::uuid
      AND authenticated_agent_id = $2::bytea
      AND spool_id = $3::uuid
      AND sequence = $4::bigint
    """

    params = [slot.network_scope_id, slot.authenticated_agent_id, slot.spool_id, slot.sequence]

    case repo.query!(sql, params) do
      %{rows: [[record_sha256, event_id, semantic_envelope_sha256]]} ->
        %{
          record_sha256: record_sha256,
          event_id: event_id,
          semantic_envelope_sha256: semantic_envelope_sha256
        }

      %{rows: []} ->
        nil
    end
  end

  defp upsert_ledger(repo, network_scope_id, event_id, semantic_digest, record_sha256) do
    sql = """
    INSERT INTO platform.event_ledger (network_scope_id, event_id, semantic_envelope_sha256, record_sha256)
    VALUES ($1::uuid, $2::uuid, $3::bytea, $4::bytea)
    ON CONFLICT (network_scope_id, event_id) DO UPDATE
      SET semantic_envelope_sha256 = platform.event_ledger.semantic_envelope_sha256
    WHERE platform.event_ledger.semantic_envelope_sha256 = EXCLUDED.semantic_envelope_sha256
    RETURNING (xmax = 0) AS fresh_insert
    """

    case repo.query!(sql, [network_scope_id, event_id, semantic_digest, record_sha256]) do
      %{rows: [[true]]} ->
        {:ok, :inserted}

      %{rows: [[false]]} ->
        {:ok, :replay}

      %{rows: []} ->
        {:error, {:event_id_conflict, fetch_ledger(repo, network_scope_id, event_id)}}
    end
  end

  defp fetch_ledger(repo, network_scope_id, event_id) do
    case repo.query!(
           "SELECT semantic_envelope_sha256, record_sha256 FROM platform.event_ledger WHERE network_scope_id = $1::uuid AND event_id = $2::uuid",
           [network_scope_id, event_id]
         ) do
      %{rows: [[semantic_envelope_sha256, record_sha256]]} ->
        %{semantic_envelope_sha256: semantic_envelope_sha256, record_sha256: record_sha256}

      %{rows: []} ->
        nil
    end
  end

  defp upsert_sweep_batch_slot(
         repo,
         network_scope_id,
         %SweepObservationBatchV1{} = batch,
         event_id,
         semantic_digest,
         projected_row_count
       ) do
    committed_row_count = ProjectionRows.sweep_count(batch)

    sql = """
    INSERT INTO platform.edge_sweep_batch_slots
      (network_scope_id, execution_id, execution_shard, assignment_epoch, batch_sequence,
       event_id, semantic_envelope_sha256, projected_row_count, committed_row_count)
    VALUES ($1::uuid, $2::uuid, $3::bigint, $4::bigint, $5::bigint, $6::uuid, $7::bytea, $8::integer, $9::integer)
    ON CONFLICT (network_scope_id, execution_id, execution_shard, assignment_epoch, batch_sequence) DO UPDATE
      SET semantic_envelope_sha256 = platform.edge_sweep_batch_slots.semantic_envelope_sha256
    WHERE platform.edge_sweep_batch_slots.semantic_envelope_sha256 = EXCLUDED.semantic_envelope_sha256
    RETURNING (xmax = 0) AS fresh_insert
    """

    params = [
      network_scope_id,
      batch.execution_id,
      batch.execution_shard,
      batch.assignment_epoch,
      batch.batch_sequence,
      event_id,
      semantic_digest,
      projected_row_count,
      committed_row_count
    ]

    case repo.query!(sql, params) do
      %{rows: [[true]]} ->
        {:ok, :inserted}

      %{rows: [[false]]} ->
        {:ok, :replay}

      %{rows: []} ->
        batch_key =
          {network_scope_id, batch.execution_id, batch.execution_shard, batch.assignment_epoch,
           batch.batch_sequence}

        {:error, {:sweep_batch_slot_conflict, fetch_sweep_batch_slot(repo, batch_key)}}
    end
  end

  defp fetch_sweep_batch_slot(
         repo,
         {network_scope_id, execution_id, execution_shard, assignment_epoch, batch_sequence}
       ) do
    sql = """
    SELECT event_id, semantic_envelope_sha256
    FROM platform.edge_sweep_batch_slots
    WHERE network_scope_id = $1::uuid
      AND execution_id = $2::uuid
      AND execution_shard = $3::bigint
      AND assignment_epoch = $4::bigint
      AND batch_sequence = $5::bigint
    """

    params = [network_scope_id, execution_id, execution_shard, assignment_epoch, batch_sequence]

    case repo.query!(sql, params) do
      %{rows: [[event_id, semantic_envelope_sha256]]} ->
        %{event_id: event_id, semantic_envelope_sha256: semantic_envelope_sha256}

      %{rows: []} ->
        nil
    end
  end

  defp project_domain_rows(repo, network_scope_id, event_id, semantic_digest, batch) do
    rows =
      batch
      |> ProjectionRows.sweep()
      |> Enum.with_index()
      |> Enum.map(fn {{kind, batch_index, element_index}, ordinal} ->
        %{
          network_scope_id: network_scope_id,
          row_key: ProjectionRows.row_key(semantic_digest, ordinal),
          event_id: event_id,
          kind: kind,
          batch_index: batch_index,
          element_index: element_index,
          inserted_at: DateTime.utc_now()
        }
      end)

    BulkInsert.insert_all(repo, "edge_sweep_projected_rows", rows,
      on_conflict: :nothing,
      returning: false
    )
  end
end
