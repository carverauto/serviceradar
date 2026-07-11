defmodule ServiceRadar.NetworkDiscovery.TopologyStateCleanup do
  @moduledoc """
  Canonicalizes stale topology endpoint IDs in `platform.mapper_topology_links`.

  Device UIDs can change over time (for example after identity conflict resolution)
  while historical topology rows keep the previous UID. This module remaps link
  endpoints from deleted UIDs to the single active UID that owns the same IP.
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Repo

  require Logger

  @cleanup_timeout_ms 120_000
  @lock_timeout "5s"

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
    case stale_active_ip_overlap_exists?() do
      {:ok, false} -> {:ok, zero_stats()}
      {:ok, true} -> run_canonicalization()
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_canonicalization do
    with {:ok, stats} <- run_endpoint_canonicalization(),
         {:ok, interface_metadata_sanitized} <- sanitize_non_unifi_interface_metadata() do
      total_updates =
        stats.local_device_id_updates + stats.neighbor_device_id_updates +
          stats.local_default_ip_id_updates + stats.neighbor_default_ip_id_updates +
          stats.local_mac_id_updates + stats.neighbor_mac_id_updates +
          stats.invalid_local_device_ids_cleared + stats.invalid_neighbor_device_ids_cleared +
          interface_metadata_sanitized

      {:ok,
       stats
       |> Map.put(:interface_metadata_sanitized, interface_metadata_sanitized)
       |> Map.put(:total_updates, total_updates)}
    end
  end

  defp run_endpoint_canonicalization do
    Repo.transaction(
      fn ->
        with :ok <- acquire_topology_mutation_barrier(),
             {:ok, local_count} <- remap_deleted_uid_column(:local_device_id),
             {:ok, neighbor_count} <- remap_deleted_uid_column(:neighbor_device_id),
             {:ok, local_default_ip_count} <- remap_default_ip_column(:local_device_id),
             {:ok, neighbor_default_ip_count} <- remap_default_ip_column(:neighbor_device_id),
             {:ok, local_mac_count} <- remap_mac_like_column(:local_device_id),
             {:ok, neighbor_mac_count} <- remap_mac_like_column(:neighbor_device_id),
             {:ok, invalid_local_count} <- clear_invalid_id_literals(:local_device_id),
             {:ok, invalid_neighbor_count} <- clear_invalid_id_literals(:neighbor_device_id) do
          %{
            local_device_id_updates: local_count,
            neighbor_device_id_updates: neighbor_count,
            local_default_ip_id_updates: local_default_ip_count,
            neighbor_default_ip_id_updates: neighbor_default_ip_count,
            local_mac_id_updates: local_mac_count,
            neighbor_mac_id_updates: neighbor_mac_count,
            invalid_local_device_ids_cleared: invalid_local_count,
            invalid_neighbor_device_ids_cleared: invalid_neighbor_count
          }
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      timeout: @cleanup_timeout_ms
    )
  end

  # Mapper ingest does not participate in a shared advisory lock. Keep its
  # INSERT/UPDATE path out of the short delete-then-remap interval so a new
  # canonical logical key cannot appear between those two statements.
  defp acquire_topology_mutation_barrier do
    with {:ok, _result} <-
           SQL.query(Repo, "SELECT set_config('lock_timeout', $1, true)", [@lock_timeout]),
         {:ok, _result} <-
           SQL.query(Repo, "SELECT set_config('statement_timeout', $1, true)", ["120s"]),
         {:ok, _result} <-
           SQL.query(
             Repo,
             "LOCK TABLE platform.mapper_topology_links IN SHARE ROW EXCLUSIVE MODE",
             [],
             timeout: @cleanup_timeout_ms
           ) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Topology state canonicalization lock failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  # Cheap early-return guard. The expensive remaps only do work when at least one
  # deleted (stale) device shares an IP with a live (active) device. Probe that with a
  # single indexed EXISTS so the common no-op case skips the endpoint cleanup passes.
  defp stale_active_ip_overlap_exists? do
    sql = """
    SELECT EXISTS (
      SELECT 1
      FROM platform.ocsf_devices AS stale
      JOIN platform.ocsf_devices AS active
        ON active.ip = stale.ip
       AND active.deleted_at IS NULL
       AND stale.deleted_at IS NOT NULL
       AND stale.ip IS NOT NULL
       AND stale.ip <> ''
      LIMIT 1
    ) AS overlap
    """

    case SQL.query(Repo, sql, []) do
      {:ok, %{rows: [[overlap]]}} ->
        {:ok, overlap == true}

      {:error, reason} ->
        Logger.warning("Topology stale/active overlap probe failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp zero_stats do
    %{
      local_device_id_updates: 0,
      neighbor_device_id_updates: 0,
      local_default_ip_id_updates: 0,
      neighbor_default_ip_id_updates: 0,
      local_mac_id_updates: 0,
      neighbor_mac_id_updates: 0,
      interface_metadata_sanitized: 0,
      invalid_local_device_ids_cleared: 0,
      invalid_neighbor_device_ids_cleared: 0,
      total_updates: 0
    }
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
    mapping_sql = """
      SELECT
        stale.uid AS raw_id,
        MIN(active.uid) AS canonical_uid
      FROM platform.ocsf_devices AS stale
      JOIN platform.ocsf_devices AS active
        ON active.deleted_at IS NULL
       AND active.ip IS NOT NULL
       AND active.ip <> ''
       AND stale.deleted_at IS NOT NULL
       AND stale.ip IS NOT NULL
       AND stale.ip <> ''
       AND active.ip = stale.ip
      GROUP BY stale.uid
      HAVING COUNT(active.uid) = 1
         AND MIN(active.uid) <> stale.uid
    """

    remap_endpoint_column(:local_device_id, mapping_sql, :local_device_id)
  end

  defp remap_deleted_uid_column(:neighbor_device_id) do
    mapping_sql = """
      SELECT
        stale.uid AS raw_id,
        MIN(active.uid) AS canonical_uid
      FROM platform.ocsf_devices AS stale
      JOIN platform.ocsf_devices AS active
        ON active.deleted_at IS NULL
       AND active.ip IS NOT NULL
       AND active.ip <> ''
       AND stale.deleted_at IS NOT NULL
       AND stale.ip IS NOT NULL
       AND stale.ip <> ''
       AND active.ip = stale.ip
      GROUP BY stale.uid
      HAVING COUNT(active.uid) = 1
         AND MIN(active.uid) <> stale.uid
    """

    remap_endpoint_column(:neighbor_device_id, mapping_sql, :neighbor_device_id)
  end

  defp clear_invalid_id_literals(:local_device_id) do
    mapping_sql = """
    SELECT DISTINCT local_device_id AS raw_id, ''::text AS canonical_uid
    FROM platform.mapper_topology_links
    WHERE LOWER(BTRIM(local_device_id)) IN ('nil', 'null', 'undefined')
    """

    remap_endpoint_column(
      :local_device_id,
      mapping_sql,
      :local_device_id_invalid_literals
    )
  end

  defp clear_invalid_id_literals(:neighbor_device_id) do
    mapping_sql = """
    SELECT DISTINCT neighbor_device_id AS raw_id, ''::text AS canonical_uid
    FROM platform.mapper_topology_links
    WHERE LOWER(BTRIM(neighbor_device_id)) IN ('nil', 'null', 'undefined')
    """

    remap_endpoint_column(
      :neighbor_device_id,
      mapping_sql,
      :neighbor_device_id_invalid_literals
    )
  end

  defp remap_default_ip_column(:local_device_id) do
    mapping_sql = """
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
    """

    remap_endpoint_column(:local_device_id, mapping_sql, :local_device_id_default_ip)
  end

  defp remap_default_ip_column(:neighbor_device_id) do
    mapping_sql = """
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
    """

    remap_endpoint_column(:neighbor_device_id, mapping_sql, :neighbor_device_id_default_ip)
  end

  defp remap_mac_like_column(:local_device_id) do
    mapping_sql = """
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
    """

    remap_endpoint_column(:local_device_id, mapping_sql, :local_device_id_mac)
  end

  defp remap_mac_like_column(:neighbor_device_id) do
    mapping_sql = """
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
    """

    remap_endpoint_column(:neighbor_device_id, mapping_sql, :neighbor_device_id_mac)
  end

  # Remapping an endpoint can collapse two formerly distinct rows onto the
  # logical-key unique index. Rank the source rows and any existing destination
  # rows together, retain the newest evidence, delete the losers, then update
  # the surviving source. The caller holds a table mutation barrier and wraps
  # all endpoint remap phases in one transaction.
  defp remap_endpoint_column(column, mapping_sql, label)
       when column in [:local_device_id, :neighbor_device_id] do
    {projected_local_device_id, projected_neighbor_device_id} =
      projected_endpoint_columns(column)

    merge_sql = """
    WITH endpoint_map AS MATERIALIZED (
      #{mapping_sql}
    ),
    mapped_sources AS MATERIALIZED (
      SELECT
        links.id,
        #{projected_local_device_id} AS local_device_id,
        #{projected_neighbor_device_id} AS neighbor_device_id,
        links.local_if_index,
        links.neighbor_port_id,
        links.protocol,
        links.neighbor_chassis_id,
        COALESCE(links.created_at, links.timestamp) AS observed_at
      FROM platform.mapper_topology_links AS links
      JOIN endpoint_map AS map
        ON links.#{column} = map.raw_id
      WHERE links.#{column} <> map.canonical_uid
    ),
    affected_keys AS MATERIALIZED (
      SELECT DISTINCT
        local_device_id,
        neighbor_device_id,
        local_if_index,
        neighbor_port_id,
        protocol,
        neighbor_chassis_id
      FROM mapped_sources
    ),
    affected_rows AS (
      SELECT
        source.id,
        source.local_device_id,
        source.neighbor_device_id,
        source.local_if_index,
        source.neighbor_port_id,
        source.protocol,
        source.neighbor_chassis_id,
        source.observed_at
      FROM mapped_sources AS source

      UNION ALL

      SELECT
        links.id,
        links.local_device_id,
        links.neighbor_device_id,
        links.local_if_index,
        links.neighbor_port_id,
        links.protocol,
        links.neighbor_chassis_id,
        COALESCE(links.created_at, links.timestamp) AS observed_at
      FROM platform.mapper_topology_links AS links
      JOIN affected_keys AS key
        ON links.local_device_id = key.local_device_id
       AND links.neighbor_device_id = key.neighbor_device_id
       AND links.local_if_index = key.local_if_index
       AND links.neighbor_port_id = key.neighbor_port_id
       AND links.protocol = key.protocol
       AND links.neighbor_chassis_id = key.neighbor_chassis_id
      WHERE NOT EXISTS (
        SELECT 1
        FROM mapped_sources AS source
        WHERE source.id = links.id
      )
    ),
    ranked AS (
      SELECT
        id,
        ROW_NUMBER() OVER (
          PARTITION BY
            local_device_id,
            neighbor_device_id,
            local_if_index,
            neighbor_port_id,
            protocol,
            neighbor_chassis_id
          ORDER BY observed_at DESC NULLS LAST, id DESC
        ) AS row_rank
      FROM affected_rows
    )
    DELETE FROM platform.mapper_topology_links AS links
    USING ranked
    WHERE links.id = ranked.id
      AND ranked.row_rank > 1
    """

    update_sql = """
    WITH endpoint_map AS MATERIALIZED (
      #{mapping_sql}
    )
    UPDATE platform.mapper_topology_links AS links
    SET #{column} = map.canonical_uid
    FROM endpoint_map AS map
    WHERE links.#{column} = map.raw_id
      AND links.#{column} <> map.canonical_uid
    """

    with {:ok, merged_count} <- execute_update(merge_sql, label),
         {:ok, updated_count} <- execute_update(update_sql, label) do
      {:ok, merged_count + updated_count}
    end
  end

  defp projected_endpoint_columns(:local_device_id) do
    {"map.canonical_uid", "links.neighbor_device_id"}
  end

  defp projected_endpoint_columns(:neighbor_device_id) do
    {"links.local_device_id", "map.canonical_uid"}
  end

  defp execute_update(sql, label) do
    case SQL.query(Repo, sql, [], timeout: @cleanup_timeout_ms) do
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
