defmodule ServiceRadar.NetworkDiscovery.TopologyStateCleanup do
  @moduledoc """
  Canonicalizes stale topology endpoint IDs in `platform.mapper_topology_links`.

  Device UIDs can change over time (for example after identity conflict resolution)
  while historical topology rows keep the previous UID. This module remaps link
  endpoints from deleted UIDs to the single active UID that owns the same IP.
  """

  alias ServiceRadar.Repo

  require Logger

  @type cleanup_stats :: %{
          local_device_id_updates: non_neg_integer(),
          neighbor_device_id_updates: non_neg_integer(),
          invalid_local_device_ids_cleared: non_neg_integer(),
          invalid_neighbor_device_ids_cleared: non_neg_integer(),
          total_updates: non_neg_integer()
        }

  @spec canonicalize_deleted_device_links() :: {:ok, cleanup_stats()} | {:error, term()}
  def canonicalize_deleted_device_links do
    with {:ok, local_count} <- remap_deleted_uid_column(:local_device_id),
         {:ok, neighbor_count} <- remap_deleted_uid_column(:neighbor_device_id),
         {:ok, invalid_local_count} <- clear_invalid_id_literals(:local_device_id),
         {:ok, invalid_neighbor_count} <- clear_invalid_id_literals(:neighbor_device_id) do
      total = local_count + neighbor_count + invalid_local_count + invalid_neighbor_count

      {:ok,
       %{
         local_device_id_updates: local_count,
         neighbor_device_id_updates: neighbor_count,
         invalid_local_device_ids_cleared: invalid_local_count,
         invalid_neighbor_device_ids_cleared: invalid_neighbor_count,
         total_updates: total
       }}
    end
  end

  defp remap_deleted_uid_column(:local_device_id) do
    sql = """
    WITH stale_to_active AS (
      SELECT
        stale.uid AS stale_uid,
        MIN(active.uid) AS canonical_uid
      FROM platform.ocsf_devices AS stale
      JOIN platform.ocsf_devices AS active
        ON active.deleted_at IS NULL
       AND stale.deleted_at IS NOT NULL
       AND stale.ip IS NOT NULL
       AND stale.ip <> ''
       AND active.ip = stale.ip
      GROUP BY stale.uid
      HAVING COUNT(active.uid) = 1
         AND MIN(active.uid) <> stale.uid
    )
    UPDATE platform.mapper_topology_links AS links
    SET local_device_id = map.canonical_uid
    FROM stale_to_active AS map
    WHERE links.local_device_id = map.stale_uid
      AND links.local_device_id <> map.canonical_uid
    """

    execute_update(sql, :local_device_id)
  end

  defp remap_deleted_uid_column(:neighbor_device_id) do
    sql = """
    WITH stale_to_active AS (
      SELECT
        stale.uid AS stale_uid,
        MIN(active.uid) AS canonical_uid
      FROM platform.ocsf_devices AS stale
      JOIN platform.ocsf_devices AS active
        ON active.deleted_at IS NULL
       AND stale.deleted_at IS NOT NULL
       AND stale.ip IS NOT NULL
       AND stale.ip <> ''
       AND active.ip = stale.ip
      GROUP BY stale.uid
      HAVING COUNT(active.uid) = 1
         AND MIN(active.uid) <> stale.uid
    )
    UPDATE platform.mapper_topology_links AS links
    SET neighbor_device_id = map.canonical_uid
    FROM stale_to_active AS map
    WHERE links.neighbor_device_id = map.stale_uid
      AND links.neighbor_device_id <> map.canonical_uid
    """

    execute_update(sql, :neighbor_device_id)
  end

  defp clear_invalid_id_literals(:local_device_id) do
    sql = """
    UPDATE platform.mapper_topology_links
    SET local_device_id = NULL
    WHERE LOWER(BTRIM(COALESCE(local_device_id, ''))) IN ('nil', 'null', 'undefined')
    """

    execute_update(sql, :local_device_id_invalid_literals)
  end

  defp clear_invalid_id_literals(:neighbor_device_id) do
    sql = """
    UPDATE platform.mapper_topology_links
    SET neighbor_device_id = NULL
    WHERE LOWER(BTRIM(COALESCE(neighbor_device_id, ''))) IN ('nil', 'null', 'undefined')
    """

    execute_update(sql, :neighbor_device_id_invalid_literals)
  end

  defp execute_update(sql, label) do
    case Ecto.Adapters.SQL.query(Repo, sql, []) do
      {:ok, %{num_rows: count}} ->
        {:ok, count}

      {:error, reason} ->
        Logger.warning("Topology state canonicalization failed",
          column: label,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end
end
