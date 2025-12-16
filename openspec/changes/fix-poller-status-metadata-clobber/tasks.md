## 1. Implementation
- [x] 1.1 Update `pkg/db/cnpg_registry.go:upsertPollerStatusSQL` conflict clause to only update operational columns and preserve registration metadata.
- [x] 1.2 Ensure `first_registered` / `first_seen` are not cleared or overwritten by status-only calls (especially when callers omit `FirstSeen`).
- [x] 1.3 Add regression tests that fail if poller registration metadata changes after a status update (explicit registration → status update).
- [x] 1.4 Audit `UpdatePollerStatus` call sites in `pkg/core/**` (and elsewhere) to confirm they are intended to be status/heartbeat updates only.
- [x] 1.5 Confirm service registry registration/upsert paths continue to update registration metadata as intended.

## 2. Validation
- [x] 2.1 Run `openspec validate fix-poller-status-metadata-clobber --strict`.
- [x] 2.2 Run targeted Go tests for the touched packages (at minimum `go test ./pkg/db/... ./pkg/core/...`).
