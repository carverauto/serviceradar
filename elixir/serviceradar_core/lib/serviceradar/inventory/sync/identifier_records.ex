defmodule ServiceRadar.Inventory.Sync.IdentifierRecords do
  @moduledoc """
  Builds and bulk-upserts device_identifiers rows for resolved updates.
  One row per atomic MAC; confidence from evidence; ownership is never
  replaced on conflict.
  """

  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.CardinalityCaps
  alias ServiceRadar.Inventory.Identity.HardwareSerial
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.Sync.SourcePolicy
  alias ServiceRadar.Repo

  require Logger

  # Build identifier records for bulk upsert
  def build_identifier_records(resolved_updates) do
    resolved_updates
    |> Enum.flat_map(fn {update, device_id} ->
      ids = SourcePolicy.effective_identifiers(update)
      partition = ids.partition
      include_mac? = SourcePolicy.include_mac_identifier?(update)

      id_types = SourcePolicy.identifier_types(update, ids)

      id_types
      |> Enum.reduce([], fn id_type, acc ->
        maybe_add_identifier_record(
          acc,
          update,
          device_id,
          id_type,
          Ids.get_identifier_value(ids, id_type),
          partition
        )
      end)
      |> add_mac_identifier_records(include_mac?, update, device_id, ids, partition)
    end)
    |> Enum.uniq_by(fn r -> {r.identifier_type, r.identifier_value, r.partition} end)
  end

  # One record per atomic MAC, confidence derived from the IEEE local bit.
  # The legacy blob value is lookup-only and never registered. Values are
  # re-validated so malformed MACs can never become identifier rows.
  defp add_mac_identifier_records(acc, false, _update, _device_id, _ids, _partition), do: acc

  defp add_mac_identifier_records(acc, true, update, device_id, ids, partition) do
    case_result =
      case ids do
        %{macs: list} when is_list(list) -> list
        _ -> List.wrap(ids.mac)
      end

    macs =
      case_result
      |> Enum.flat_map(&IdentityReconciler.normalize_mac_list/1)
      |> Enum.uniq()

    Enum.reduce(macs, acc, fn mac, inner ->
      [
        %{
          device_id: device_id,
          identifier_type: :mac,
          identifier_value: mac,
          partition: partition,
          confidence: IdentityReconciler.mac_confidence(mac),
          source: "sync_ingestor",
          metadata: build_identifier_metadata(update)
        }
        | inner
      ]
    end)
  end

  defp maybe_add_identifier_record(acc, _update, _device_id, _type, nil, _partition), do: acc

  defp maybe_add_identifier_record(acc, update, device_id, type, value, partition) do
    [
      %{
        device_id: device_id,
        identifier_type: type,
        identifier_value: value,
        partition: partition,
        confidence: :strong,
        source: "sync_ingestor",
        metadata: build_identifier_metadata(update)
      }
      | acc
    ]
  end

  # Bulk upsert identifiers
  # DB connection's search_path determines the schema
  def bulk_upsert_identifiers(records) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    insert_records =
      Enum.map(records, fn r ->
        Map.merge(r, %{
          first_seen: now,
          last_seen: now
        })
      end)

    if !Enum.empty?(insert_records) do
      # Ownership is intentionally NOT replaced on conflict: silently
      # re-pointing an identifier's device_id collapsed distinct devices
      # (500-per-batch integration_id pile-ups, agent identity theft).
      # Identifier ownership changes only via audited merges/rebinds.
      Repo.insert_all(
        DeviceIdentifier,
        insert_records,
        on_conflict: {:replace, [:last_seen, :metadata]},
        conflict_target: [:identifier_type, :identifier_value, :partition]
      )

      CardinalityCaps.enforce(
        Enum.map(insert_records, fn r -> {r.device_id, r.identifier_type} end)
      )
    end

    :ok
  rescue
    e ->
      Logger.warning("Bulk identifier upsert failed: #{inspect(e)}")
      {:error, e}
  end

  def build_identifier_metadata(update) do
    metadata =
      Map.take(update.metadata, [
        "sync_service_id",
        "sync_run_id",
        "sync_total_devices",
        "integration_type",
        "source_duplicate_conflict"
      ])

    case HardwareSerial.evidence(update) do
      {:ok, evidence} ->
        Map.merge(metadata, %{
          "hardware_serial_namespace" => evidence.vendor_namespace,
          "hardware_serial_normalized" => evidence.normalized_serial
        })

      :error ->
        metadata
    end
  end
end
