# Change: Refactor Device Inventory Rollup Triggers to Eliminate Write Serialization

## Why
Every transaction that inserts, deletes, or updates rollup-relevant columns on `platform.ocsf_devices` invokes `platform.apply_device_inventory_rollup_deltas()`, which acquires a global transaction-level advisory lock (`pg_advisory_xact_lock(hashtextextended('serviceradar:device-inventory-rollup', 0))`) and row-level `FOR NO KEY UPDATE` locks on singleton counter rows in `platform.device_inventory_counts`, `platform.device_inventory_type_counts`, and `platform.device_inventory_vendor_counts`. Because PostgreSQL holds transaction-level advisory locks and row locks until `COMMIT` or `ROLLBACK`, concurrent device-mutating transactions serialize globally behind a single lock queue for the remainder of their transaction lifetimes (up to 9.7x lower throughput and 9.4x higher p50 latency at concurrency 16 on `srql-fixtures`), while bulk refreshes (`platform.refresh_device_inventory_rollups()`) execute `TRUNCATE TABLE` and take `AccessExclusiveLock` on all three rollup tables, blocking concurrent SRQL readers.

## What Changes
- **Sharded Inventory Rollup Counters**: Partition `platform.device_inventory_counts`, `platform.device_inventory_type_counts`, and `platform.device_inventory_vendor_counts` across a fixed number of shards (`shard smallint NOT NULL DEFAULT 0 CHECK (shard >= 0 AND shard < 64)`) and remove the global `pg_advisory_xact_lock` from `platform.apply_device_inventory_rollup_deltas()` so concurrent transactions update transaction-hashed shards (`mod(abs(hashtextextended(pg_current_xact_id()::text, 0)), 64)`) in deterministic key order without cross-transaction serialization.
- **Narrowed Update Trigger Column Filter**: Restrict `trg_ocsf_devices_inventory_rollup_update` to `AFTER UPDATE OF deleted_at, source_retired_at, is_available, type, vendor_name ON platform.ocsf_devices` so high-frequency updates to non-rollup columns (`last_seen`, `metadata`, `ip`, `hostname`, `identity_revision`, `availability_state`) do not materialize transition tables or invoke the trigger function.
- **Non-Blocking Rollup Refresh & Unified Lock Key**: Replace `TRUNCATE TABLE` in `platform.refresh_device_inventory_rollups()` with transactional `DELETE` + `INSERT ... ON CONFLICT DO UPDATE` into `shard = 0` (retaining `RowExclusiveLock` instead of `AccessExclusiveLock` so SRQL readers are never blocked), and remove the redundant, mismatched advisory lock (`2_026_030_601`) in `ServiceRadar.Inventory.Sync.DeviceWrites.refresh_inventory_rollups/0`.
- **SRQL Sharded Rollup Aggregation**: Update `rust/srql/src/query/devices/stats/rollup.rs` (`in:devices rollup_stats:inventory_summary`) to aggregate `SUM(count)::bigint` grouped by `key`, `type`, and `vendor_name` across shards, filtering `HAVING SUM(count) > 0`.

## Impact
- Affected specs: `device-inventory`
- Affected code:
  - `elixir/serviceradar_core/priv/repo/migrations/` (new migration updating rollup tables, functions, and update trigger column list)
  - `elixir/serviceradar_core/lib/serviceradar/inventory/sync/device_writes.ex` (`refresh_inventory_rollups/0` lock key alignment)
  - `rust/srql/src/query/devices/stats/rollup.rs` (`execute_inventory_summary_rollup` query aggregation across shards)
  - `elixir/serviceradar_core/test/serviceradar/inventory/device_inventory_rollup_db_test.exs`
