defmodule ServiceRadar.Inventory.Remediation.ArmisSourceIdentityRepair do
  @moduledoc """
  Collection-bound dry-run classification for canonical devices with multiple
  Armis identifiers.

  Presence in one complete activated source collection determines whether an
  identifier is current. Shared canonical ownership is reported as evidence,
  never treated as proof that distinct Armis IDs are duplicate assets.
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Repo

  @default_limit 5_000
  @maximum_limit 10_000

  @spec dry_run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def dry_run(source_id, opts \\ [])

  def dry_run(source_id, opts) when is_binary(source_id) do
    limit = bounded_limit(Keyword.get(opts, :limit, @default_limit))

    with {:ok, snapshot} <- exact_snapshot(source_id),
         {:ok, rows, total_count} <- multi_id_rows(source_id, snapshot, limit) do
      classifications = Enum.map(rows, &classify_row/1)

      {:ok,
       %{
         mode: "dry_run",
         source_id: source_id,
         collection_id: snapshot.collection_id,
         collection_content_hash: snapshot.content_hash,
         collection_observed_at: snapshot.observed_at,
         total_count: total_count,
         returned_count: length(classifications),
         truncated: total_count > length(classifications),
         summary: Enum.frequencies_by(classifications, & &1.classification),
         classifications: classifications
       }}
    end
  end

  def dry_run(_source_id, _opts), do: {:error, :invalid_source_id}

  @doc false
  def classify_row(row) do
    typed_ids = normalize_ids(Map.get(row, :typed_ids))
    current_ids = normalize_ids(Map.get(row, :current_ids))
    stale_ids = typed_ids -- current_ids

    {classification, proposed_action} =
      case length(current_ids) do
        0 -> {"no_current_ids", "review_historical_identity"}
        1 -> {"one_current_id", "review_stale_ids_after_absence_grace"}
        _ -> {"multiple_current_ids", "manual_source_alias_or_overmerge_review"}
      end

    %{
      device_uid: Map.get(row, :device_uid),
      classification: classification,
      typed_ids: typed_ids,
      current_ids: current_ids,
      stale_ids: stale_ids,
      deleted: Map.get(row, :deleted, false),
      merge_audit_count: Map.get(row, :merge_audit_count, 0),
      proposed_action: proposed_action,
      apply_eligible: false
    }
  end

  defp exact_snapshot(source_id) do
    sql = """
    SELECT collection_id, content_hash, partition, observed_at, activated_at
    FROM platform.device_source_snapshots
    WHERE source = 'armis'
      AND source_instance = $1
      AND metadata->>'accounting_status' = 'exact'
    ORDER BY activated_at DESC, observed_at DESC, id DESC
    LIMIT 1
    """

    case SQL.query(Repo, sql, [source_id]) do
      {:ok, %{rows: [[collection_id, content_hash, partition, observed_at, activated_at]]}} ->
        {:ok,
         %{
           collection_id: collection_id,
           content_hash: content_hash,
           partition: partition,
           observed_at: observed_at,
           activated_at: activated_at
         }}

      {:ok, %{rows: []}} ->
        {:error, :exact_source_snapshot_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp multi_id_rows(source_id, snapshot, limit) do
    sql = """
    WITH typed AS (
      SELECT di.device_id,
             array_agg(DISTINCT di.identifier_value ORDER BY di.identifier_value) AS typed_ids
      FROM platform.device_identifiers di
      JOIN platform.ocsf_devices d ON d.uid = di.device_id
      WHERE di.identifier_type = 'armis_device_id'
        AND NULLIF(di.identifier_value, '') IS NOT NULL
        AND di.partition = $3
        AND COALESCE(
              NULLIF(di.metadata->>'sync_service_id', ''),
              NULLIF(d.metadata->>'sync_service_id', '')
            ) = $1
      GROUP BY di.device_id
      HAVING count(DISTINCT di.identifier_value) > 1
    ),
    current_ids AS (
      SELECT source_object_id
      FROM platform.device_source_observations
      WHERE source = 'armis'
        AND source_instance = $1
        AND partition = $3
        AND collection_id = $2
        AND present = true
    ),
    classified AS (
      SELECT typed.device_id,
             typed.typed_ids,
             ARRAY(
               SELECT typed_id
               FROM unnest(typed.typed_ids) AS typed_id
               JOIN current_ids current ON current.source_object_id = typed_id
               ORDER BY typed_id
             ) AS current_ids,
             (d.deleted_at IS NOT NULL) AS deleted,
             (
               SELECT count(*)
               FROM platform.merge_audit audit
               WHERE audit.from_device_id = typed.device_id
                  OR audit.to_device_id = typed.device_id
             ) AS merge_audit_count
      FROM typed
      JOIN platform.ocsf_devices d ON d.uid = typed.device_id
    )
    SELECT device_id,
           typed_ids,
           current_ids,
           deleted,
           merge_audit_count,
           count(*) OVER () AS total_count
    FROM classified
    ORDER BY device_id
    LIMIT $4
    """

    case SQL.query(Repo, sql, [source_id, snapshot.collection_id, snapshot.partition, limit]) do
      {:ok, %{rows: rows}} ->
        mapped =
          Enum.map(rows, fn [device_uid, typed_ids, current_ids, deleted, audit_count, _total] ->
            %{
              device_uid: device_uid,
              typed_ids: typed_ids,
              current_ids: current_ids,
              deleted: deleted,
              merge_audit_count: audit_count
            }
          end)

        total_count =
          case rows do
            [[_, _, _, _, _, total] | _] -> total
            [] -> 0
          end

        {:ok, mapped, total_count}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bounded_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @maximum_limit)

  defp bounded_limit(_limit), do: @default_limit

  defp normalize_ids(ids) when is_list(ids) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_ids(_ids), do: []
end
