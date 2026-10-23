## Context

### 1. Inventory of Rollup Tables, Triggers, and Functions

#### Rollup Tables (`elixir/serviceradar_core/priv/repo/migrations/20260305110000_add_device_inventory_rollup_tables.exs`, also `platform_schema.sql:6280-6306`)
- `platform.device_inventory_counts (key text PRIMARY KEY, value bigint NOT NULL DEFAULT 0, updated_at timestamptz NOT NULL DEFAULT now())` — three singleton rows: `key IN ('total', 'available', 'unavailable')`. The counter column is `value`, not `count`.
- `platform.device_inventory_type_counts (type text PRIMARY KEY, count bigint NOT NULL DEFAULT 0, updated_at timestamptz NOT NULL DEFAULT now())` — one row per normalized device `type` (`COALESCE(NULLIF(trim(type), ''), 'Unknown')`).
- `platform.device_inventory_vendor_counts (vendor_name text PRIMARY KEY, count bigint NOT NULL DEFAULT 0, updated_at timestamptz NOT NULL DEFAULT now())` — one row per normalized `vendor_name` (`COALESCE(NULLIF(trim(vendor_name), ''), 'Unknown')`).

#### Triggers on `platform.ocsf_devices`
Inspection of `pg_trigger` on a fully migrated schema (`mix serviceradar.db.migrate`) shows 15 user triggers on `platform.ocsf_devices`:

| Trigger Name | Timing / Scope | Event & Condition | Function | Cross-Transaction Contention |
|---|---|---|---|---|
| `device_location_sync` | `BEFORE FOR EACH ROW` | `INSERT OR UPDATE OF metadata` | `sync_device_location()` | None (mutates `NEW` only) |
| `trg_clear_restored_identity_purge` | `BEFORE FOR EACH ROW` | `UPDATE OF deleted_at WHEN (old.deleted_at IS NOT NULL AND new.deleted_at IS NULL)` | `clear_restored_identity_purge()` | None (mutates `NEW` only) |
| `trg_ocsf_devices_availability_mirror` | `BEFORE FOR EACH ROW` | `INSERT OR UPDATE OF is_available, availability_state` | `trg_ocsf_devices_availability_mirror()` | None (mutates `NEW` only) |
| `trg_ocsf_devices_source_retired_mirror` | `BEFORE FOR EACH ROW` | `INSERT OR UPDATE WHEN (new.source_retired_at IS NOT NULL OR ...)` | `trg_ocsf_devices_source_retired_mirror()` | None (mutates `NEW` only) |
| `trg_device_fleet_identity_insert` | `AFTER FOR EACH ROW` | `INSERT` | `sync_device_fleet_identity()` -> `ensure_device_fleet_ordinal(NEW.uid)` | Per-device `uid` only (`FOR NO KEY UPDATE` on `uid = NEW.uid`, sequence allocation in `device_fleet_ordinals`) |
| `trg_device_fleet_identity_update` | `AFTER FOR EACH ROW` | `UPDATE OF deleted_at, deleted_reason, is_active` | `sync_device_fleet_identity()` | Per-device `uid` only |
| `trg_ocsf_devices_availability_insert_invalidate` | `AFTER FOR EACH ROW` | `INSERT WHEN (new.deleted_at IS NULL)` | `trg_ocsf_devices_availability_lifecycle_invalidate()` | Per-device `device_uid` only |
| `trg_ocsf_devices_availability_legacy_insert` | `AFTER FOR EACH ROW` | `INSERT` | `trg_ocsf_devices_availability_legacy()` | Per-device `device_uid` only |
| `trg_ocsf_devices_availability_legacy_update` | `AFTER FOR EACH ROW` | `UPDATE OF is_available WHEN (old.is_available IS DISTINCT FROM new.is_available)` | `trg_ocsf_devices_availability_legacy()` | Per-device `device_uid` only |
| `trg_ocsf_devices_availability_pin_invalidate` | `AFTER FOR EACH ROW` | `UPDATE OF availability_source_agent_id` | `trg_ocsf_devices_availability_pin_invalidate()` | Per-device `device_uid` only |
| `trg_ocsf_devices_availability_restore_invalidate` | `AFTER FOR EACH ROW` | `UPDATE OF deleted_at WHEN (old.deleted_at IS NOT NULL AND new.deleted_at IS NULL)` | `trg_ocsf_devices_availability_lifecycle_invalidate()` | Per-device `device_uid` only |
| `trg_ocsf_devices_revival_audit` | `AFTER FOR EACH ROW` | `UPDATE WHEN (old.deleted_at IS NOT NULL AND new.deleted_at IS NULL)` | `trg_ocsf_devices_revival_audit()` | Append-only insert into `device_revival_audit` |
| **`trg_ocsf_devices_inventory_rollup_insert`** | **`AFTER FOR EACH STATEMENT`** | **`INSERT REFERENCING NEW TABLE AS inventory_new`** | **`trg_ocsf_devices_inventory_rollup_insert()`** | **Global advisory lock + singleton counter rows** |
| **`trg_ocsf_devices_inventory_rollup_update`** | **`AFTER FOR EACH STATEMENT`** | **`UPDATE REFERENCING OLD TABLE AS inventory_old NEW TABLE AS inventory_new`** | **`trg_ocsf_devices_inventory_rollup_update()`** | **Global advisory lock + singleton counter rows; fires on ALL updates** |
| **`trg_ocsf_devices_inventory_rollup_delete`** | **`AFTER FOR EACH STATEMENT`** | **`DELETE REFERENCING OLD TABLE AS inventory_old`** | **`trg_ocsf_devices_inventory_rollup_delete()`** | **Global advisory lock + singleton counter rows** |

#### Historical Evolution of the Rollup Triggers
1. `20260305110000_add_device_inventory_rollup_tables.exs`: Introduced `platform.device_inventory_counts`, `device_inventory_type_counts`, `device_inventory_vendor_counts`, `refresh_device_inventory_rollups()`, and a `FOR EACH ROW` trigger `trg_ocsf_devices_inventory_rollup` calling `update_device_inventory_counts_row(...)`.
2. `20260306001000_optimize_device_inventory_rollup_bulk_sync.exs`: Added the transaction-local `current_setting('platform.skip_inventory_rollup', true) = 'on'` bypass in `trg_ocsf_devices_inventory_rollup()` and a `TRUNCATE`-based `refresh_device_inventory_rollups()`.
3. `20261005120000_mark_source_retired_devices.exs`: Excluded `source_retired_at IS NOT NULL` devices from active rollup counts and replaced `refresh_device_inventory_rollups()` with the current three-`TRUNCATE` body. That function does not take an advisory lock.
4. `20261019150000_batch_device_inventory_rollups.exs`: Replaced the row trigger with three `FOR EACH STATEMENT` transition-table triggers. Each function aggregates the transition table with a CTE and, on a non-zero delta, takes the advisory lock and upserts counters inline. There is no `platform.apply_device_inventory_rollup_deltas()` and no `pg_temp` delta table. The sequential batch measurement lives in `docs/device-inventory-rollup-performance.md`.

#### Why `20261019150000_batch_device_inventory_rollups.exs` Still Serializes Concurrent Transactions
Statement-level transition tables reduced the cost of a multi-row statement. The three trigger functions still serialize concurrent transactions:
1. **Global transaction-scoped advisory lock.** Each function, on its first non-zero delta, executes `PERFORM pg_advisory_xact_lock(hashtextextended('serviceradar:device-inventory-rollup', 0))`. That exclusive lock is held until the enclosing transaction commits or rolls back, so a later statement in the same transaction keeps every other device write behind it. `refresh_device_inventory_rollups()` does not take this lock. A refresh still blocks writers because each `TRUNCATE` needs `AccessExclusiveLock` on a rollup table.
2. **Singleton counter rows.** Even without the advisory lock, an active insert upserts `device_inventory_counts` for `key = 'total'` and either `'available'` or `'unavailable'` (`ON CONFLICT (key) DO UPDATE` of `value`), plus the matching type and vendor rows (`count`). Those row locks last until transaction end.
3. **Unfiltered `AFTER UPDATE` transition tables.** `trg_ocsf_devices_inventory_rollup_update` is `AFTER UPDATE ON platform.ocsf_devices` with no `OF` column list. Every update, including `last_seen`, `metadata`, `ip`, `identity_revision`, and `availability_state`, materializes `inventory_old` and `inventory_new` and runs the delta CTEs. A zero net change takes no advisory lock.

---

### 2. Inventory of All Writers and Readers

#### Writers to `platform.ocsf_devices` and `platform.device_inventory_*`
1. **Sync ingestion (`ServiceRadar.Inventory.Sync.DeviceWrites`)**:
   - `bulk_upsert_devices/4` (`device_writes.ex:93-96`) sets `refresh_rollups?` from `inventory_rollup_bulk_refresh_required?/1`. The default threshold is `10_000` (`@default_inventory_rollup_bulk_refresh_threshold`, `device_writes.ex:40`), overridable with `:inventory_rollup_bulk_refresh_threshold`.
   - At or below that threshold the statement triggers run inside the upsert. Fenced callers invoke this inside `Identity.Fence.fenced_write/3`, so a taken advisory lock is held until that transaction commits.
   - Above the threshold, `with_inventory_rollup_bypassed/1` (`device_writes.ex:1700-1704`) sets `SET LOCAL platform.skip_inventory_rollup = 'on'` around the write. After the batches finish, `SyncIngestor` calls `DeviceWrites.maybe_refresh_inventory_rollups/2` (`sync_ingestor.ex:82`).
   - **Separate refresh lock and `TRUNCATE`.** `refresh_inventory_rollups_in_transaction/0` (`device_writes.ex:1722-1724`) takes `pg_advisory_xact_lock(20_240_306)` (`@inventory_rollup_refresh_lock_key`, `device_writes.ex:30`) and then `SELECT platform.refresh_device_inventory_rollups()`. The SQL function, last replaced in `20261005120000_mark_source_retired_devices.exs`, does not take the trigger advisory lock. It runs three separate `TRUNCATE TABLE` statements, one per rollup table, then full-table `COUNT(*)` / `GROUP BY` scans. Each `TRUNCATE` takes `AccessExclusiveLock` and blocks concurrent `SELECT`s of that table. `mapper_results_ingestor.ex` also calls `maybe_refresh_inventory_rollups/2`.
2. **Ash `ServiceRadar.Inventory.Device` (`device.ex`)**:
   - Actions that write devices include `:create`, `:update`, `:gateway_sync`, `:gateway_restore`, `:restore`, `:soft_delete`, `:set_availability`, `:touch`, `:bump_identity_revision`, `:merge_metadata`, `:write_facts`, and `:remove_facts`. There is no `:retire_source`, `:clear_source_retired`, or `:touch_last_seen` action.
   - Callers include `ServiceRadar.Edge.AgentGatewaySync` (`elixir/serviceradar_core/lib/serviceradar/edge/agent_gateway_sync.ex`), web-ng device edits, and `ServiceRadar.Inventory.Remediation.AgentLinks`. DIRE's public module is a facade (`identity_reconciler.ex`); device writes go through `ServiceRadar.Inventory.Identity`.
3. **Fact and metadata writers (`elixir/serviceradar_core/lib/serviceradar/inventory/changes/`)**:
   - `MergeDeviceFacts` (`merge_device_facts.ex:136`), `RemoveDeviceFacts` (`remove_device_facts.ex:109`), and `MergeDeviceMetadata` (`merge_device_metadata.ex:66`) run `UPDATE platform.ocsf_devices`.
4. **Availability and lifecycle workers**:
   - `ServiceRadar.Inventory.Availability.ResolverWorker` and `ExpiryWorker` do not set `platform.skip_inventory_rollup`.
   - `CaptureBackfillWorker.run_pages/4` sets it for every page (`capture_backfill_worker.ex:125`), including the `availability_state` projection update. There is no `backfill_merged_batch/2` or `backfill_single_batch/2`.
   - `ServiceRadar.Inventory.DeviceCleanupWorker` soft-deletes and expires devices.
   - Production setters of `platform.skip_inventory_rollup` are only `DeviceWrites.with_inventory_rollup_bypassed/1` and `CaptureBackfillWorker.run_pages/4`.

#### Readers of `platform.device_inventory_*`
- **SRQL (`rust/srql/src/query/devices/stats/rollup.rs:21-51`)**:
  - `build_rollup_stats_query/1` for `in:devices rollup_stats:inventory_summary` is the production reader of the three rollup tables. Status keys read `device_inventory_counts.value`. Type and vendor rows read `count`.
  - `ServiceRadarWebNGWeb.DeviceLive.IndexData.Stats` loads that query for the `/devices` summary (`index_data/stats.ex`).

---

### 3. Empirical Benchmark on `srql-fixtures` (`codex_rollup_bench_1792731434_52021`)

We measured concurrent device inserts against a fully migrated scratch database (`codex_rollup_bench_1792731434_52021`) on the `srql-fixtures` CNPG cluster (`192.168.10.31:30818`, TLS `verify-full`, warm `Postgrex` pool of 20 connections). Each transaction inserted `batch_size` synthetic `platform.ocsf_devices` rows and optionally held the transaction open for `hold_ms` (`0 ms`, `10 ms`, `25 ms`) to model post-insert identifier/alias/interface work within the same transaction before `COMMIT`.

#### Concurrent Insert Throughput and Latency Across Trigger Modes

| Concurrency | Tx Count | Batch Size | Post-Insert Hold (`hold_ms`) | Mode | Wall Time (ms) | Throughput (tx/s) | Throughput (rows/s) | p50 (ms) | p95 (ms) | p99 (ms) | Max (ms) | Speedup vs `with_trigger` |
|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 40 | 1 | 0 | `with_trigger` | 2,279.7 | 17.5 | 17.5 | 59.9 | 74.4 | 76.1 | 76.1 | 1.00x |
| 1 | 40 | 1 | 0 | `without_trigger` | 2,008.5 | 19.9 | 19.9 | 43.3 | 62.8 | 168.1 | 168.1 | 1.14x |
| 4 | 80 | 1 | 0 | `with_trigger` | 978.6 | 81.7 | 81.7 | 45.2 | 57.7 | 79.6 | 79.6 | 1.00x |
| 4 | 80 | 1 | 0 | `without_trigger` | 1,021.5 | 78.3 | 78.3 | 48.3 | 70.6 | 83.3 | 83.3 | 0.96x |
| 8 | 160 | 1 | 0 | `with_trigger` | 2,017.8 | 79.3 | 79.3 | 90.2 | 148.3 | 223.4 | 224.3 | 1.00x |
| 8 | 160 | 1 | 0 | `without_trigger` | 1,007.4 | 158.8 | 158.8 | 46.8 | 57.3 | 164.8 | 166.5 | **2.00x** |
| 16 | 160 | 1 | 0 | `with_trigger` | 3,213.6 | 49.8 | 49.8 | 297.8 | 528.0 | 722.5 | 722.7 | 1.00x |
| 16 | 160 | 1 | 0 | `skip_guc_bypass` | 873.4 | 183.2 | 183.2 | 75.3 | 114.2 | 239.5 | 239.5 | **3.68x** |
| 16 | 160 | 1 | 0 | `without_trigger` | 729.3 | 219.4 | 219.4 | 50.2 | 171.3 | 171.4 | 171.5 | **4.41x** |
| 8 | 80 | 1 | 10 | `with_trigger` | 4,117.8 | 19.4 | 19.4 | 387.6 | 515.6 | 535.5 | 535.5 | 1.00x |
| 8 | 80 | 1 | 10 | `skip_guc_bypass` | 1,242.7 | 64.4 | 64.4 | 111.9 | 146.2 | 231.2 | 231.2 | **3.32x** |
| 8 | 80 | 1 | 10 | `without_trigger` | 1,011.0 | 79.1 | 79.1 | 78.4 | 90.6 | 281.9 | 281.9 | **4.08x** |
| 16 | 160 | 1 | 10 | `with_trigger` | 7,918.4 | 20.2 | 20.2 | 743.3 | 980.4 | 1,020.6 | 1,021.7 | 1.00x |
| 16 | 160 | 1 | 10 | `skip_guc_bypass` | 1,210.8 | 132.1 | 132.1 | 113.9 | 150.1 | 151.0 | 151.3 | **6.54x** |
| 16 | 160 | 1 | 10 | `without_trigger` | 906.9 | 176.4 | 176.4 | 86.5 | 117.9 | 118.0 | 118.1 | **8.73x** |
| 8 | 80 | 1 | 25 | `with_trigger` | 4,779.3 | 16.7 | 16.7 | 465.2 | 514.3 | 594.8 | 594.8 | 1.00x |
| 8 | 80 | 1 | 25 | `skip_guc_bypass` | 1,252.2 | 63.9 | 63.9 | 123.0 | 130.9 | 131.2 | 131.2 | **3.83x** |
| 8 | 80 | 1 | 25 | `without_trigger` | 1,078.8 | 74.2 | 74.2 | 95.8 | 123.2 | 220.7 | 220.7 | **4.44x** |
| 16 | 160 | 1 | 25 | `with_trigger` | 10,156.3 | 15.8 | 15.8 | 957.5 | 1,124.0 | 1,148.8 | 1,155.9 | 1.00x |
| 16 | 160 | 1 | 25 | `skip_guc_bypass` | 1,394.9 | 114.7 | 114.7 | 127.1 | 182.7 | 185.5 | 185.8 | **7.26x** |
| 16 | 160 | 1 | 25 | `without_trigger` | 1,045.7 | 153.0 | 153.0 | 102.0 | 117.5 | 121.2 | 122.1 | **9.68x** |
| 8 | 80 | 25 | 10 | `with_trigger` | 3,862.6 | 20.7 | 517.8 | 360.9 | 449.9 | 483.1 | 483.1 | 1.00x |
| 8 | 80 | 25 | 10 | `skip_guc_bypass` | 1,286.4 | 62.2 | 1,554.7 | 112.6 | 206.1 | 211.6 | 211.6 | **3.00x** |
| 8 | 80 | 25 | 10 | `without_trigger` | 1,129.5 | 70.8 | 1,770.7 | 89.6 | 217.3 | 228.9 | 228.9 | **3.42x** |

#### Key Observations from the Benchmark
1. **Negative Concurrency Scaling (`hold_ms = 0`)**: With the rollup trigger active, raising concurrency from 4 to 16 **reduces** throughput from `81.7 tx/s` to `49.8 tx/s` while `p50` latency climbs **6.6x** (`45.2 ms` -> `297.8 ms`) and `p99` climbs **9.1x** (`79.6 ms` -> `722.5 ms`). With the trigger disabled, throughput scales linearly from `78.3 tx/s` (c=4) to `158.8 tx/s` (c=8) to `219.4 tx/s` (c=16) while `p50` remains flat (`48.3 ms` -> `46.8 ms` -> `50.2 ms`).
2. **Severe Head-of-Line Blocking on Multi-Statement Transactions (`hold_ms = 10..25 ms`)**: When a transaction performs `10 ms` or `25 ms` of additional work after inserting into `ocsf_devices` (such as writing `device_identifiers`, `device_alias_states`, `discovered_interfaces`, or sightings), throughput with the trigger collapses to a hard ceiling of `15.8–20.2 tx/s` regardless of whether concurrency is 8 or 16. At `concurrency = 16, hold_ms = 25`, `without_trigger` achieves **9.68x higher throughput** (`153.0 tx/s` vs `15.8 tx/s`) and **9.39x lower p50 latency** (`102.0 ms` vs `957.5 ms`), while `with_trigger` pushes `p95` (`1,124.0 ms`) past the 1,000 ms `DBConnection` CoDel queue timeout.
3. **`pg_locks` Evidence of `AccessExclusiveLock` During `refresh_device_inventory_rollups()`**:
   Inspecting `pg_locks` inside a transaction executing `SELECT platform.refresh_device_inventory_rollups()` confirmed that `TRUNCATE TABLE` acquires `AccessExclusiveLock` on `device_inventory_counts`, `device_inventory_type_counts`, `device_inventory_vendor_counts`, and all of their primary-key and count indexes, blocking concurrent SRQL `SELECT` readers for `47.7 ms` (at `8,760` devices, and proportionally longer on larger fleets).

---

## Goals / Non-Goals

- **Goals**:
  - Eliminate the global cross-transaction serialization point (`pg_advisory_xact_lock` and singleton counter rows) on `platform.ocsf_devices` inserts, updates, and deletes.
  - Prevent non-rollup `UPDATE` statements on `platform.ocsf_devices` from materializing transition tables or invoking the rollup trigger function.
  - Eliminate `AccessExclusiveLock` on the rollup tables during `platform.refresh_device_inventory_rollups()` so SRQL `in:devices rollup_stats:inventory_summary` reads are never blocked by bulk refreshes.
  - Preserve sub-5ms SRQL read latency for `in:devices rollup_stats:inventory_summary` regardless of total device fleet size.
- **Non-Goals**:
  - Changing the external SRQL response contract of `in:devices rollup_stats:inventory_summary`.
  - Removing the `platform.skip_inventory_rollup` GUC used by bulk sync batches above the default `10_000`-row threshold and by async `DataCase` sandbox owners (`openspec/changes/parallelize-core-integration-tests`).

---

## Decisions

### Decision 1: Use Fixed-Bucket Sharded Counter Tables (`64` Shards) Without a Global Advisory Lock

We evaluated three candidate designs:

| Criterion | Option 1: Sharded Counters (`64` shards, Recommended) | Option 2: Append-Only Delta Queue + Periodic Compaction | Option 3: Read-Time Aggregation Over `ocsf_devices` |
|---|---|---|---|
| Write-path lock contention | **Near-zero**: concurrent transactions hash `pg_current_xact_id()` into `0..63` shards; no global advisory lock; deterministic key sort prevents deadlocks when two transactions share a shard | **Zero on insert**, but periodic compactor must lock/delete compacted rows and update summary rows | **Zero** (no trigger or rollup tables) |
| Read-path cost (`rollup.rs`) | **O(shards x distinct_keys)**: `SUM(count)` over `<= 64 * 3 = 192` count rows and `64 * K` vendor/type rows (`< 1 ms`) | **O(summary + uncompacted deltas)**: degrades if compactor lags during sync bursts | **O(active_devices)**: 3 aggregation queries per `/devices` load (`~48 ms` at `8.7k` devices; hundreds of ms at `100k+` devices) |
| Operational / VACUUM complexity | Bounded table size (`64 * K` rows); standard HOT updates within each shard | High tuple churn and VACUUM pressure on delta log table; requires background compaction monitoring | None, but adds CPU/buffer pressure on `ocsf_devices` for every UI summary load |
| Transactional consistency | **Immediate read-your-writes consistency**: committed deltas are immediately visible in `SUM(count)` | Immediate if reader unions uncompacted deltas; eventual if reader only queries compacted table | Immediate |

**Rationale for Option 1 (Sharded Counters)**:
- By adding `shard smallint NOT NULL DEFAULT 0 CHECK (shard >= 0 AND shard < 64)` to the primary key of all three rollup tables (`PRIMARY KEY (key, shard)`, `PRIMARY KEY (type, shard)`, `PRIMARY KEY (vendor_name, shard)`), each transaction computes:
  ```sql
  v_shard := mod(abs(hashtextextended(pg_current_xact_id()::text, 0)), 64)::smallint;
  ```
- **Do not take `pg_advisory_xact_lock` in the new `apply_device_inventory_rollup_deltas()`**. Today the lock sits inline in each of the three trigger functions (`20261019150000_batch_device_inventory_rollups.exs`). It was added because an upsert runs the update and insert triggers as separate statements, so key order inside one trigger does not by itself order locks across both. The new function orders `INSERT ... ON CONFLICT DO UPDATE` by `key`, then `type`, then `vendor_name`, and every caller uses that same order, so two transactions that land on one shard (`1/64`) take row locks in one order.
- **Signed per-shard counts**: A later transaction can decrement a shard other than the one that inserted the device, including shard `0`. The sum across shards stays `>= 0` while one shard's `value` or `count` goes below `0`. Status rows already store signed `value` with no clamp. Type and vendor triggers `DELETE` rows `WHERE count <= 0` after a negative delta. Incremental shard updates must not do that delete. SRQL reports `GREATEST(SUM(value), 0)` for status keys and `HAVING SUM(count) > 0` for type and vendor. `refresh_device_inventory_rollups()` compacts back to `shard = 0`.

### Decision 2: Narrow `trg_ocsf_devices_inventory_rollup_update` to Rollup-Relevant Columns

Replace:
```sql
CREATE TRIGGER trg_ocsf_devices_inventory_rollup_update
AFTER UPDATE ON platform.ocsf_devices
REFERENCING OLD TABLE AS inventory_old NEW TABLE AS inventory_new
FOR EACH STATEMENT
EXECUTE FUNCTION platform.trg_ocsf_devices_inventory_rollup_update();
```
with:
```sql
CREATE TRIGGER trg_ocsf_devices_inventory_rollup_update
AFTER UPDATE OF deleted_at, source_retired_at, is_available, type, vendor_name ON platform.ocsf_devices
REFERENCING OLD TABLE AS inventory_old NEW TABLE AS inventory_new
FOR EACH STATEMENT
EXECUTE FUNCTION platform.trg_ocsf_devices_inventory_rollup_update();
```
(When `add-merged-device-availability` switches the availability rollup from `is_available` to `availability_state`, the column list includes `availability_state`.)
This prevents PostgreSQL from building `inventory_old` and `inventory_new` transition tuplestores on `UPDATE` statements that only touch `last_seen`, `ip`, `hostname`, `metadata`, `agent_id`, or `identity_revision`.

### Decision 3: Replace `TRUNCATE TABLE` in `refresh_device_inventory_rollups()` with Non-Blocking Differential Upsert + Cleanup

Instead of `TRUNCATE TABLE` (which takes `AccessExclusiveLock` and blocks SRQL readers), `platform.refresh_device_inventory_rollups()` will:
1. Acquire `pg_advisory_xact_lock(hashtextextended('serviceradar:device-inventory-rollup', 0))` solely to serialize concurrent full refreshes against each other.
2. Delete non-zero shards (`DELETE FROM platform.device_inventory_counts WHERE shard <> 0`, and likewise for `type_counts` and `vendor_counts`) and stale keys not present in the recomputed aggregate.
3. Upsert the canonical totals into `shard = 0` via `INSERT ... ON CONFLICT (..., shard) DO UPDATE SET count = EXCLUDED.count, updated_at = NOW()`.
4. Remove `pg_advisory_xact_lock(20_240_306)` from `ServiceRadar.Inventory.Sync.DeviceWrites.refresh_inventory_rollups_in_transaction/0` so `SELECT platform.refresh_device_inventory_rollups()` is the only refresh lock.

Because `DELETE` and `INSERT ... ON CONFLICT DO UPDATE` acquire only `RowExclusiveLock`, concurrent SRQL `SELECT` queries (`AccessShareLock`) never block during a full refresh, and MVCC ensures readers see a consistent snapshot before, during, and after the refresh transaction.

### Decision 4: Aggregate Shards in SRQL `build_rollup_stats_query/1`

Update `rust/srql/src/query/devices/stats/rollup.rs` to sum across shards. The status column stays `value`:
- Counts query:
  ```sql
  SELECT key, GREATEST(COALESCE(SUM(value), 0), 0)::bigint AS count
  FROM platform.device_inventory_counts
  GROUP BY key
  ```
- Type counts query:
  ```sql
  SELECT type AS key, SUM(count)::bigint AS count
  FROM platform.device_inventory_type_counts
  GROUP BY type
  HAVING SUM(count) > 0
  ORDER BY count DESC, type ASC
  ```
- Vendor counts query:
  ```sql
  SELECT vendor_name AS key, SUM(count)::bigint AS count
  FROM platform.device_inventory_vendor_counts
  GROUP BY vendor_name
  HAVING SUM(count) > 0
  ORDER BY count DESC, vendor_name ASC
  ```
`SUM(value) GROUP BY key` and `SUM(count) GROUP BY type` or `vendor_name` return the same totals for one row per key and for up to 64 shard rows per key, so the SRQL change is safe to deploy before the schema migration.

---

## Risks / Trade-offs

- **Risk: Concurrent incremental trigger write vs. concurrent full `refresh_device_inventory_rollups()`**
  - *Mitigation*: Full refreshes run after bulk sync batches above the default `10_000` device threshold (those batches set `skip_inventory_rollup = 'on'`). During `refresh_device_inventory_rollups()`, the refresh transaction snapshots `ocsf_devices` under MVCC and writes `shard = 0` while deleting `shard <> 0`. If a small concurrent transaction commits a delta into `shard = k` right before `refresh_device_inventory_rollups()` starts, its row is already included in the `ocsf_devices` scan; if it is in flight concurrently, locking shards in deterministic order (`DELETE ... WHERE shard <> 0` after the `ocsf_devices` scan) bounds the conflict window to the final millisecond of the refresh transaction.
- **Risk: Signed per-shard counts when devices change type/vendor or are deleted on a different shard**
  - *Mitigation*: Do not copy the type/vendor `DELETE ... WHERE count <= 0` into sharded incremental updates. Status `value` is already unclamped. `GREATEST(SUM(value), 0)` and `HAVING SUM(count) > 0` in `rollup.rs`, plus `refresh_device_inventory_rollups()`, collapse shards back to `shard = 0`.

## Migration Plan

1. Deploy the SRQL `SUM(value)` / `SUM(count)` `GROUP BY` update in `rust/srql/src/query/devices/stats/rollup.rs` (compatible with the existing single-row-per-key schema).
2. Run a database migration that:
   - Adds `shard smallint NOT NULL DEFAULT 0 CHECK (shard >= 0 AND shard < 64)` to `device_inventory_counts`, `device_inventory_type_counts`, and `device_inventory_vendor_counts`, replacing each single-column primary key with `(key, shard)`, `(type, shard)`, and `(vendor_name, shard)`.
   - Adds `platform.apply_device_inventory_rollup_deltas()` and points the three statement triggers at it. The function is sharded, takes no advisory lock, and orders keys deterministically. It writes status deltas to `value` and type/vendor deltas to `count`.
   - Replaces `platform.refresh_device_inventory_rollups()` with the `DELETE` + `UPSERT` (`shard = 0`) implementation (no `TRUNCATE TABLE`).
   - Recreates `trg_ocsf_devices_inventory_rollup_update` with `AFTER UPDATE OF deleted_at, source_retired_at, is_available, type, vendor_name`.
3. Update `ServiceRadar.Inventory.Sync.DeviceWrites.refresh_inventory_rollups_in_transaction/0` to call `SELECT platform.refresh_device_inventory_rollups()` without `pg_advisory_xact_lock(20_240_306)`.
4. **Rollback**: Revert the trigger and function definitions to `shard = 0` and collapse `shard <> 0` rows via `SELECT platform.refresh_device_inventory_rollups()` before dropping the `shard` column.

## Open Questions

- Should `platform.refresh_device_inventory_rollups()` also be scheduled as a lightweight daily/hourly Oban maintenance job to compact non-zero shards back into `shard = 0` during periods without bulk syncs above the `10_000` threshold, even though 64 shards cap the maximum row count at `64 * distinct_keys`?
