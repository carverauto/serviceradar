# Change: Fix pgx batch error handling for CNPG writes

## Why
Issue #2153 identifies multiple CNPG write paths that use `pgx.SendBatch` and then immediately call `BatchResults.Close()` without reading results via `BatchResults.Exec()`. This can silently discard per-statement INSERT errors, causing undetected data loss (for example, dropped CloudEvents or missing user rows) while callers proceed as if the write succeeded.

## What Changes
- Update CNPG batch write call sites to always read each queued batch result (`br.Exec()`) before closing (`br.Close()`), returning the first encountered error with context (operation name + command index).
- Introduce a small shared helper for "exec all + close" to keep batch handling consistent and reduce the risk of future regressions.
- Audit existing `SendBatch` usages and bring them onto the same pattern, including paths that currently log-and-continue so they still drain results and can log the real insert error.

## Impact
- Affected specs: `db-batch-writes` (new)
- Affected code (expected):
  - `pkg/db/events.go` (`InsertEvents`)
  - `pkg/db/auth.go` (`StoreBatchUsers`)
  - `pkg/db/cnpg_unified_devices.go` (`DeleteDevices` audit batch)
  - Other `pkg/db/**` `SendBatch` call sites discovered during audit
- Behavior change: previously hidden DB write failures will now return errors to callers (or be logged explicitly for "best-effort" audit batches).
- Risk: Low. This change only affects error surfacing and batch result consumption; it does not change SQL statements or schemas.
