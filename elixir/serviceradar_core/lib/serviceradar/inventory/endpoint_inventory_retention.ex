defmodule ServiceRadar.Inventory.EndpointInventoryRetention do
  @moduledoc """
  Retention cleanup for historical endpoint inventory scans and SBOM artifacts.
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.DataService.Client, as: DataServiceClient
  alias ServiceRadar.Repo
  alias ServiceRadar.Sync.Client, as: SyncClient

  require Logger

  @default_batch_size 5_000
  @default_retention_days 30
  @default_timeout_ms 30_000
  @query_timeout_ms 120_000

  @type summary :: %{
          scanned: non_neg_integer(),
          eligible_scans: non_neg_integer(),
          deleted_scans: non_neg_integer(),
          deleted_objects: non_neg_integer(),
          failed_objects: non_neg_integer(),
          dry_run: boolean(),
          failures: [map()]
        }

  @spec prune(keyword()) :: {:ok, summary()} | {:error, term()}
  def prune(opts \\ []) do
    retention_days = positive_integer(opts[:retention_days], @default_retention_days)
    batch_size = positive_integer(opts[:batch_size], @default_batch_size)
    timeout = positive_integer(opts[:timeout], @default_timeout_ms)
    dry_run? = Keyword.get(opts, :dry_run?, false)
    delete_object = Keyword.get(opts, :delete_object, &default_delete_object/2)

    with {:ok, candidates} <- candidate_scans(retention_days, batch_size),
         {:ok, summary} <- prune_candidates(candidates, delete_object, timeout, dry_run?) do
      if summary.deleted_scans > 0 or summary.failed_objects > 0 do
        Logger.info("Endpoint inventory retention completed",
          scanned: summary.scanned,
          deleted_scans: summary.deleted_scans,
          deleted_objects: summary.deleted_objects,
          failed_objects: summary.failed_objects,
          retention_days: retention_days,
          dry_run: dry_run?
        )
      end

      {:ok, summary}
    end
  end

  defp candidate_scans(retention_days, batch_size) do
    sql = """
    WITH candidate_scans AS (
      SELECT s.id, COALESCE(s.ingested_at, s.inserted_at) AS scan_time
      FROM platform.endpoint_inventory_scans AS s
      WHERE s.current = FALSE
        AND COALESCE(s.ingested_at, s.inserted_at) < NOW() - ($1::int * INTERVAL '1 day')
      ORDER BY COALESCE(s.ingested_at, s.inserted_at) ASC
      LIMIT $2
    ),
    deletable_contents AS (
      SELECT
        c.id AS content_ref,
        c.object_key,
        MIN(a.scan_ref::text) AS owner_scan_ref
      FROM platform.endpoint_inventory_artifact_contents AS c
      JOIN platform.endpoint_inventory_artifacts AS a ON a.artifact_content_ref = c.id
      WHERE EXISTS (
        SELECT 1
        FROM candidate_scans AS candidate
        WHERE candidate.id = a.scan_ref
      )
      AND NOT EXISTS (
        SELECT 1
        FROM platform.endpoint_inventory_artifacts AS outside_ref
        WHERE outside_ref.artifact_content_ref = c.id
          AND NOT EXISTS (
            SELECT 1
            FROM candidate_scans AS candidate
            WHERE candidate.id = outside_ref.scan_ref
          )
      )
      GROUP BY c.id, c.object_key
    ),
    legacy_objects AS (
      SELECT a.scan_ref::text AS scan_ref, a.object_key
      FROM platform.endpoint_inventory_artifacts AS a
      JOIN candidate_scans AS candidate ON candidate.id = a.scan_ref
      WHERE a.artifact_content_ref IS NULL
        AND a.object_key IS NOT NULL
    ),
    scan_objects AS (
      SELECT owner_scan_ref AS scan_ref, object_key FROM deletable_contents
      UNION ALL
      SELECT scan_ref, object_key FROM legacy_objects
    )
    SELECT s.id::text,
           COALESCE(
             array_agg(scan_objects.object_key ORDER BY scan_objects.object_key)
               FILTER (WHERE scan_objects.object_key IS NOT NULL),
             ARRAY[]::text[]
           ) AS object_keys
    FROM candidate_scans AS s
    LEFT JOIN scan_objects ON scan_objects.scan_ref = s.id::text
    GROUP BY s.id, s.scan_time
    ORDER BY s.scan_time ASC
    """

    case SQL.query(Repo, sql, [retention_days, batch_size], timeout: @query_timeout_ms) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [scan_ref, object_keys] ->
           %{scan_ref: scan_ref, object_keys: List.wrap(object_keys)}
         end)}

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        {:ok, []}

      {:error, error} ->
        {:error, error}
    end
  end

  defp prune_candidates(candidates, delete_object, timeout, dry_run?) do
    {eligible, deleted_objects, failures} =
      Enum.reduce(candidates, {[], 0, []}, fn candidate, {eligible, deleted, failures} ->
        case delete_candidate_objects(candidate, delete_object, timeout, dry_run?) do
          {:ok, object_count} ->
            {[candidate | eligible], deleted + object_count, failures}

          {:error, candidate_failures} ->
            {eligible, deleted, candidate_failures ++ failures}
        end
      end)

    eligible = Enum.reverse(eligible)
    failures = Enum.reverse(failures)

    with {:ok, deleted_scans} <- maybe_delete_scans(eligible, dry_run?) do
      {:ok,
       %{
         scanned: length(candidates),
         eligible_scans: length(eligible),
         deleted_scans: deleted_scans,
         deleted_objects: deleted_objects,
         failed_objects: length(failures),
         dry_run: dry_run?,
         failures: failures
       }}
    end
  end

  defp delete_candidate_objects(
         %{scan_ref: scan_ref, object_keys: object_keys},
         delete_object,
         timeout,
         dry_run?
       ) do
    if dry_run? do
      {:ok, 0}
    else
      {deleted, failures} =
        Enum.reduce(object_keys, {0, []}, fn object_key, {deleted, failures} ->
          case delete_object.(object_key, timeout: timeout) do
            {:ok, true} ->
              {deleted + 1, failures}

            {:ok, false} ->
              {deleted, failures}

            {:error, reason} ->
              {deleted,
               [
                 %{scan_ref: scan_ref, object_key: object_key, reason: inspect(reason)}
                 | failures
               ]}
          end
        end)

      if failures == [] do
        {:ok, deleted}
      else
        {:error, Enum.reverse(failures)}
      end
    end
  end

  defp maybe_delete_scans([], _dry_run?), do: {:ok, 0}
  defp maybe_delete_scans(_eligible, true), do: {:ok, 0}

  defp maybe_delete_scans(eligible, false) do
    scan_refs = Enum.map(eligible, & &1.scan_ref)

    sql = """
    DELETE FROM platform.endpoint_inventory_scans
    WHERE id::text = ANY($1::text[])
    """

    case SQL.query(Repo, sql, [scan_refs], timeout: @query_timeout_ms) do
      {:ok, %{num_rows: deleted}} ->
        delete_orphaned_artifact_contents()
        {:ok, deleted}

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        {:ok, 0}

      {:error, error} ->
        {:error, error}
    end
  end

  defp delete_orphaned_artifact_contents do
    sql = """
    DELETE FROM platform.endpoint_inventory_artifact_contents AS c
    WHERE NOT EXISTS (
      SELECT 1
      FROM platform.endpoint_inventory_artifacts AS a
      WHERE a.artifact_content_ref = c.id
    )
    """

    case SQL.query(Repo, sql, [], timeout: @query_timeout_ms) do
      {:ok, _result} ->
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "Failed to prune orphaned endpoint artifact content rows: #{inspect(error)}"
        )
    end
  end

  defp default_delete_object(object_key, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    DataServiceClient.with_channel(
      fn channel ->
        case SyncClient.delete_object(channel, object_key, timeout: timeout) do
          {:ok, %Proto.DeleteObjectResponse{deleted: deleted?}} -> {:ok, deleted?}
          {:ok, _response} -> {:ok, false}
          {:error, reason} -> {:error, reason}
        end
      end,
      timeout: timeout
    )
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
