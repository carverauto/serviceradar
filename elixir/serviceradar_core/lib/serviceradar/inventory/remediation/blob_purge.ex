defmodule ServiceRadar.Inventory.Remediation.BlobPurge do
  @moduledoc """
  Step `blob-purge` (OpenSpec refactor-device-identity-reconciliation 4.1).

  Purges the multi-MAC blob / malformed `mac` identifier rows that the
  pre-guard sync path accumulated (~12.2M rows live):

  1. For every device whose ONLY `mac` identifiers are invalid (no atomic
     12-hex row), the first MAC of its most recently seen blob is extracted
     (`IdentityReconciler.normalize_mac/1`) and inserted as a valid
     identifier (source `"remediation"`, confidence from
     `IdentityReconciler.mac_confidence/1`) BEFORE anything is deleted, so
     no device is left without a MAC identity.
  2. All `mac` rows whose value is not exactly 12 uppercase hex characters
     (comma blobs, wrong length, non-hex) are deleted in bounded batches
     (keyset pagination on `id`, default 50k/batch) with progress logging.

  Inserts go through the audited Ash `:upsert` action, which intentionally
  does NOT repoint `device_id` on conflict — if an extracted MAC already
  exists on another device, ownership stays put and the conflict is counted.
  Deletes are recorded in the manifest (row ids per batch).
  """

  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.Remediation.Decisions
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo

  require Logger

  @step "blob-purge"
  @valid_sql_pattern "^[0-9A-F]{12}$"
  @default_batch_size 50_000
  @progress_every 10

  @doc false
  def run(mode, opts, manifest, actor) do
    batch_size = positive(Keyword.get(opts, :batch_size), @default_batch_size)

    invalid_rows = count_invalid_rows()
    {blob_only_devices, sample} = blob_only_summary()

    base = %{
      invalid_mac_rows: invalid_rows,
      blob_only_devices: blob_only_devices,
      sample_extractions: sample
    }

    case mode do
      :dry_run ->
        Map.merge(base, %{
          would_delete_rows: invalid_rows,
          would_extract_devices: blob_only_devices,
          deleted_rows: 0,
          extracted_macs: 0
        })

      :execute ->
        extract_stats = extract_fallback_macs(batch_size, manifest, actor)
        deleted_rows = delete_invalid_rows(batch_size, manifest)

        base
        |> Map.merge(extract_stats)
        |> Map.put(:deleted_rows, deleted_rows)
    end
  end

  # -- counts -----------------------------------------------------------------

  defp count_invalid_rows do
    %{rows: [[count]]} =
      query!(
        "SELECT count(*) FROM platform.device_identifiers " <>
          "WHERE identifier_type = 'mac' AND identifier_value !~ '#{@valid_sql_pattern}'",
        []
      )

    count
  end

  defp blob_only_summary do
    %{rows: [[count]]} =
      query!(
        """
        SELECT count(*) FROM (
          SELECT device_id
          FROM platform.device_identifiers
          WHERE identifier_type = 'mac'
          GROUP BY device_id
          HAVING count(*) FILTER (WHERE identifier_value ~ '#{@valid_sql_pattern}') = 0
        ) blob_only
        """,
        []
      )

    sample =
      ""
      |> blob_only_batch(5)
      |> Enum.map(fn {device_id, _blob_id, blob, _partition} ->
        %{device_id: device_id, extracted_mac: Decisions.first_mac_from_blob(blob)}
      end)

    {count, sample}
  end

  # -- extraction (insert BEFORE delete) --------------------------------------

  defp extract_fallback_macs(batch_size, manifest, actor) do
    extract_loop("", batch_size, manifest, actor, %{
      extracted_macs: 0,
      extraction_conflicts: 0,
      unextractable_devices: 0
    })
  end

  defp extract_loop(cursor, batch_size, manifest, actor, stats) do
    case blob_only_batch(cursor, batch_size) do
      [] ->
        stats

      batch ->
        {stats, inserted_ids} =
          Enum.reduce(batch, {stats, []}, fn {device_id, blob_id, blob, partition},
                                             {stats, ids} ->
            case Decisions.first_mac_from_blob(blob) do
              nil ->
                {bump(stats, :unextractable_devices), ids}

              mac ->
                insert_extracted_mac(device_id, blob_id, mac, partition, actor, stats, ids)
            end
          end)

        Manifest.record(
          manifest,
          @step,
          :insert_extracted_mac,
          "platform.device_identifiers",
          Enum.reverse(inserted_ids),
          %{devices: length(batch)}
        )

        next_cursor = batch |> List.last() |> elem(0)
        extract_loop(next_cursor, batch_size, manifest, actor, stats)
    end
  end

  defp insert_extracted_mac(device_id, blob_id, mac, partition, actor, stats, ids) do
    result =
      DeviceIdentifier
      |> Ash.Changeset.for_create(:upsert, %{
        device_id: device_id,
        identifier_type: :mac,
        identifier_value: mac,
        partition: partition || "default",
        confidence: IdentityReconciler.mac_confidence(mac),
        source: "remediation",
        metadata: %{"remediation" => @step, "extracted_from_blob_id" => blob_id}
      })
      |> Ash.create(actor: actor)

    case result do
      {:ok, %DeviceIdentifier{id: id, device_id: ^device_id}} ->
        {bump(stats, :extracted_macs), [id | ids]}

      {:ok, %DeviceIdentifier{}} ->
        # Conflict on (type, value, partition): the MAC already belongs to
        # another device; ownership intentionally stays put.
        {bump(stats, :extraction_conflicts), ids}

      {:error, error} ->
        Logger.warning(
          "BlobPurge: failed to insert extracted MAC #{mac} for #{device_id}: #{inspect(error)}"
        )

        {bump(stats, :unextractable_devices), ids}
    end
  end

  # Devices whose mac identifiers are all invalid, with their most recently
  # seen blob row, keyset-paginated by device_id.
  defp blob_only_batch(cursor, limit) do
    %{rows: rows} =
      query!(
        """
        WITH blob_only AS (
          SELECT device_id
          FROM platform.device_identifiers
          WHERE identifier_type = 'mac' AND device_id > $1
          GROUP BY device_id
          HAVING count(*) FILTER (WHERE identifier_value ~ '#{@valid_sql_pattern}') = 0
          ORDER BY device_id
          LIMIT $2
        )
        SELECT DISTINCT ON (di.device_id)
               di.device_id, di.id, di.identifier_value, di.partition
        FROM platform.device_identifiers di
        JOIN blob_only b ON b.device_id = di.device_id
        WHERE di.identifier_type = 'mac'
        ORDER BY di.device_id, di.last_seen DESC NULLS LAST, di.id DESC
        """,
        [cursor, limit]
      )

    Enum.map(rows, fn [device_id, id, value, partition] -> {device_id, id, value, partition} end)
  end

  # -- batched delete ----------------------------------------------------------

  defp delete_invalid_rows(batch_size, manifest) do
    delete_loop(0, batch_size, manifest, 0, 0)
  end

  defp delete_loop(cursor, batch_size, manifest, total, batches) do
    %{rows: rows} =
      query!(
        """
        SELECT id FROM platform.device_identifiers
        WHERE identifier_type = 'mac'
          AND id > $1
          AND identifier_value !~ '#{@valid_sql_pattern}'
        ORDER BY id
        LIMIT $2
        """,
        [cursor, batch_size]
      )

    case List.flatten(rows) do
      [] ->
        Logger.info("BlobPurge: deleted #{total} invalid mac identifier rows total")
        total

      ids ->
        %{num_rows: deleted} =
          query!("DELETE FROM platform.device_identifiers WHERE id = ANY($1)", [ids])

        Manifest.record(
          manifest,
          @step,
          :delete_invalid_mac_rows,
          "platform.device_identifiers",
          ids
        )

        total = total + deleted
        batches = batches + 1

        if rem(batches, @progress_every) == 0 do
          Logger.info("BlobPurge: deleted #{total} invalid mac identifier rows so far")
        end

        delete_loop(List.last(ids), batch_size, manifest, total, batches)
    end
  end

  # -- helpers -----------------------------------------------------------------

  defp query!(sql, params), do: Ecto.Adapters.SQL.query!(Repo, sql, params)

  defp bump(stats, key), do: Map.update!(stats, key, &(&1 + 1))

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
