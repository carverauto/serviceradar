## ADDED Requirements

### Requirement: Sharded Non-Serializing Device Inventory Rollup Updates
The system SHALL maintain `platform.device_inventory_counts`, `platform.device_inventory_type_counts`, and `platform.device_inventory_vendor_counts` across fixed shards (`0..63`) without acquiring a global transaction-level advisory lock during incremental `platform.ocsf_devices` `INSERT`, `UPDATE`, or `DELETE` statements.
Each transaction that mutates rollup-relevant device state SHALL apply its statement-level transition-table deltas to a transaction-hashed shard in deterministic key order so concurrent device-writing transactions on distinct shards do not serialize behind a single counter row, and transactions that map to the same shard acquire row locks in a deadlock-free order.

#### Scenario: Concurrent device insert transactions on distinct shards do not block each other
- **GIVEN** transaction A has inserted an active device into `platform.ocsf_devices` and remains open before committing
- **WHEN** transaction B (mapping to a different rollup shard) inserts an active device into `platform.ocsf_devices`
- **THEN** transaction B SHALL complete its `INSERT` and commit without waiting for transaction A to release a global advisory lock or a singleton counter row lock
- **AND** after both transactions commit, `SUM(value)` across shards for `key = 'total'` SHALL include both devices

#### Scenario: Deletions and type or vendor transitions across shards preserve exact net sums
- **GIVEN** an active device was inserted in transaction A (recording `+1` for its type and vendor on shard `s1`)
- **WHEN** a later transaction B on shard `s2` updates the device's `type` or `vendor_name` or soft-deletes the device
- **THEN** shard `s2` SHALL record the `-1` delta on `value` or `count` without deleting that shard row when the shard total is `<= 0`
- **AND** `in:devices rollup_stats:inventory_summary` SHALL report `SUM(value)` for status keys and `SUM(count)` for type and vendor, omitting any `type` or `vendor_name` whose net count across shards is `<= 0`

### Requirement: Column-Scoped Inventory Rollup Update Trigger
The `trg_ocsf_devices_inventory_rollup_update` trigger on `platform.ocsf_devices` SHALL fire only when at least one rollup-relevant column (`deleted_at`, `source_retired_at`, `is_available`, `type`, or `vendor_name`) is targeted by an `UPDATE` statement.
Updates that modify only non-rollup columns (such as `last_seen`, `ip`, `hostname`, `metadata`, or `identity_revision`) SHALL NOT materialize rollup transition tables or invoke `platform.trg_ocsf_devices_inventory_rollup_update()`.

#### Scenario: Heartbeat and metadata updates do not invoke the rollup update trigger
- **GIVEN** an existing active device in `platform.ocsf_devices`
- **WHEN** a transaction executes `UPDATE platform.ocsf_devices SET last_seen = NOW(), metadata = '{"probe":"ok"}'::jsonb WHERE uid = $1`
- **THEN** `trg_ocsf_devices_inventory_rollup_update` SHALL NOT fire
- **AND** no locks SHALL be acquired on `platform.device_inventory_counts`, `platform.device_inventory_type_counts`, or `platform.device_inventory_vendor_counts`

### Requirement: Non-Blocking Full Inventory Rollup Refresh
Full recomputation via `platform.refresh_device_inventory_rollups()` SHALL compact and replace rollup counts using row-level DML (`DELETE` and `INSERT ... ON CONFLICT DO UPDATE`) without executing `TRUNCATE TABLE` or acquiring `AccessExclusiveLock` on the rollup tables.
Concurrent SRQL readers querying `in:devices rollup_stats:inventory_summary` SHALL NOT be blocked while `platform.refresh_device_inventory_rollups()` is executing.

#### Scenario: Concurrent SRQL summary read succeeds while a full rollup refresh is in progress
- **GIVEN** a transaction has called `SELECT platform.refresh_device_inventory_rollups()` and has not yet committed
- **WHEN** a concurrent session queries `platform.device_inventory_counts`, `platform.device_inventory_type_counts`, and `platform.device_inventory_vendor_counts` for `in:devices rollup_stats:inventory_summary`
- **THEN** the `refresh_device_inventory_rollups()` transaction SHALL NOT hold `AccessExclusiveLock` on any of the three rollup tables
- **AND** the concurrent `SELECT` query SHALL return a consistent MVCC snapshot immediately without blocking on the refresh transaction
