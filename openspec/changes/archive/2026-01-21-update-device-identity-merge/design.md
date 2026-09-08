## Context
DIRE currently resolves device identity using a single strong identifier (armis/integration/netbox/mac) from each update. When multiple sources report the same device with different MACs (common on multi-interface routers), DIRE creates separate device IDs because only one MAC is registered per update. The demo-staging `tonka01` duplicate shows this failure. Interface data is now presented via SRQL `in:interfaces` over `platform.discovered_interfaces` (tracked in `add-interface-timeseries`), so this change focuses on identity reconciliation and merge correctness.

## Goals / Non-Goals
- Goals:
  - Reconcile updates that include multiple strong identifiers into a single canonical device ID.
  - Register interface MACs as strong identifiers so subsequent updates map consistently.
  - Preserve or merge related inventory records during identity merges.
- Non-Goals:
  - Redesign identifier priority ordering or add new external IDs beyond MAC lists.
  - Change SRQL schema or interface presentation (handled elsewhere).

## Decisions
- Decision: Expand the identity reconciler to accept an identifier set per update.
  - The update payload will surface a list of interface MACs (from mapper/sweep metadata or interface discovery), normalized and filtered (ignore empty/invalid MACs).
  - The reconciler will look up all identifiers, detect conflicts, and converge on a single canonical device ID.

- Decision: Deterministic canonical selection.
  - Prefer an existing `sr:` device ID present on the update.
  - Otherwise prefer the device ID associated with the highest-priority identifier.
  - Break ties by most recent `last_seen_time` in `ocsf_devices`.

- Decision: Merge as an atomic Ash transaction.
  - Wrap identifier reassignment, inventory updates, and merge audit rows in `Ash.transaction/2`.
  - Avoid `require_atomic? false` for convenience; keep the merge atomic to prevent partial updates.

- Decision: Reassign interface observations during merges.
  - Move `discovered_interfaces` records from the non-canonical device ID to the canonical device ID.
  - If an identical interface observation already exists on the canonical device (same timestamp + interface_uid), drop the duplicate record.

## Risks / Trade-offs
- Incorrect merges if MAC lists are incomplete or noisy. Mitigate by requiring at least two strong identifiers in the same update before merging.
- Additional DB writes when registering interface MACs. Mitigate with batching and avoiding duplicates.
- Reassigning interface observations can touch many rows; mitigate by batch updates and avoiding duplicate key conflicts.

## Migration Plan
1. Implement multi-identifier reconciliation and merge action.
2. Add identifier enrichment (register interface MACs) in the ingest pipeline.
3. Reassign interface observations when merges occur.
4. Ensure the reconciliation scheduler runs and validate merges in demo-staging.

## Open Questions
- Where is the authoritative interface MAC list for each update (mapper payload vs. batch results)?
- Should we allow merging across source types (sync vs. mapper) only when MAC overlap is exact, or also when hostname matches?
- What is the desired max merge batch size per reconciliation run in production?
