## Context
DIRE currently resolves device identity using a single strong identifier (armis/integration/netbox/mac) from each update. When multiple sources report the same device with different MACs (common on multi-interface routers), DIRE creates separate device IDs because only one MAC is registered per update. The demo-staging `tonka01` duplicate shows this failure. Additionally, interface data is written to `platform.discovered_interfaces` but never surfaces in `ocsf_devices.network_interfaces`, so the UI interfaces tab remains empty.

## Goals / Non-Goals
- Goals:
  - Reconcile updates that include multiple strong identifiers into a single canonical device ID.
  - Register interface MACs as strong identifiers so subsequent updates map consistently.
  - Preserve or merge related inventory records during identity merges.
  - Materialize `network_interfaces` from `discovered_interfaces` for UI consumption.
- Non-Goals:
  - Redesign identifier priority ordering or add new external IDs beyond MAC lists.
  - Change SRQL schema or introduce new UI navigation.

## Decisions
- Decision: Expand the identity reconciler to accept an identifier set per update.
  - The update payload will surface a list of interface MACs (from mapper/sweep metadata or interface discovery), normalized and filtered (ignore empty/invalid MACs).
  - The reconciler will look up all identifiers, detect conflicts, and converge on a single canonical device ID.

- Decision: Deterministic canonical selection.
  - Prefer an existing `sr:` device ID present on the update.
  - Otherwise prefer the device ID associated with the highest-priority identifier.
  - Break ties by most recent `last_seen_time` in `ocsf_devices`.

- Decision: Merge as an atomic Ash action.
  - Use Ash actions with `atomic/3` so identifier reassignment, inventory updates, and merge audit rows commit together.
  - Avoid `require_atomic? false` for convenience; keep the merge atomic to prevent partial updates.

- Decision: Stop writing to `platform.discovered_interfaces` and write interfaces directly to `ocsf_devices.network_interfaces`.
  - Mapper interface publishing will update the inventory record for the device with the latest interface set.
  - Deduplicate by interface identity (name/mac/if_index) within the write path.

## Risks / Trade-offs
- Incorrect merges if MAC lists are incomplete or noisy. Mitigate by requiring at least two strong identifiers in the same update before merging.
- Additional DB writes when registering interface MACs. Mitigate with batching and avoiding duplicates.
- Interface writes add update pressure to `ocsf_devices`; mitigate by batching per-device updates.

## Migration Plan
1. Implement multi-identifier reconciliation and merge action.
2. Add identifier enrichment (register interface MACs) in the ingest pipeline.
3. Update mapper interface publishing to write directly into `network_interfaces`.
4. Run reconciliation task in demo-staging to merge existing duplicates and backfill interface arrays.

## Open Questions
- Where is the authoritative interface MAC list for each update (mapper payload vs. batch results)?
- Should we allow merging across source types (sync vs. mapper) only when MAC overlap is exact, or also when hostname matches?
- What is the desired refresh cadence for `network_interfaces` rollups?
