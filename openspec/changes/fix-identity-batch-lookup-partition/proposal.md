# Change: Fix partition-scoped batch identifier lookup

## Why
GitHub issue `#2140` reports that `IdentityEngine.batchLookupByStrongIdentifiers` performs batch identifier lookups without filtering by `partition`. In a multi-tenant deployment, two partitions can legitimately contain the same identifier value (e.g., MAC address). When updates from different partitions land in the same batch, the current implementation can assign the first-matched `device_id` to all updates, violating partition isolation and silently corrupting device identity.

This is a security-relevant correctness issue: cross-partition identity assignment can leak inventory and telemetry between tenants and break the integrity of the canonical device model.

## What Changes
- Add a `partition` parameter to the DB batch lookup API and filter the underlying SQL query by partition.
- Update `IdentityEngine.batchLookupByStrongIdentifiers` to preserve correctness when a batch contains multiple partitions by grouping updates by partition and performing per-partition batch lookups.
- Add regression tests to ensure mixed-partition batches resolve to partition-correct device IDs (no cross-partition matches).

## Impact
- Affected specs: `device-identity-reconciliation`
- Affected code:
  - `pkg/registry/identity_engine.go`
  - `pkg/db/interfaces.go`
  - `pkg/db/cnpg_identity_engine.go`
  - `pkg/db/mock_db.go`
  - `pkg/registry/*_test.go` (new regression coverage)
- Behavior change: only for mixed-partition batches with colliding identifier values; fixes prior incorrect cross-partition assignment.

