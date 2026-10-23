# Change: Refactor Device Inventory Rollup Triggers to Eliminate Write Serialization

## Why
Every insert, update, or delete on `platform.ocsf_devices` fires `platform.trg_ocsf_devices_inventory_rollup_{insert,update,delete}()`. A statement with a net counter change takes `pg_advisory_xact_lock(hashtextextended('serviceradar:device-inventory-rollup', 0))` and upserts singleton rows in `platform.device_inventory_counts` (column `value`), `platform.device_inventory_type_counts` (column `count`), and `platform.device_inventory_vendor_counts` (column `count`). PostgreSQL holds that advisory lock and the upsert row locks until `COMMIT` or `ROLLBACK`, so concurrent device-mutating transactions serialize for the rest of the transaction (up to 9.7x lower throughput and 9.4x higher p50 latency at concurrency 16 with a 25 ms post-insert hold on `srql-fixtures` database `codex_rollup_bench_1792731434_52021`). `platform.refresh_device_inventory_rollups()` `TRUNCATE`s each rollup table and takes `AccessExclusiveLock`, which blocks concurrent SRQL readers. The Elixir refresh path takes a different advisory key, `20_240_306`; the SQL refresh function does not take the trigger lock.

## What Changes
- **Sharded Inventory Rollup Counters**: Partition `platform.device_inventory_counts`, `platform.device_inventory_type_counts`, and `platform.device_inventory_vendor_counts` across a fixed number of shards (`shard smallint NOT NULL DEFAULT 0 CHECK (shard >= 0 AND shard < 64)`) and move the inline counter writes out of the three statement triggers into `platform.apply_device_inventory_rollup_deltas()`. That function does not take `pg_advisory_xact_lock`. Concurrent transactions update transaction-hashed shards (`mod(abs(hashtextextended(pg_current_xact_id()::text, 0)), 64)`) in deterministic key order. Status rows keep the `value` column; type and vendor rows keep `count`.
- **Narrowed Update Trigger Column Filter**: Restrict `trg_ocsf_devices_inventory_rollup_update` to `AFTER UPDATE OF deleted_at, source_retired_at, is_available, type, vendor_name ON platform.ocsf_devices` so high-frequency updates to non-rollup columns (`last_seen`, `metadata`, `ip`, `hostname`, `identity_revision`, `availability_state`) do not materialize transition tables or invoke the trigger function.
- **Non-Blocking Rollup Refresh & Unified Lock Key**: Replace the per-table `TRUNCATE` in `platform.refresh_device_inventory_rollups()` with transactional `DELETE` + `INSERT ... ON CONFLICT DO UPDATE` into `shard = 0` (row locks instead of `AccessExclusiveLock`, so SRQL readers are not blocked). Drop the separate `pg_advisory_xact_lock(20_240_306)` in `ServiceRadar.Inventory.Sync.DeviceWrites` so the SQL refresh function is the only refresh lock.
- **SRQL Sharded Rollup Aggregation**: Update `build_rollup_stats_query/1` in `rust/srql/src/query/devices/stats/rollup.rs` (`in:devices rollup_stats:inventory_summary`) to aggregate `SUM(value)` for status keys and `SUM(count)` for `type` and `vendor_name` across shards, omitting type and vendor groups whose sum is `<= 0`.

## Impact
- Affected specs: `device-inventory`
- Affected code:
  - `elixir/serviceradar_core/priv/repo/migrations/` (new migration updating rollup tables, functions, and update trigger column list)
  - `elixir/serviceradar_core/lib/serviceradar/inventory/sync/device_writes.ex` (drop the `20_240_306` refresh lock)
  - `rust/srql/src/query/devices/stats/rollup.rs` (`build_rollup_stats_query/1` sums shards)
  - `elixir/serviceradar_core/test/serviceradar/inventory/device_inventory_rollup_db_test.exs`
