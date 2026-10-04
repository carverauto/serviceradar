defmodule ServiceRadar.Inventory.EndpointInventoryRetention do
  @moduledoc """
  Retention cleanup for historical endpoint inventory scans and SBOM artifacts.
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.DataService.Client, as: DataServiceClient
  alias ServiceRadar.Repo
  alias ServiceRadar.Sync.Client, as: SyncClient

  require Logger

  # Old scans deleted per run. A scan owns several hundred package rows, so this
  # bounds how long one run takes, not how long any single statement takes.
  @default_batch_size 5_000
  # Scans whose objects and rows are removed together.
  @default_scan_batch_size 100
  # Package rows per DELETE. Every statement has to finish well inside the
  # application role's statement_timeout: deleting a run's scans in one
  # statement cascaded to millions of package rows and was cancelled every time.
  @default_package_batch_size 10_000
  @default_retention_days 30
  @default_timeout_ms 30_000
  @query_timeout_ms 120_000

  @type summary :: %{
          scanned: non_neg_integer(),
          eligible_scans: non_neg_integer(),
          deleted_scans: non_neg_integer(),
          deleted_packages: non_neg_integer(),
          deleted_objects: non_neg_integer(),
          failed_objects: non_neg_integer(),
          dry_run: boolean(),
          failures: [map()]
        }

  @doc """
  Deletes up to `:batch_size` non-current scans older than `:retention_days`,
  oldest first, with their package rows and every SBOM object no other scan
  references.

  The work runs `:scan_batch_size` scans at a time, and package rows are deleted
  `:package_batch_size` at a time before their scans, so no statement grows with
  the backlog. A scan whose object deletion fails is kept for a later run. An
  error stops the run; pages already finished stay deleted.
  """
  @spec prune(keyword()) :: {:ok, summary()} | {:error, term()}
  def prune(opts \\ []) do
    retention_days = positive_integer(opts[:retention_days], @default_retention_days)
    max_scans = positive_integer(opts[:batch_size], @default_batch_size)
    dry_run? = Keyword.get(opts, :dry_run?, false)

    ctx = %{
      retention_days: retention_days,
      max_scans: max_scans,
      scan_batch_size:
        min(positive_integer(opts[:scan_batch_size], @default_scan_batch_size), max_scans),
      package_batch_size:
        positive_integer(opts[:package_batch_size], @default_package_batch_size),
      timeout: positive_integer(opts[:timeout], @default_timeout_ms),
      dry_run?: dry_run?,
      delete_object: Keyword.get(opts, :delete_object, &default_delete_object/2)
    }

    with {:ok, summary} <- prune_pages(ctx, nil, empty_summary(dry_run?)) do
      if summary.deleted_scans > 0, do: delete_orphaned_artifact_contents()

      if summary.deleted_scans > 0 or summary.failed_objects > 0 do
        Logger.info("Endpoint inventory retention completed",
          scanned: summary.scanned,
          deleted_scans: summary.deleted_scans,
          deleted_packages: summary.deleted_packages,
          deleted_objects: summary.deleted_objects,
          failed_objects: summary.failed_objects,
          retention_days: retention_days,
          dry_run: dry_run?
        )
      end

      {:ok, summary}
    end
  end

  defp empty_summary(dry_run?) do
    %{
      scanned: 0,
      eligible_scans: 0,
      deleted_scans: 0,
      deleted_packages: 0,
      deleted_objects: 0,
      failed_objects: 0,
      dry_run: dry_run?,
      failures: []
    }
  end

  # Pages advance by a (scan_time, id) cursor instead of re-selecting the oldest
  # scans, so a scan kept back by a failed object delete -- or every scan, in a
  # dry run -- is not offered again within the run.
  defp prune_pages(ctx, cursor, summary) do
    limit = min(ctx.scan_batch_size, ctx.max_scans - summary.scanned)

    if limit <= 0 do
      {:ok, summary}
    else
      with {:ok, candidates} <- candidate_scans(ctx.retention_days, limit, cursor),
           {:ok, page} <- prune_candidates(candidates, ctx) do
        summary = merge_summary(summary, page)

        if length(candidates) < limit do
          {:ok, summary}
        else
          last = List.last(candidates)
          prune_pages(ctx, {last.scan_time, last.scan_ref}, summary)
        end
      end
    end
  end

  defp merge_summary(summary, page) do
    %{
      summary
      | scanned: summary.scanned + page.scanned,
        eligible_scans: summary.eligible_scans + page.eligible_scans,
        deleted_scans: summary.deleted_scans + page.deleted_scans,
        deleted_packages: summary.deleted_packages + page.deleted_packages,
        deleted_objects: summary.deleted_objects + page.deleted_objects,
        failed_objects: summary.failed_objects + page.failed_objects,
        failures: summary.failures ++ page.failures
    }
  end

  defp candidate_scans(retention_days, limit, cursor) do
    {cursor_filter, cursor_params} =
      case cursor do
        nil ->
          {"", []}

        {scan_time, scan_ref} ->
          {"AND (COALESCE(s.ingested_at, s.inserted_at), s.id) > ($3::timestamp, $4::text::uuid)",
           [scan_time, scan_ref]}
      end

    sql = """
    WITH candidate_scans AS (
      SELECT s.id, COALESCE(s.ingested_at, s.inserted_at) AS scan_time
      FROM platform.endpoint_inventory_scans AS s
      WHERE s.current = FALSE
        AND COALESCE(s.ingested_at, s.inserted_at) < NOW() - ($1::int * INTERVAL '1 day')
        #{cursor_filter}
      ORDER BY COALESCE(s.ingested_at, s.inserted_at) ASC, s.id ASC
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
           s.scan_time,
           COALESCE(
             array_agg(scan_objects.object_key ORDER BY scan_objects.object_key)
               FILTER (WHERE scan_objects.object_key IS NOT NULL),
             ARRAY[]::text[]
           ) AS object_keys
    FROM candidate_scans AS s
    LEFT JOIN scan_objects ON scan_objects.scan_ref = s.id::text
    GROUP BY s.id, s.scan_time
    ORDER BY s.scan_time ASC, s.id ASC
    """

    case SQL.query(Repo, sql, [retention_days, limit | cursor_params], timeout: @query_timeout_ms) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [scan_ref, scan_time, object_keys] ->
           %{scan_ref: scan_ref, scan_time: scan_time, object_keys: List.wrap(object_keys)}
         end)}

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        {:ok, []}

      {:error, error} ->
        {:error, error}
    end
  end

  defp prune_candidates(candidates, ctx) do
    {eligible, deleted_objects, failures} =
      Enum.reduce(candidates, {[], 0, []}, fn candidate, {eligible, deleted, failures} ->
        case delete_candidate_objects(candidate, ctx.delete_object, ctx.timeout, ctx.dry_run?) do
          {:ok, object_count} ->
            {[candidate | eligible], deleted + object_count, failures}

          {:error, candidate_failures} ->
            {eligible, deleted, candidate_failures ++ failures}
        end
      end)

    eligible = Enum.reverse(eligible)
    failures = Enum.reverse(failures)

    with {:ok, deleted} <- maybe_delete_scans(eligible, ctx) do
      {:ok,
       %{
         scanned: length(candidates),
         eligible_scans: length(eligible),
         deleted_scans: deleted.scans,
         deleted_packages: deleted.packages,
         deleted_objects: deleted_objects,
         failed_objects: length(failures),
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

  defp maybe_delete_scans([], _ctx), do: {:ok, %{scans: 0, packages: 0}}
  defp maybe_delete_scans(_eligible, %{dry_run?: true}), do: {:ok, %{scans: 0, packages: 0}}

  defp maybe_delete_scans(eligible, ctx) do
    scan_refs = Enum.map(eligible, & &1.scan_ref)

    # Packages first, in bounded statements, so the scan DELETE has nothing left
    # to cascade into but the scans' artifact rows.
    with {:ok, packages} <- delete_scan_packages(scan_refs, ctx.package_batch_size, 0) do
      sql = """
      DELETE FROM platform.endpoint_inventory_scans
      WHERE id = ANY($1::text[]::uuid[])
      """

      case SQL.query(Repo, sql, [scan_refs], timeout: @query_timeout_ms) do
        {:ok, %{num_rows: deleted}} ->
          {:ok, %{scans: deleted, packages: packages}}

        {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
          {:ok, %{scans: 0, packages: packages}}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp delete_scan_packages(scan_refs, batch_size, deleted) do
    sql = """
    DELETE FROM platform.endpoint_inventory_packages
    WHERE id IN (
      SELECT id
      FROM platform.endpoint_inventory_packages
      WHERE scan_ref = ANY($1::text[]::uuid[])
      LIMIT $2
    )
    """

    case SQL.query(Repo, sql, [scan_refs, batch_size], timeout: @query_timeout_ms) do
      {:ok, %{num_rows: count}} when count < batch_size ->
        {:ok, deleted + count}

      {:ok, %{num_rows: count}} ->
        delete_scan_packages(scan_refs, batch_size, deleted + count)

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        {:ok, deleted}

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
