defmodule ServiceRadar.Repo.Migrations.AddDireReconciliationIndexes do
  @moduledoc """
  Indexes for the DIRE / topology reconciliation maintenance queries that were
  doing full-table/seq scans every cycle to touch a handful of rows (~13% of CNPG
  CPU between this and the discovered_interfaces GIN).

  (1) ocsf_devices_deleted_ip_idx — the stale-side (deleted_at IS NOT NULL) partial
      ip index. ocsf_devices already had a partial ip index for the ACTIVE side
      (deleted_at IS NULL) but nothing for the stale side, so the stale_to_active
      self-join (TopologyStateCleanup.remap_deleted_uid_column/1) and the
      stale_active_ip_overlap_exists? gate both Seq Scanned the deleted side. Live
      EXPLAIN: the join now uses Bitmap Index Scan on this index + Nested Loop.

  (2) device_identifiers_dup_group_covering_idx — covering index for the duplicate
      identifier array_agg (Inventory.Identity.DuplicateSweep). The existing unique
      index orders the GROUP BY but lacks device_id, forcing a 369k-row Sort; INCLUDE
      (device_id) makes the GroupAggregate index-only. Live EXPLAIN: cost 99941 -> 66000,
      Index Only Scan + Incremental Sort (no full sort).
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS ocsf_devices_deleted_ip_idx
    ON platform.ocsf_devices (ip)
    WHERE deleted_at IS NOT NULL AND ip IS NOT NULL AND ip <> ''
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS device_identifiers_dup_group_covering_idx
    ON platform.device_identifiers (identifier_type, identifier_value, partition)
    INCLUDE (device_id)
    WHERE device_id NOT LIKE 'serviceradar:%'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.ocsf_devices_deleted_ip_idx")

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS platform.device_identifiers_dup_group_covering_idx"
    )
  end
end
