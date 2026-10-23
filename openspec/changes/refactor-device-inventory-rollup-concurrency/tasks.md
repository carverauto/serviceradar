## 1. Schema Migration & Rollup Functions
- [ ] 1.1 Create an Ecto migration adding `shard smallint NOT NULL DEFAULT 0 CHECK (shard >= 0 AND shard < 64)` to `platform.device_inventory_counts`, `platform.device_inventory_type_counts`, and `platform.device_inventory_vendor_counts` with composite primary keys `(key, shard)`, `(type, shard)`, and `(vendor_name, shard)`.
- [ ] 1.2 Update `platform.apply_device_inventory_rollup_deltas()` to route statement deltas to `mod(abs(hashtextextended(pg_current_xact_id()::text, 0)), 64)::smallint` in deterministic key order (`ORDER BY key`, `ORDER BY type`, `ORDER BY vendor_name`) without calling `pg_advisory_xact_lock` and without clamping per-shard signed deltas at zero.
- [ ] 1.3 Narrow `trg_ocsf_devices_inventory_rollup_update` on `platform.ocsf_devices` to `AFTER UPDATE OF deleted_at, source_retired_at, is_available, type, vendor_name`.
- [ ] 1.4 Replace `TRUNCATE TABLE` in `platform.refresh_device_inventory_rollups()` with transactional `DELETE` + `INSERT ... ON CONFLICT DO UPDATE` into `shard = 0` so full refreshes never acquire `AccessExclusiveLock`.

## 2. Elixir & SRQL Integration
- [ ] 2.1 Remove the redundant, mismatched `pg_advisory_xact_lock(2_026_030_601)` call in `ServiceRadar.Inventory.Sync.DeviceWrites.refresh_inventory_rollups/0` so `platform.refresh_device_inventory_rollups()` owns refresh serialization.
- [ ] 2.2 Update `rust/srql/src/query/devices/stats/rollup.rs` (`execute_inventory_summary_rollup`) to aggregate `SUM(count)::bigint` grouped by `key`, `type`, and `vendor_name` across shards with `HAVING SUM(count) > 0`.

## 3. Verification
- [ ] 3.1 Update `elixir/serviceradar_core/test/serviceradar/inventory/device_inventory_rollup_db_test.exs` to verify concurrent multi-transaction inserts do not block on `pg_advisory_xact_lock` or `shard = 0` when transactions hash to distinct shards, while `SUM(count)` across shards equals exact active inventory totals.
- [ ] 3.2 Add a database regression test proving `SELECT platform.refresh_device_inventory_rollups()` does not acquire `AccessExclusiveLock` on the rollup tables and does not block concurrent `SELECT` readers.
- [ ] 3.3 Add a Rust SRQL test in `rust/srql` verifying `in:devices rollup_stats:inventory_summary` sums positive and negative per-shard deltas accurately and omits types/vendors whose net sum across shards is `<= 0`.
