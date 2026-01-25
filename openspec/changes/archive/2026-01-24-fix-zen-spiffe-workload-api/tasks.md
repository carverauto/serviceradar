## 1. Implementation
- [x] 1.1 Update zen SPIFFE Workload API error handling to classify PermissionDenied/no identity issued as a configuration error with actionable logging.
- [x] 1.2 Ensure retries are bounded and terminate with a clear error after the configured max attempts.
- [x] 1.3 Add/extend unit tests for SPIFFE error classification and retry behavior.

## 2. Validation
- [x] 2.1 Run `cargo test` in `cmd/consumers/zen` or the relevant workspace to cover the new logic.
