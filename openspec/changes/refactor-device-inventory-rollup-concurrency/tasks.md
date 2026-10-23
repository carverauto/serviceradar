## 1. Schema Migration & Rollup Functions
- [ ] 1.1 Create an Ecto migration adding `shard smallint NOT NULL DEFAULT 0 CHECK (shard >= 0 AND shard < 64)` to `platform.device_inventory_counts`, `platform.device_inventory_type_counts`, and `platform.device_inventory_vendor_counts` with composite primary keys `(key, shard)`, `(type, shard)`, and `(vendor_name, shard)`.
- [ ] 1.2 Add `platform.apply_device_inventory_rollup_deltas()` and call it from the three statement triggers. Route deltas to `mod(abs(hashtextextended(pg_current_xact_id()::text, 0)), 64)::smallint` in deterministic key order (`ORDER BY key`, `ORDER BY type`, `ORDER BY vendor_name`) without `pg_advisory_xact_lock`. Write status deltas to `value` and type/vendor deltas to `count`. Do not delete a type or vendor row whose shard count is `<= 0`.
- [ ] 1.3 Narrow `trg_ocsf_devices_inventory_rollup_update` on `platform.ocsf_devices` to `AFTER UPDATE OF deleted_at, source_retired_at, is_available, type, vendor_name`.
- [ ] 1.4 Replace `TRUNCATE TABLE` in `platform.refresh_device_inventory_rollups()` with transactional `DELETE` + `INSERT ... ON CONFLICT DO UPDATE` into `shard = 0` so full refreshes never acquire `AccessExclusiveLock`.

## 2. Elixir & SRQL Integration
- [ ] 2.1 Remove `pg_advisory_xact_lock(20_240_306)` from `ServiceRadar.Inventory.Sync.DeviceWrites.refresh_inventory_rollups_in_transaction/0` so `platform.refresh_device_inventory_rollups()` owns refresh serialization.
- [ ] 2.2 Update `build_rollup_stats_query/1` in `rust/srql/src/query/devices/stats/rollup.rs` to aggregate `SUM(value)` by status `key` and `SUM(count)` by `type` and `vendor_name` across shards, with `HAVING SUM(count) > 0` on type and vendor.

## 3. Verification
- [ ] 3.1 Update `elixir/serviceradar_core/test/serviceradar/inventory/device_inventory_rollup_db_test.exs` to verify concurrent multi-transaction inserts do not block on `pg_advisory_xact_lock` or on `shard = 0` when transactions hash to distinct shards, while `SUM(value)` for status keys and `SUM(count)` for type and vendor equal the active inventory.
- [ ] 3.2 Add a database regression test proving `SELECT platform.refresh_device_inventory_rollups()` does not acquire `AccessExclusiveLock` on the rollup tables and does not block concurrent `SELECT` readers.
- [ ] 3.3 Add a Rust SRQL test in `rust/srql` verifying `in:devices rollup_stats:inventory_summary` sums positive and negative per-shard deltas accurately and omits types/vendors whose net sum across shards is `<= 0`.
