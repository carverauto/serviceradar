defmodule ServiceRadar.Repo.Migrations.AddOcsfDevicesManagedActiveCountIndex do
  @moduledoc """
  Adds a partial index for the managed/active device count.

  `ServiceRadarWebNG.TenantUsage.managed_device_count/0` runs
  `SELECT count(*) FROM platform.ocsf_devices WHERE deleted_at IS NULL
   AND is_managed AND is_active` about once per second (device-list refresh).
  `platform.ocsf_devices` is a regular 86k-row heap with no index matching that
  all-boolean predicate, so each call is a full sequential scan
  (live EXPLAIN: `Seq Scan ... cost=0.00..19310`). Only ~44 rows actually match.

  A partial index keyed on `uid` (NOT NULL) over the exact predicate turns the
  count into an index-only scan over the matching set. Built `CONCURRENTLY`
  + `IF NOT EXISTS`; purely additive, results unchanged.

  Note: the DIRE reconcile self-joins on this table need a query rewrite (in
  `topology_state_cleanup.ex`) rather than an index, and are handled separately.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS ocsf_devices_managed_active_live_idx
    ON platform.ocsf_devices (uid)
    WHERE deleted_at IS NULL AND is_managed AND is_active
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.ocsf_devices_managed_active_live_idx")
  end
end
