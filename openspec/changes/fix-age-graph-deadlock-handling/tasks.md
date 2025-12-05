## 1. Write Serialization (Root Cause Fix)
- [x] 1.1 Add `writeMu sync.Mutex` to `ageGraphWriter` struct to serialize database writes.
- [x] 1.2 Wrap `ExecuteQuery` call in `processRequest` with mutex lock/unlock.
- [x] 1.3 Document the serialization approach in code comments.

## 2. Expand transient error classification
- [x] 2.1 Add SQLSTATE 40P01 (deadlock_detected) to `classifyAGEError()` as a transient error.
- [x] 2.2 Add SQLSTATE 40001 (serialization_failure) to `classifyAGEError()` as a transient error.
- [x] 2.3 Add string fallback patterns for "deadlock detected" and "could not serialize access" in wrapped errors.
- [x] 2.4 Define named constants for SQLSTATE codes for clarity.

## 3. Improve backoff strategy for deadlocks
- [x] 3.1 Add `defaultAgeGraphDeadlockBackoff` constant (500ms) for deadlock-specific backoff.
- [x] 3.2 Update `backoffDelay()` to accept SQLSTATE code and use longer backoff for deadlocks.
- [x] 3.3 Implement exponential backoff with randomized jitter.
- [x] 3.4 Add `AGE_GRAPH_DEADLOCK_BACKOFF_MS` environment variable for tuning.

## 4. Add deadlock-specific metrics
- [x] 4.1 Add `age_graph_deadlock_total` counter metric.
- [x] 4.2 Add `age_graph_serialization_failure_total` counter metric.
- [x] 4.3 Add `age_graph_transient_retry_total` counter metric.
- [x] 4.4 Record metrics in `processRequest` when corresponding errors occur.

## 5. Testing and validation
- [ ] 5.1 Build and lint verification (completed).
- [ ] 5.2 Deploy to demo namespace and verify deadlocks/XX000 errors are eliminated.
- [ ] 5.3 Monitor metrics to confirm near-zero deadlock rate.
- [ ] 5.4 Verify queue drains successfully under load.
