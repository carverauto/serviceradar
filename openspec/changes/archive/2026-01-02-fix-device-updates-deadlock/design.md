## Context

Issue #2087 reports PostgreSQL deadlocks (SQLSTATE 40P01) during CNPG `device_updates` batch operations. This is the same class of problem that was fixed for AGE graph writes in #2058, where concurrent MERGE queries caused circular lock dependencies.

### Deadlock Scenario

The deadlock occurs when multiple concurrent calls to `ProcessBatchDeviceUpdates` execute overlapping database operations:

```
Thread 1: ProcessBatchDeviceUpdates([device-A, device-B])
  -> RegisterDeviceIdentifiers(device-A)
     - Acquires lock on device_identifiers row (identifier_type, identifier_value, partition)
  -> PublishBatchDeviceUpdates([device-A, device-B])
     - Waits for lock on unified_devices row for device-B

Thread 2: ProcessBatchDeviceUpdates([device-C, device-B])
  -> RegisterDeviceIdentifiers(device-B)
     - Acquires lock on different device_identifiers row
  -> PublishBatchDeviceUpdates([device-C, device-B])
     - Waits for lock on unified_devices row for device-B (held by Thread 1's pending batch)

Result: Circular wait → PostgreSQL detects deadlock → One transaction aborted with 40P01
```

### Call Sites Triggering Concurrent Writes

| File | Line | Context |
|------|------|---------|
| `pkg/core/metrics.go` | 245, 563 | Metrics processing |
| `pkg/core/pollers.go` | 1386, 1445, 1503 | Poller status updates |
| `pkg/core/flush.go` | 334 | Periodic flush |
| `pkg/core/discovery.go` | 127, 460, 833 | Discovery events |
| `pkg/core/services.go` | 199 | Service registration |
| `pkg/mapper/publisher.go` | 238 | Mapper publishing |

## Goals / Non-Goals

**Goals:**
- Eliminate deadlock errors in device_updates operations
- Maintain data consistency across all concurrent callers
- Add observability for deadlock frequency
- Follow established patterns from AGE graph fix

**Non-Goals:**
- Optimize throughput (reliability is prioritized)
- Change database schema or indexes
- Modify the batch operation SQL queries themselves

## Decisions

### Decision 1: Go-level Mutex Serialization
**What:** Add a `sync.Mutex` in the DB struct to serialize all CNPG device-related batch writes.

**Why:**
- Proven effective in AGE graph writer (reduced ~50% failure rate to ~0%)
- Simple implementation with minimal code changes
- No database-level changes required
- Works regardless of which PostgreSQL connection pool member handles the request

**Alternatives considered:**
1. **SELECT FOR UPDATE with ORDER BY**: Requires modifying all call sites to pre-acquire locks in consistent order. More complex, error-prone if any call site misses the pattern.
2. **PostgreSQL Advisory Locks**: Application-level locks via `pg_advisory_xact_lock()`. Would require hash-based key derivation and careful transaction scoping.
3. **Serializable Isolation Level**: Would prevent anomalies but increases abort rate and requires application-level retry logic anyway.

### Decision 2: Transient Error Retry with Backoff
**What:** Classify 40P01 (deadlock) and 40001 (serialization failure) as transient errors with automatic retry.

**Why:**
- Provides defense-in-depth if mutex contention or timing edge cases still occur
- Consistent with AGE graph error handling
- Allows gradual recovery rather than immediate failure

**Configuration:**
- Base backoff: 500ms (longer than AGE graph's 150ms due to larger batch sizes)
- Max attempts: 3
- Jitter: 0-100% of base to avoid thundering herd

### Decision 3: Mutex Scope
**What:** Single mutex protecting all device-related CNPG writes.

**Why:**
- `unified_devices`, `device_identifiers`, and `network_sightings` tables are often updated together in the same logical flow
- Using separate mutexes per table would still allow cross-table deadlocks
- Single mutex ensures atomicity of the entire `ProcessBatchDeviceUpdates` flow

**Trade-off:** Slightly lower concurrency than per-table locks, but eliminates all deadlock scenarios.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Reduced write throughput | Acceptable for reliability; batching already amortizes overhead |
| Mutex contention under high load | Monitor queue depth; batch size limits natural concurrency |
| Increased latency for individual writes | p99 latency may increase but p50 should remain stable |
| Mutex held during network I/O | Keep critical section minimal (only batch execution) |

## Migration Plan

1. **Phase 1**: Deploy mutex + retry logic to demo environment
2. **Phase 2**: Monitor for 24-48 hours, verify zero deadlock errors
3. **Phase 3**: Roll out to production with feature flag if needed
4. **Rollback**: Remove mutex acquisition (no schema changes to revert)

## Open Questions

1. Should we add a circuit breaker like AGE graph writer has?
   - Recommendation: No, device updates are more critical than graph writes. Prefer retry over rejection.

2. Should the mutex be per-partition to allow some parallelism?
   - Recommendation: Start with global mutex for simplicity. Can optimize later if throughput is insufficient.
