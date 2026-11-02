defmodule ServiceRadar.Edge.Projectors.SweepObservation do
  @moduledoc """
  Projects `serviceradar.sweep.observation` v1 records: scheduled sweep batches under a sweep
  lease.

  `decode/1` validates the sweep body and its correlation with the record's signed source
  authority. `project/4` runs inside the EventWriter ledger transaction: it claims the batch
  coordinate, and a primary delivery projects into the ordinary sweep and inventory tables
  through `ServiceRadar.Edge.SweepProjection`. A delivery that does not project (a replay or a
  late-fenced delivery) still locks the sweep execution slot before its batch coordinate
  commits. Conflicting coordinates roll back the whole transaction.
  """

  @behaviour ServiceRadar.Edge.Projector

  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.ProjectionRows
  alias ServiceRadar.Edge.SweepCorrelate
  alias ServiceRadar.Edge.SweepProjection
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.SweepObservationBatchV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.EventWriter.BulkInsert

  @impl true
  def decode(%EdgeRecordV1{payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1} = record) do
    with {:ok, body} <- Compression.inner_payload(record),
         {:ok, %SweepObservationBatchV1{} = batch} <- WireDecode.decode_sweep_batch(body),
         :ok <- SweepCorrelate.ingest_own_payload(record) do
      {:ok, batch}
    end
  end

  def decode(%EdgeRecordV1{}), do: {:error, :unsupported_payload_family}

  @impl true
  def project(repo, record, %SweepObservationBatchV1{} = batch, %{primary?: primary?}) do
    network_scope_id = record.network_scope_id
    event_id = record.event_id
    semantic_digest = record.semantic_envelope_sha256

    with :ok <- lock_unprojected_slot(repo, primary?, batch.execution_id),
         {:ok, _batch_outcome} <-
           upsert_sweep_batch_slot(
             repo,
             network_scope_id,
             batch,
             event_id,
             semantic_digest,
             record.projected_row_count
           ) do
      if primary? do
        case SweepProjection.project(repo, record, batch) do
          :ok -> project_domain_rows(repo, network_scope_id, event_id, semantic_digest, batch)
          {:error, reason} -> repo.rollback(reason)
        end
      end

      :ok
    end
  end

  defp lock_unprojected_slot(_repo, true, _execution_id), do: :ok

  defp lock_unprojected_slot(repo, false, execution_id),
    do: lock_sweep_execution_slot(repo, execution_id)

  defp lock_sweep_execution_slot(repo, execution_id) do
    repo.query!(
      """
      SELECT id
      FROM platform.sweep_execution_slots
      WHERE id = $1::uuid
      FOR UPDATE
      """,
      [execution_id]
    )

    :ok
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
