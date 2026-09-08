defmodule ServiceRadar.Inventory.Identity.SourceAuthorityGuard do
  @moduledoc """
  Fail-closed guard for automatic merges across source-authoritative IDs.

  A MAC, IP, hostname, or transitive duplicate edge cannot authorize combining
  two non-empty, disjoint Armis identity sets from the same source scope.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.SourceIdentityDrift
  alias ServiceRadar.Repo

  @typed_identifier :armis_device_id

  @spec conflict_details([String.t()], keyword()) :: map() | nil
  def conflict_details(device_ids, opts \\ []) when is_list(device_ids) do
    device_ids = device_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    if length(device_ids) < 2 do
      nil
    else
      device_ids
      |> identifier_rows(Keyword.get(opts, :lock, false))
      |> conflict_from_rows(device_ids)
    end
  end

  @spec ensure_merge_allowed([String.t()], keyword()) :: :ok | {:error, term()}
  def ensure_merge_allowed(device_ids, opts \\ []) do
    with :ok <- maybe_lock_ownership(device_ids, Keyword.get(opts, :lock, false)) do
      case conflict_details(device_ids, opts) do
        nil -> :ok
        details -> {:error, {:source_authority_conflict, details}}
      end
    end
  end

  @doc false
  def conflict_from_rows(rows, device_ids) when is_list(rows) and is_list(device_ids) do
    rows
    |> Enum.group_by(fn row -> {row.partition, source_id(row)} end)
    |> Enum.find_value(fn {{partition, source_id}, scoped_rows} ->
      sets =
        Map.new(device_ids, fn device_id ->
          ids =
            scoped_rows
            |> Enum.filter(&(&1.device_id == device_id))
            |> Enum.map(& &1.identifier_value)
            |> Enum.reject(&(&1 in [nil, ""]))
            |> MapSet.new()

          {device_id, ids}
        end)

      nonempty = Enum.reject(sets, fn {_device_id, ids} -> MapSet.size(ids) == 0 end)

      if disjoint_nonempty_sets?(nonempty) do
        %{
          partition: partition,
          source_id: blank_to_nil(source_id),
          device_ids: Enum.sort(device_ids),
          source_ids:
            Map.new(sets, fn {device_id, ids} ->
              {device_id, ids |> MapSet.to_list() |> Enum.sort()}
            end)
        }
      end
    end)
  end

  def conflict_from_rows(_rows, _device_ids), do: nil

  @spec record_blocked(map(), String.t(), map()) :: :ok | {:error, term()}
  def record_blocked(details, reason, evidence \\ %{})

  def record_blocked(details, reason, evidence) when is_map(details) do
    now = DateTime.utc_now()
    [first_device | _] = details.device_ids

    source_values =
      details.source_ids |> Map.values() |> List.flatten() |> Enum.uniq() |> Enum.sort()

    SourceIdentityDrift.record_conflicts([
      %{
        source_type: "armis",
        source_id: details.source_id,
        source_identifier_type: "armis_device_id",
        source_identifier_value: Enum.join(source_values, ","),
        device_uid: first_device,
        conflict_category: "automatic_merge_source_authority_conflict",
        conflicting_identifiers: %{
          "device_ids" => details.device_ids,
          "source_ids" => details.source_ids,
          "partition" => details.partition
        },
        proposed_action: "block_automatic_merge",
        confidence: "high",
        first_detected_at: now,
        last_detected_at: now,
        metadata: %{"merge_reason" => reason, "evidence" => evidence}
      }
    ])
  end

  def record_blocked(_details, _reason, _evidence), do: :ok

  defp identifier_rows(device_ids, lock?) do
    query =
      from(identifier in DeviceIdentifier,
        where:
          identifier.device_id in ^device_ids and
            identifier.identifier_type == ^@typed_identifier,
        select: %{
          device_id: identifier.device_id,
          identifier_value: identifier.identifier_value,
          partition: identifier.partition,
          metadata: identifier.metadata
        }
      )

    query = if lock?, do: lock(query, "FOR UPDATE"), else: query
    Repo.all(query)
  end

  defp maybe_lock_ownership(_device_ids, false), do: :ok

  defp maybe_lock_ownership(device_ids, true) do
    if Repo.in_transaction?() do
      sql = """
      SELECT pg_advisory_xact_lock(
               hashtextextended('serviceradar:armis-identifier-owner:' || device_id, 0)
             )
      FROM (
        SELECT DISTINCT unnest($1::text[]) AS device_id
        ORDER BY device_id
      ) ordered_devices
      """

      case SQL.query(Repo, sql, [Enum.sort(Enum.uniq(device_ids))]) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, {:source_authority_lock_failed, reason}}
      end
    else
      {:error, :source_authority_lock_requires_transaction}
    end
  end

  defp disjoint_nonempty_sets?(sets) when length(sets) < 2, do: false

  defp disjoint_nonempty_sets?(sets) do
    Enum.any?(sets, fn {left_device, left_ids} ->
      Enum.any?(sets, fn {right_device, right_ids} ->
        left_device < right_device and MapSet.disjoint?(left_ids, right_ids)
      end)
    end)
  end

  defp source_id(row) do
    metadata = row.metadata || %{}
    metadata["sync_service_id"] || metadata[:sync_service_id] || ""
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
