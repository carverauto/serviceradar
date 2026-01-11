# Change: Fix CNPG device_updates deadlock with write serialization

## Why
Core is emitting deadlock errors (`ERROR: deadlock detected (SQLSTATE 40P01)`) during CNPG device_updates batch operations. Investigation of issue #2087 reveals:

1. **Multiple concurrent callers executing batch writes**: `ProcessBatchDeviceUpdates` is called concurrently from 8+ locations (pollers, discovery, metrics, flush, services, mapper). Each call triggers multiple database operations without serialization.

2. **Circular lock dependencies across operations**: The flow performs sequential writes to multiple tables with UNIQUE/PRIMARY KEY constraints:
   - `RegisterDeviceIdentifiers` → INSERT with `ON CONFLICT (identifier_type, identifier_value, partition)`
   - `PublishBatchDeviceUpdates` → INSERT with `ON CONFLICT (device_id)` on `unified_devices`

   When two concurrent batches contain overlapping devices or identifiers, they can acquire locks in different orders, creating deadlock cycles.

3. **Complex ON CONFLICT UPDATE clauses**: The `unified_devices` upsert includes array aggregation (`array_cat`, `array_agg(DISTINCT)`) and JSONB merge operations that hold locks longer during the UPDATE phase.

4. **No transient error handling**: Unlike the AGE graph writer (fixed in #2058), device_updates operations don't classify deadlock errors as transient and don't implement retry logic.

## What Changes

### 1. Write Serialization with Mutex (Root Cause Fix)
Add a Go-level mutex in `pkg/db/DB` to serialize CNPG device_updates batch operations. This follows the pattern established in `age_graph_writer.go:81` (`writeMu sync.Mutex`) which successfully eliminated AGE graph deadlocks.

### 2. Transient Error Classification
Add SQLSTATE 40P01 (deadlock_detected) and 40001 (serialization_failure) to a transient error classifier for device_updates operations, enabling retry with exponential backoff.

### 3. Exponential Backoff with Jitter
Implement configurable backoff timing for deadlock errors (default 500ms base) with exponential growth and randomized jitter to break lock acquisition synchronization patterns.

### 4. Deadlock-Specific Metrics
Add new OTel metrics to track deadlock frequency and retry success:
- `cnpg_device_updates_deadlock_total`: Count of deadlock errors encountered
- `cnpg_device_updates_retry_total`: Count of transient retries
- `cnpg_device_updates_retry_success_total`: Count of successful retries

## Impact
- Affected specs: device-registry
- Affected code:
  - `pkg/db/db.go` (new deviceUpdatesMu mutex, retry logic)
  - `pkg/db/cnpg_unified_devices.go` (mutex acquisition around batch)
  - `pkg/db/cnpg_identity_reconciliation_upserts.go` (mutex acquisition)
  - `pkg/db/cnpg_metrics.go` (new deadlock metrics)
- Risk: Low - serialization may reduce throughput but eliminates failures
- Performance: Device update writes become sequential but reliable

## Trade-offs
- **Throughput vs Reliability**: Serializing writes reduces parallel throughput but ensures ~100% success rate vs intermittent deadlock failures.
- **Latency**: Individual batches may wait longer if another write is in progress, but total time to completion improves due to elimination of failed operations and retries.
- **Alternative considered**: Row-level locking with `SELECT FOR UPDATE ORDER BY device_id` was considered but adds complexity and still requires consistent ordering across all call sites. The mutex approach is simpler and proven effective in the AGE graph case.
