## Why
- Nine query modules in the SRQL translator silently ignore unknown filter fields via `_ => {}` catch-all match arms, while six other modules correctly return `ServiceError::InvalidRequest`.
- When a user mistypes a query filter (e.g., `in:events severty:error` instead of `severity:error`), the API silently drops the invalid filter and returns *all* rows matching other criteria, which can leak sensitive data or produce confusing results.
- Inconsistent error handling violates the principle of least surprise and makes debugging user queries harder—some endpoints fail fast while others fail silently.

## What Changes
1. Replace the `_ => {}` catch-all in the `apply_filter` function of each affected query module with an explicit error return that names the unsupported field, matching the pattern used in `devices.rs` and `events.rs`.
2. Add unit tests for each fixed module asserting that queries with unknown filter fields return a 400-level error rather than silently succeeding.
3. Update the SRQL language reference documentation to clarify supported fields per entity, so users know which filters are valid.

### Affected Files
| File | Line | Current Behavior |
|------|------|------------------|
| `rust/srql/src/query/logs.rs` | 235 | Silent ignore |
| `rust/srql/src/query/timeseries_metrics.rs` | 120 | Silent ignore |
| `rust/srql/src/query/cpu_metrics.rs` | 191 | Silent ignore |
| `rust/srql/src/query/traces.rs` | 111 | Silent ignore |
| `rust/srql/src/query/services.rs` | 105 | Silent ignore |
| `rust/srql/src/query/otel_metrics.rs` | 145 | Silent ignore |
| `rust/srql/src/query/pollers.rs` | 103 | Silent ignore |
| `rust/srql/src/query/memory_metrics.rs` | 128 | Silent ignore |
| `rust/srql/src/query/disk_metrics.rs` | 133 | Silent ignore |

### Reference Implementation
Files with correct error handling that should be used as reference:
- `rust/srql/src/query/devices.rs:175-179`
- `rust/srql/src/query/events.rs:120-124`
- `rust/srql/src/query/interfaces.rs:214-216`
- `rust/srql/src/query/device_graph.rs:94-96`
- `rust/srql/src/query/device_updates.rs:120-122`

## Impact
- **Breaking Change (by design):** Queries that previously succeeded silently with invalid filters will now return HTTP 400 errors. This is the correct behavior and surfaces bugs in client code or user queries that were previously hidden.
- No schema changes or migrations required.
- Minimal code changes—each fix is a 3-4 line replacement of the catch-all arm.
- Test coverage additions ensure the fix does not regress.

## Related
- GitHub Issue: #2049
