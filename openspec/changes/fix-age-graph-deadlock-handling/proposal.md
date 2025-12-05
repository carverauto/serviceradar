# Change: Fix AGE graph deadlock handling with write serialization

## Why
Core in the demo namespace is emitting deadlock errors (`deadlock detected` / SQLSTATE 40P01) and entity update failures (`Entity failed to be updated: 3` / SQLSTATE XX000) during AGE graph merges. Investigation of issue #2058 reveals:

1. **Multiple concurrent database connections executing MERGE queries**: With `AGE_GRAPH_WORKERS=4`, up to 4 workers execute MERGE batches simultaneously against the same graph. CNPG logs show 3+ concurrent processes hitting the same timestamp with XX000 errors.

2. **Failure rate approaching 50%**: Logs show `270 failures vs 304 successes` - nearly half of all graph writes are failing.

3. **Deadlocks not classified as transient errors**: The `classifyAGEError()` function only treats XX000 and 57014 as transient. Deadlock (40P01) and serialization failure (40001) errors cause immediate batch failure without retry.

4. **Circular lock dependencies from parallel MERGE**: When two workers update overlapping nodes (e.g., same Collector referenced by multiple devices), they create lock contention:
   - Worker A locks Node X, waits for Node Y
   - Worker B locks Node Y, waits for Node X
   - Result: PostgreSQL aborts one as deadlock victim (40P01) or raises XX000

## What Changes

### 1. Write Serialization with Mutex (Root Cause Fix)
Add a Go-level mutex (`writeMu`) in `ageGraphWriter` to serialize all AGE graph MERGE operations. Multiple workers can still process the queue (for responsiveness), but only one can execute a database query at a time. This eliminates the concurrent write contention that causes deadlocks.

### 2. Expanded Transient Error Classification
Add SQLSTATE 40P01 (deadlock_detected) and 40001 (serialization_failure) to the list of transient errors that trigger retry with backoff. Includes string fallback patterns for wrapped errors.

### 3. Improved Backoff Strategy for Deadlocks
Implement separate backoff timing for deadlock errors (500ms base vs 150ms for other errors) with exponential growth and randomized jitter to break lock acquisition synchronization.

### 4. Deadlock-Specific Metrics
Add new OTel metrics to track deadlock and serialization failure frequency:
- `age_graph_deadlock_total`: Count of deadlock errors encountered
- `age_graph_serialization_failure_total`: Count of serialization failures
- `age_graph_transient_retry_total`: Count of all transient retries

## Impact
- Affected specs: device-relationship-graph
- Affected code:
  - `pkg/registry/age_graph_writer.go` (writeMu, classifyAGEError, backoffDelay)
  - `pkg/registry/age_graph_metrics.go` (new metrics)
- Risk: Low - serialization may reduce throughput but eliminates failures
- Performance: Graph writes become sequential but reliable. Queue depth may increase temporarily during bursts but will drain successfully.

## Trade-offs
- **Throughput vs Reliability**: Serializing writes reduces parallel throughput but ensures ~100% success rate vs ~50% with concurrent writes.
- **Queue Latency**: Individual batches may wait longer in queue, but total time to completion improves due to elimination of failed retries.
- **Worker Count**: Multiple workers still provide value for queue responsiveness even though writes are serialized.
