## Context

### 1. Inventory of Rollup Tables, Triggers, and Functions

#### Rollup Tables (`elixir/serviceradar_core/priv/repo/baseline/platform_schema.sql:4619-4642`)
- `platform.device_inventory_counts (key text PRIMARY KEY, count bigint NOT NULL DEFAULT 0, updated_at timestamptz NOT NULL DEFAULT now())` — stores three singleton rows: `key IN ('total', 'available', 'unavailable')`.
- `platform.device_inventory_type_counts (type text PRIMARY KEY, count bigint NOT NULL DEFAULT 0, updated_at timestamptz NOT NULL DEFAULT now())` — stores one row per normalized device `type` (`COALESCE(NULLIF(BTRIM(type), ''), 'Unknown')`).
- `platform.device_inventory_vendor_counts (vendor_name text PRIMARY KEY, count bigint NOT NULL DEFAULT 0, updated_at timestamptz NOT NULL DEFAULT now())` — stores one row per normalized `vendor_name` (`COALESCE(NULLIF(BTRIM(vendor_name), ''), 'Unknown')`).

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
2. `20260306001000_optimize_device_inventory_rollup_bulk_sync.exs`: Added the transaction-local `current_setting('platform.skip_inventory_rollup', true) = 'on'` bypass in `trg_ocsf_devices_inventory_rollup()` so bulk sync batches exceeding 1,000 devices could skip per-row updates and call `refresh_device_inventory_rollups()` afterward.
3. `20261005120000_mark_source_retired_devices.exs`: Excluded `source_retired_at IS NOT NULL` devices from active rollup counts.
4. `20261019150000_batch_device_inventory_rollups.exs`: Replaced the `FOR EACH ROW` trigger with three `FOR EACH STATEMENT` transition-table triggers (`_insert`, `_update`, `_delete`) that populate transaction-local temporary tables (`pg_temp.device_inventory_rollup_count_deltas`, `pg_temp.device_inventory_rollup_type_deltas`, `pg_temp.device_inventory_rollup_vendor_deltas`) and call `platform.apply_device_inventory_rollup_deltas()`.

#### Why `20261019150000_batch_device_inventory_rollups.exs` Still Serializes Concurrent Transactions
While statement-level transition tables reduced the overhead of a multi-row `INSERT` *within a single statement*, `platform.apply_device_inventory_rollup_deltas()` still serializes **across concurrent transactions** for three reasons:
1. **Global Transaction-Scoped Advisory Lock**: `apply_device_inventory_rollup_deltas()` executes:
   ```sql
   PERFORM pg_advisory_xact_lock(hashtextextended('serviceradar:device-inventory-rollup', 0));
   ```
   `pg_advisory_xact_lock` is an exclusive lock held until the enclosing transaction commits or rolls back. Once a transaction executes `INSERT INTO platform.ocsf_devices`, no other transaction can complete `apply_device_inventory_rollup_deltas()` or `refresh_device_inventory_rollups()` until the first transaction finishes all remaining statements and commits.
2. **Singleton Counter Row Contention**: Even without the advisory lock, every active device insert updates `device_inventory_counts WHERE key = 'total'` and either `key = 'available'` or `key = 'unavailable'`, plus the matching `type` and `vendor_name` rows. Updating a row in PostgreSQL holds a `FOR NO KEY UPDATE` tuple lock until transaction end.
3. **Unfiltered `AFTER UPDATE` Transition Table Materialization**: `trg_ocsf_devices_inventory_rollup_update` is declared as `AFTER UPDATE ON platform.ocsf_devices` without an `OF <column_list>` clause. Every `UPDATE` on `platform.ocsf_devices` (including `last_seen` heartbeats, `metadata` merges, `ip` updates, `identity_revision` bumps, and `availability_state` transitions) forces PostgreSQL to materialize `inventory_old` and `inventory_new` tuplestores and execute the three delta-aggregation CTE joins.

---

### 2. Inventory of All Writers and Readers

#### Writers to `platform.ocsf_devices` and `platform.device_inventory_*`
1. **Sync Ingestion (`ServiceRadar.Inventory.Sync.DeviceWrites`, `elixir/serviceradar_core/lib/serviceradar/inventory/sync/device_writes.ex`)**:
   - `upsert_devices_with_ips/5` (`device_writes.ex:1663-1695`) runs inside the `SyncIngestor` transaction (`sync_ingestor.ex:254`).
   - When `length(existing_devices) <= 1_000` (`@default_inventory_rollup_bulk_refresh_threshold`, `device_writes.ex:28,1697-1699`), `set_local_skip_inventory_rollup/0` is **not** called. The `Repo.insert_all(Device, chunk, on_conflict: ...)` call fires `trg_ocsf_devices_inventory_rollup_insert` mid-transaction, acquiring the global rollup lock and holding it while the rest of `SyncIngestor` processes device identifiers, aliases, interfaces, and sightings.
   - When `length(existing_devices) > 1_000`, `set_local_skip_inventory_rollup/0` (`device_writes.ex:1701-1709`) sets `SET LOCAL platform.skip_inventory_rollup = 'on'`, and after the main transaction commits, `SyncIngestor` calls `DeviceWrites.refresh_inventory_rollups/0` (`device_writes.ex:1722-1736`).
   - **Lock Key Mismatch & `TRUNCATE` Reader Blocking**: `DeviceWrites.refresh_inventory_rollups/0` acquires `pg_advisory_xact_lock(2_026_030_601)` (`@inventory_rollup_refresh_lock_key`, `device_writes.ex:29,1726`) and then invokes `SELECT platform.refresh_device_inventory_rollups()`. Inside SQL, `refresh_device_inventory_rollups()` acquires a *different* advisory lock key (`hashtextextended('serviceradar:device-inventory-rollup', 0)` = `-1913561502452284797`) and immediately runs:
     ```sql
     TRUNCATE TABLE
       platform.device_inventory_counts,
       platform.device_inventory_type_counts,
       platform.device_inventory_vendor_counts;
     ```
     `TRUNCATE TABLE` acquires `AccessExclusiveLock` on all three rollup tables and their indexes for the duration of the subsequent three full-table `COUNT(*)` / `GROUP BY` scans of `platform.ocsf_devices`, blocking all concurrent `SELECT` queries against the rollup tables.
2. **Ash `ServiceRadar.Inventory.Device` Actions (`elixir/serviceradar_core/lib/serviceradar/inventory/device.ex`)**:
   - `:create`, `:update`, `:gateway_sync`, `:gateway_restore`, `:restore`, `:soft_delete`, `:retire_source`, `:clear_source_retired`, `:touch_last_seen`.
   - Callers include `ServiceRadar.Inventory.AgentGatewaySync` (`agent_gateway_sync.ex:76,204,225`), manual device creation/editing in `web-ng`, remediation (`ServiceRadar.Inventory.Remediation.AgentLinks`, `agent_links.ex:266`), and DIRE (`ServiceRadar.Inventory.IdentityReconciler`, `identity_reconciler.ex:863,1152`). None of these set `platform.skip_inventory_rollup`.
3. **Canonical Fact & Metadata Writers (`elixir/serviceradar_core/lib/serviceradar/inventory/changes/`)**:
   - `MergeDeviceFacts` (`merge_device_facts.ex:136`), `RemoveDeviceFacts` (`remove_device_facts.ex:109`), and `MergeDeviceMetadata` (`merge_device_metadata.ex:66`) execute `UPDATE platform.ocsf_devices` inside transaction boundaries.
4. **Availability & Lifecycle Workers**:
   - `ServiceRadar.Inventory.Availability.ResolverWorker` / `ExpiryWorker` / `CaptureBackfillWorker` (`capture_backfill_worker.ex:43,125` — sets `skip_inventory_rollup = 'on'` in `backfill_merged_batch/2` at line 125, but not in `backfill_single_batch/2` at line 43).
   - `ServiceRadar.Jobs.DeviceCleanupWorker` (batch soft-delete / expiry of stale ephemeral devices).

#### Readers of `platform.device_inventory_*`
- **SRQL (`rust/srql/src/query/devices/stats/rollup.rs:28-140`)**:
  - `execute_inventory_summary_rollup` (triggered by `in:devices rollup_stats:inventory_summary`) is the **sole production reader** of `device_inventory_counts`, `device_inventory_type_counts`, and `device_inventory_vendor_counts`.
  - Consumed by `ServiceRadarWebNG.DeviceLive.IndexData.Stats` (the `/devices` header summary cards and vendor/type facets) and `ServiceRadarWebNG.DashboardLive.Data.BasicSummaries`.

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
  - Removing the `platform.skip_inventory_rollup` GUC used by >1,000-row bulk sync batches and async `DataCase` sandbox owners (`openspec/changes/parallelize-core-integration-tests`).

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
- **Removing `pg_advisory_xact_lock` from `apply_device_inventory_rollup_deltas()`**: The global advisory lock was originally added in `20261019150000_batch_device_inventory_rollups.exs` to prevent deadlocks when two concurrent transactions updated multiple keys in `device_inventory_counts`, `device_inventory_type_counts`, and `device_inventory_vendor_counts`. Ordering each statement's `INSERT ... ON CONFLICT (key, shard) DO UPDATE` source query by `ORDER BY key` (and `ORDER BY type`, `ORDER BY vendor_name`) already guarantees a strict global lock acquisition order `(table, key, shard)` whenever two transactions happen to land on the same `shard` (`1/64` probability), making deadlocks impossible without a global advisory lock.
- **Note on signed shard counts**: Within an individual shard `1..63`, a `DELETE` or `UPDATE` of a device originally inserted by a different transaction can decrement that shard's counter below `0` while the sum across all shards (`SUM(count)`) remains `>= 0`. Therefore, individual shard rows MUST allow signed `bigint` values (`count bigint NOT NULL DEFAULT 0`, removing `GREATEST(..., 0)` per-shard clamping during incremental deltas), while the SRQL reader and `refresh_device_inventory_rollups()` enforce `HAVING SUM(count) > 0` (and `GREATEST(SUM(count), 0)`).

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
4. Remove the redundant and mismatched `pg_advisory_xact_lock(2_026_030_601)` call in `ServiceRadar.Inventory.Sync.DeviceWrites.refresh_inventory_rollups/0` so `SELECT platform.refresh_device_inventory_rollups()` is the single authority for refresh locking.

Because `DELETE` and `INSERT ... ON CONFLICT DO UPDATE` acquire only `RowExclusiveLock`, concurrent SRQL `SELECT` queries (`AccessShareLock`) never block during a full refresh, and MVCC ensures readers see a consistent snapshot before, during, and after the refresh transaction.

### Decision 4: Aggregate Shards in SRQL `execute_inventory_summary_rollup`

Update `rust/srql/src/query/devices/stats/rollup.rs` to sum across shards:
- Counts query:
  ```sql
  SELECT key, GREATEST(COALESCE(SUM(count), 0), 0)::bigint AS count
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
Because both the pre-migration schema (1 row per key) and the post-migration schema (`<= 64` rows per key) return identical results under `SUM(count) ... GROUP BY ...`, the SRQL query change is backward- and forward-compatible with the schema migration during rolling deploys.

---

## Risks / Trade-offs

- **Risk: Concurrent incremental trigger write vs. concurrent full `refresh_device_inventory_rollups()`**
  - *Mitigation*: Full refreshes only run after bulk sync batches exceeding 1,000 devices (which set `skip_inventory_rollup = 'on'`). During `refresh_device_inventory_rollups()`, the refresh transaction snapshots `ocsf_devices` under MVCC and writes `shard = 0` while deleting `shard <> 0`. If a small concurrent transaction commits a delta into `shard = k` right before `refresh_device_inventory_rollups()` starts, its row is already included in the `ocsf_devices` scan; if it is in flight concurrently, locking shards in deterministic order (`DELETE ... WHERE shard <> 0` after the `ocsf_devices` scan) bounds the conflict window to the final millisecond of the refresh transaction.
- **Risk: Signed per-shard counts when devices change type/vendor or are deleted on a different shard**
  - *Mitigation*: Drop the `GREATEST(..., 0)` clamp and `WHERE count <= 0` delete inside incremental `apply_device_inventory_rollup_deltas()` so negative deltas on a shard are preserved accurately; `HAVING SUM(count) > 0` in `rollup.rs` and periodic `refresh_device_inventory_rollups()` compaction collapse all shards back into `shard = 0`.

## Migration Plan

1. Deploy the SRQL `GROUP BY` / `SUM(count)` query update in `rust/srql/src/query/devices/stats/rollup.rs` (fully compatible with the existing single-row-per-key schema).
2. Run a database migration that:
   - Adds `shard smallint NOT NULL DEFAULT 0 CHECK (shard >= 0 AND shard < 64)` to `device_inventory_counts`, `device_inventory_type_counts`, and `device_inventory_vendor_counts`, replacing each single-column primary key with `(key, shard)`, `(type, shard)`, and `(vendor_name, shard)`.
   - Replaces `platform.apply_device_inventory_rollup_deltas()` with the sharded, advisory-lock-free implementation using deterministic `ORDER BY` key ordering.
   - Replaces `platform.refresh_device_inventory_rollups()` with the `DELETE` + `UPSERT` (`shard = 0`) implementation (no `TRUNCATE TABLE`).
   - Recreates `trg_ocsf_devices_inventory_rollup_update` with `AFTER UPDATE OF deleted_at, source_retired_at, is_available, type, vendor_name`.
3. Update `ServiceRadar.Inventory.Sync.DeviceWrites.refresh_inventory_rollups/0` to call `SELECT platform.refresh_device_inventory_rollups()` directly without the mismatched `2_026_030_601` advisory lock.
4. **Rollback**: Revert the trigger and function definitions to `shard = 0` and collapse `shard <> 0` rows via `SELECT platform.refresh_device_inventory_rollups()` before dropping the `shard` column.

## Open Questions

- Should `platform.refresh_device_inventory_rollups()` also be scheduled as a lightweight daily/hourly Oban maintenance job to compact non-zero shards back into `shard = 0` during periods without >1,000-device bulk syncs, even though 64 shards cap the maximum row count at `64 * distinct_keys`?
