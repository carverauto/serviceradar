## Context
`IdentityEngine.lookupByStrongIdentifiers` correctly filters identifier lookups by `partition`, but `IdentityEngine.batchLookupByStrongIdentifiers` does not. This creates cross-partition identity assignment when identifier values collide across partitions within the same batch.

## Goals / Non-Goals
- Goals:
  - Guarantee partition isolation for all strong-identifier lookups, including batch paths.
  - Preserve batch-mode performance characteristics for single-partition batches.
- Non-Goals:
  - Data repair/migration of previously-corrupted device identities (out of scope for this change; handled operationally if needed).

## Decisions
- Decision: Group updates by partition and run per-partition batch queries.
  - Rationale: Minimizes SQL complexity, keeps the lookup API stable (single partition per call), and naturally matches the correctness constraint.

## Alternatives Considered
- Single query across partitions using composite keys (e.g., `UNNEST(partitions, values)` and joining on both columns).
  - Rejected: Higher SQL complexity and more complicated result mapping; can be revisited if per-partition query counts become a bottleneck.
- Disable batch lookup when mixed partitions are present (fall back to single lookups).
  - Rejected: Correct but loses the optimization exactly when batch sizes are large and mixed partitions are common.

## Risks / Trade-offs
- More queries when a batch spans many partitions.
  - Mitigation: Partition count per batch is typically small; deduplicate identifier values within each partition and type to reduce query payload.

## Migration Plan
1. Update DB API + SQL to require partition for batch lookups.
2. Update IdentityEngine to group-by-partition and call the new API.
3. Add regression tests for mixed-partition batches.

## Open Questions
- Should we add an explicit metric for identifier collisions across partitions to aid detection of multi-tenant environments with common MAC reuse?

