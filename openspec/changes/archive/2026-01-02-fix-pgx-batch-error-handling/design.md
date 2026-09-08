## Context
`pgx.SendBatch` requires callers to read results for each queued command to reliably surface per-command errors. Several ServiceRadar DB write paths only call `BatchResults.Close()`, which can discard insert errors and hide partial write failures.

The codebase already contains correct examples (for example, `sendCNPG` in `pkg/db/cnpg_metrics.go` and `sendCNPGBatch` in `pkg/db/cnpg_device_updates_retry.go`) that call `br.Exec()` for every queued command before closing.

## Goals / Non-Goals
- Goals:
  - Ensure every CNPG batch write path consumes results for each queued command.
  - Surface INSERT failures to callers (or log them explicitly for best-effort paths).
  - Reduce copy/paste batch handling logic to avoid reintroducing the bug.
- Non-Goals:
  - Change SQL behavior, schemas, or add transactional semantics.
  - Add new dependencies unless required for testing.

## Decisions
- Decision: Add a small helper in `pkg/db` that implements the standard pattern:
  - `br := executor.SendBatch(ctx, batch)`
  - `for i := 0; i < batch.Len(); i++ { br.Exec() }`
  - `br.Close()` in a `defer` to ensure cleanup even on early return
  - Include `operation name` and `command index` in errors

## Alternatives Considered
- Inline fixes at each call site:
  - Pros: minimal new code
  - Cons: easy to miss future uses; inconsistency across files

## Risks / Trade-offs
- Risk: Surfacing errors may expose previously hidden data problems (bad inputs, constraint issues) and cause callers to retry or fail where they previously succeeded.
- Trade-off: Slight additional CPU per batch to read results, but this is required for correctness and is already the established pattern elsewhere in the codebase.

## Migration Plan
1. Add helper + tests.
2. Update the affected call sites (starting with `InsertEvents` and `StoreBatchUsers`).
3. Audit remaining `SendBatch` usages and migrate them.

## Open Questions
- For best-effort audit/log batches (for example, device deletion audit trails), should the system:
  - Continue and only log errors (current behavior), or
  - Fail the higher-level operation when the audit record cannot be written?
