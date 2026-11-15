# Implementation handoff

Approval: product owner authorized proposal completion and implementation.

## Current pass

Implement listener consolidation and its chart/Compose migration. In parallel,
implement bounded publication under `accelerate-log-ingestion`. Keep JSON
compatible while these foundations land.

## Dependency order

1. Concurrent listeners and deployment consolidation.
2. Bounded publisher and queue handoff.
3. Shared native Zen, versioned datasvc rules and binary-reader parity; then
   collector normalization and protobuf batches.
4. Optional independent JetStream shard streams and routing epochs.
5. Portable receive improvements and AF_XDP/ZC Rx prototypes using the same
   normalization/publishing contract.

Consumer replacement and warehouse format changes require equivalent semantics
and measured benefit. They are experiments, not presumed bottlenecks.

## Evidence

- Proposal validation passed before implementation.
- Research identifies code paths; no end-to-end throughput result is claimed.
- Live operational inventory is not stored in the repository.
- Runtime/chart/publisher checks are pending in the current pass.

## Next agent prompt

Read tasks and the three companion proposals, then continue the first incomplete
slice. Verify public behavior and preserve unrelated work. Do not mark rollout
or performance gates complete based on unit tests. Keep this handoff current.
