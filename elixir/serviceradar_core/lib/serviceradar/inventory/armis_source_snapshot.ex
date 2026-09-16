defmodule ServiceRadar.Inventory.ArmisSourceSnapshot do
  @moduledoc """
  Activates an exact Armis source collection after a complete sync run.

  Sync chunks stamp their run ID onto typed identifier metadata. Once the final
  chunk has landed, those rows are the immutable membership boundary for the
  collection; mutable active-device counts are never used as a substitute.
  """

  import Ecto.Query

  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.DeviceSourceObservationIngestor
  alias ServiceRadar.Repo

  @source "armis"

  @spec activate([map()], map(), keyword()) :: :ok | {:error, term()}
  def activate(updates, sync_meta, opts \\ [])

  def activate(updates, sync_meta, opts) when is_list(updates) and is_map(sync_meta) do
    actor = Keyword.get(opts, :actor)

    with {:ok, source_id} <- required_string(sync_meta, :sync_service_id),
         {:ok, run_id} <- required_string(sync_meta, :sync_run_id),
         {:ok, population} <- validate_population(map_value(sync_meta, :population)),
         {:ok, source} <- IntegrationSource.get_by_id(source_id, actor: actor),
         :ok <- require_armis_source(source),
         rows = collection_rows(source_id, run_id),
         :ok <- require_distinct_count(rows, population.distinct_source_ids) do
      snapshot = build_snapshot(source, run_id, population, rows, updates)
      observations = build_observations(snapshot, rows)
      DeviceSourceObservationIngestor.activate_resolved(snapshot, observations)
    end
  end

  def activate(_updates, _sync_meta, _opts), do: {:error, :invalid_sync_snapshot}

  @doc false
  def validate_population(population) when is_map(population) do
    with {:ok, raw_rows} <- nonnegative_integer(population, :raw_rows),
         {:ok, excluded_rows} <- nonnegative_integer(population, :excluded_rows),
         {:ok, invalid_rows} <- nonnegative_integer(population, :invalid_rows),
         {:ok, valid_occurrences} <- nonnegative_integer(population, :valid_occurrences),
         {:ok, distinct_source_ids} <- nonnegative_integer(population, :distinct_source_ids),
         {:ok, duplicate_occurrences} <-
           nonnegative_integer(population, :duplicate_occurrences),
         {:ok, conflicting_duplicate_ids} <-
           nonnegative_integer(population, :conflicting_duplicate_ids),
         true <- raw_rows == excluded_rows + invalid_rows + valid_occurrences,
         true <- valid_occurrences == distinct_source_ids + duplicate_occurrences do
      {:ok,
       %{
         raw_rows: raw_rows,
         excluded_rows: excluded_rows,
         invalid_rows: invalid_rows,
         valid_occurrences: valid_occurrences,
         distinct_source_ids: distinct_source_ids,
         duplicate_occurrences: duplicate_occurrences,
         conflicting_duplicate_ids: conflicting_duplicate_ids,
         duplicate_source_id_examples:
           string_list(map_get(population, :duplicate_source_id_examples)),
         invalid_row_examples: string_list(map_get(population, :invalid_row_examples)),
         conflicting_duplicate_examples:
           string_list(map_get(population, :conflicting_duplicate_examples))
       }}
    else
      false -> {:error, :population_equation_mismatch}
      {:error, _} = error -> error
    end
  end

  def validate_population(_), do: {:error, :population_accounting_unavailable}

  defp collection_rows(source_id, run_id) do
    Repo.all(
      from(identifier in DeviceIdentifier,
        join: device in Device,
        on: device.uid == identifier.device_id,
        where:
          identifier.identifier_type == :armis_device_id and
            fragment("COALESCE(?->>'sync_service_id', '') = ?", identifier.metadata, ^source_id) and
            fragment("COALESCE(?->>'sync_run_id', '') = ?", identifier.metadata, ^run_id),
        select: %{
          source_object_id: identifier.identifier_value,
          device_id: identifier.device_id,
          hostname: device.hostname,
          ip: device.ip,
          mac: device.mac,
          # `ServiceRadar.Inventory.Device` has no `serial_number` column -- it is only ever
          # carried in `metadata` (see `DeviceSourceObservationIngestor`'s own
          # `bounded_value(metadata, "serial_number", ...)` on the raw update path). Read it the
          # same way `site_name` already does below rather than a plain field reference, which
          # raises `Ecto.QueryError: field serial_number ... does not exist` at query build time.
          serial_number: fragment("?->>'serial_number'", device.metadata),
          vendor_name: device.vendor_name,
          model: device.model,
          device_type: device.type,
          site_name:
            fragment(
              "COALESCE(?->>'site_name', ?->>'boundary_names')",
              device.metadata,
              device.metadata
            ),
          metadata: identifier.metadata
        },
        order_by: [asc: identifier.identifier_value]
      )
    )
  end

  defp require_distinct_count(rows, expected) do
    actual = rows |> Enum.map(& &1.source_object_id) |> Enum.uniq() |> length()

    if actual == expected,
      do: :ok,
      else: {:error, {:source_membership_mismatch, expected, actual}}
  end

  defp build_snapshot(source, run_id, population, rows, updates) do
    observed_at = observed_at(updates)
    content_hash = content_hash(rows)

    %{
      partition: source.partition || "default",
      source: @source,
      source_instance: to_string(source.id),
      collection_id: run_id,
      content_hash: content_hash,
      query_hash: nil,
      observed_at: observed_at,
      metadata: %{
        "accounting_status" => "exact",
        "raw_rows" => population.raw_rows,
        "excluded_rows" => population.excluded_rows,
        "invalid_rows" => population.invalid_rows,
        "valid_occurrences" => population.valid_occurrences,
        "distinct_source_ids" => population.distinct_source_ids,
        "duplicate_occurrences" => population.duplicate_occurrences,
        "conflicting_duplicate_ids" => population.conflicting_duplicate_ids,
        "duplicate_source_id_examples" => population.duplicate_source_id_examples,
        "invalid_row_examples" => population.invalid_row_examples,
        "conflicting_duplicate_examples" => population.conflicting_duplicate_examples
      }
    }
  end

  defp build_observations(snapshot, rows) do
    Enum.map(rows, fn row ->
      %{
        device_id: row.device_id,
        partition: snapshot.partition,
        source: snapshot.source,
        source_instance: snapshot.source_instance,
        source_object_id: row.source_object_id,
        source_integration_id: "armis:source:#{snapshot.source_instance}:#{row.source_object_id}",
        collection_id: snapshot.collection_id,
        content_hash: snapshot.content_hash,
        query_hash: snapshot.query_hash,
        present: true,
        first_observed_at: snapshot.observed_at,
        last_observed_at: snapshot.observed_at,
        absent_since: nil,
        hostname: row.hostname,
        ip: row.ip,
        mac: row.mac,
        serial_number: row.serial_number,
        vendor_name: row.vendor_name,
        model: row.model,
        device_type: stringify(row.device_type),
        site_name: row.site_name,
        management_status: nil,
        metadata: %{"identifier_metadata" => row.metadata || %{}}
      }
    end)
  end

  defp observed_at(updates) do
    updates
    |> Enum.map(fn update -> map_get(update, :timestamp) end)
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn value ->
      case DateTime.from_iso8601(value) do
        {:ok, timestamp, _offset} -> [timestamp]
        _ -> []
      end
    end)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> DateTime.utc_now() end)
    |> DateTime.truncate(:microsecond)
  end

  defp content_hash(rows) do
    rows
    |> Enum.map(& &1.source_object_id)
    |> Enum.sort()
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp require_armis_source(%{source_type: :armis}), do: :ok
  defp require_armis_source(%{source_type: "armis"}), do: :ok
  defp require_armis_source(_source), do: {:error, :not_armis_source}

  defp required_string(map, key) do
    case map_get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_sync_meta, key}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:missing_sync_meta, key}}
    end
  end

  defp nonnegative_integer(map, key) do
    case map_get(map, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_population_count, key}}
    end
  end

  defp map_value(map, key) do
    case map_get(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(100)
  end

  defp string_list(_), do: []
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_binary(value), do: value
  defp stringify(_), do: nil
end
