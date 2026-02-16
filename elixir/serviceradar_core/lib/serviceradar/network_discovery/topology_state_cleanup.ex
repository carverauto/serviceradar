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
          local_default_ip_id_updates: non_neg_integer(),
          neighbor_default_ip_id_updates: non_neg_integer(),
          local_mac_id_updates: non_neg_integer(),
          neighbor_mac_id_updates: non_neg_integer(),
          interface_metadata_sanitized: non_neg_integer(),
          invalid_local_device_ids_cleared: non_neg_integer(),
          invalid_neighbor_device_ids_cleared: non_neg_integer(),
          total_updates: non_neg_integer()
        }

  @spec canonicalize_deleted_device_links() :: {:ok, cleanup_stats()} | {:error, term()}
  def canonicalize_deleted_device_links do
    with {:ok, local_count} <- remap_deleted_uid_column(:local_device_id),
         {:ok, neighbor_count} <- remap_deleted_uid_column(:neighbor_device_id),
         {:ok, local_default_ip_count} <- remap_default_ip_column(:local_device_id),
         {:ok, neighbor_default_ip_count} <- remap_default_ip_column(:neighbor_device_id),
         {:ok, local_mac_count} <- remap_mac_like_column(:local_device_id),
         {:ok, neighbor_mac_count} <- remap_mac_like_column(:neighbor_device_id),
         {:ok, interface_metadata_sanitized} <- sanitize_non_unifi_interface_metadata(),
         {:ok, invalid_local_count} <- clear_invalid_id_literals(:local_device_id),
         {:ok, invalid_neighbor_count} <- clear_invalid_id_literals(:neighbor_device_id) do
      total =
        local_count + neighbor_count + local_default_ip_count + neighbor_default_ip_count +
          local_mac_count + neighbor_mac_count + interface_metadata_sanitized +
          invalid_local_count + invalid_neighbor_count

      {:ok,
       %{
         local_device_id_updates: local_count,
         neighbor_device_id_updates: neighbor_count,
         local_default_ip_id_updates: local_default_ip_count,
         neighbor_default_ip_id_updates: neighbor_default_ip_count,
         local_mac_id_updates: local_mac_count,
         neighbor_mac_id_updates: neighbor_mac_count,
         interface_metadata_sanitized: interface_metadata_sanitized,
         invalid_local_device_ids_cleared: invalid_local_count,
         invalid_neighbor_device_ids_cleared: invalid_neighbor_count,
         total_updates: total
       }}
    end
  end

  defp sanitize_non_unifi_interface_metadata do
    sql = """
    UPDATE platform.discovered_interfaces
    SET metadata = metadata
      - 'unifi_api_urls'
      - 'unifi_api_names'
      - 'controller_url'
      - 'controller_name'
      - 'site_id'
      - 'site_name'
      - 'unifi_device_id'
    WHERE COALESCE(metadata->>'source', '') <> 'unifi-api'
      AND metadata ?| ARRAY[
        'unifi_api_urls',
        'unifi_api_names',
        'controller_url',
        'controller_name',
        'site_id',
        'site_name',
        'unifi_device_id'
      ]
    """

    execute_update(sql, :sanitize_non_unifi_interface_metadata)
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

  defp remap_default_ip_column(:local_device_id) do
    sql = """
    WITH default_ip_to_active AS (
      SELECT
        links.local_device_id AS raw_id,
        MIN(dev.uid) AS canonical_uid
      FROM platform.mapper_topology_links AS links
      JOIN platform.ocsf_devices AS dev
        ON dev.deleted_at IS NULL
       AND dev.ip = SPLIT_PART(links.local_device_id, 'default:', 2)
      WHERE links.local_device_id LIKE 'default:%'
      GROUP BY links.local_device_id
      HAVING COUNT(dev.uid) = 1
    )
    UPDATE platform.mapper_topology_links AS links
    SET local_device_id = map.canonical_uid
    FROM default_ip_to_active AS map
    WHERE links.local_device_id = map.raw_id
      AND links.local_device_id <> map.canonical_uid
    """

    execute_update(sql, :local_device_id_default_ip)
  end

  defp remap_default_ip_column(:neighbor_device_id) do
    sql = """
    WITH default_ip_to_active AS (
      SELECT
        links.neighbor_device_id AS raw_id,
        MIN(dev.uid) AS canonical_uid
      FROM platform.mapper_topology_links AS links
      JOIN platform.ocsf_devices AS dev
        ON dev.deleted_at IS NULL
       AND dev.ip = SPLIT_PART(links.neighbor_device_id, 'default:', 2)
      WHERE links.neighbor_device_id LIKE 'default:%'
      GROUP BY links.neighbor_device_id
      HAVING COUNT(dev.uid) = 1
    )
    UPDATE platform.mapper_topology_links AS links
    SET neighbor_device_id = map.canonical_uid
    FROM default_ip_to_active AS map
    WHERE links.neighbor_device_id = map.raw_id
      AND links.neighbor_device_id <> map.canonical_uid
    """

    execute_update(sql, :neighbor_device_id_default_ip)
  end

  defp remap_mac_like_column(:local_device_id) do
    sql = """
    WITH mac_to_active AS (
      SELECT
        links.local_device_id AS raw_id,
        MIN(ids.device_id) AS canonical_uid
      FROM platform.mapper_topology_links AS links
      JOIN platform.device_identifiers AS ids
        ON ids.identifier_type = 'mac'
       AND ids.identifier_value = REGEXP_REPLACE(UPPER(links.local_device_id), '[^0-9A-F]', '', 'g')
      JOIN platform.ocsf_devices AS dev
        ON dev.uid = ids.device_id
       AND dev.deleted_at IS NULL
      WHERE links.local_device_id IS NOT NULL
        AND links.local_device_id NOT LIKE 'sr:%'
        AND links.local_device_id NOT LIKE 'default:%'
        AND LENGTH(REGEXP_REPLACE(UPPER(links.local_device_id), '[^0-9A-F]', '', 'g')) = 12
      GROUP BY links.local_device_id
      HAVING COUNT(DISTINCT ids.device_id) = 1
    )
    UPDATE platform.mapper_topology_links AS links
    SET local_device_id = map.canonical_uid
    FROM mac_to_active AS map
    WHERE links.local_device_id = map.raw_id
      AND links.local_device_id <> map.canonical_uid
    """

    execute_update(sql, :local_device_id_mac)
  end

  defp remap_mac_like_column(:neighbor_device_id) do
    sql = """
    WITH mac_to_active AS (
      SELECT
        links.neighbor_device_id AS raw_id,
        MIN(ids.device_id) AS canonical_uid
      FROM platform.mapper_topology_links AS links
      JOIN platform.device_identifiers AS ids
        ON ids.identifier_type = 'mac'
       AND ids.identifier_value = REGEXP_REPLACE(UPPER(links.neighbor_device_id), '[^0-9A-F]', '', 'g')
      JOIN platform.ocsf_devices AS dev
        ON dev.uid = ids.device_id
       AND dev.deleted_at IS NULL
      WHERE links.neighbor_device_id IS NOT NULL
        AND links.neighbor_device_id NOT LIKE 'sr:%'
        AND links.neighbor_device_id NOT LIKE 'default:%'
        AND LENGTH(REGEXP_REPLACE(UPPER(links.neighbor_device_id), '[^0-9A-F]', '', 'g')) = 12
      GROUP BY links.neighbor_device_id
      HAVING COUNT(DISTINCT ids.device_id) = 1
    )
    UPDATE platform.mapper_topology_links AS links
    SET neighbor_device_id = map.canonical_uid
    FROM mac_to_active AS map
    WHERE links.neighbor_device_id = map.raw_id
      AND links.neighbor_device_id <> map.canonical_uid
    """

    execute_update(sql, :neighbor_device_id_mac)
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
