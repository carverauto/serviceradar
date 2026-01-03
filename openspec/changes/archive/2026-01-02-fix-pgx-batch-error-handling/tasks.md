## 1. Batch Helper
- [x] 1.1 Add a shared helper in `pkg/db/` to execute all queued batch commands (`br.Exec()` for `batch.Len()` items) and always close the results (`br.Close()`), preserving close errors when no prior error exists.
- [x] 1.2 Add unit tests for the helper with a fake `pgx.BatchResults` that can inject an error at a specific command index.

## 2. Fix Affected Call Sites
- [x] 2.1 Update `pkg/db/events.go` `InsertEvents` to use the helper and return an error when any queued INSERT fails.
- [x] 2.2 Update `pkg/db/auth.go` `StoreBatchUsers` to use the helper and return an error when any queued INSERT fails.
- [x] 2.3 Update `pkg/db/cnpg_unified_devices.go` `DeleteDevices` audit batch to drain results and log the real insert error(s) (best-effort behavior remains).
- [x] 2.4 Audit the remaining `SendBatch` usages under `pkg/db/**` and either migrate them to the helper or document why they intentionally do not surface errors.

## 3. Verification
- [x] 3.1 Run `go test ./pkg/db/...` (and any targeted tests added by this change).
- [x] 3.2 Confirm `openspec validate fix-pgx-batch-error-handling --strict` passes.
