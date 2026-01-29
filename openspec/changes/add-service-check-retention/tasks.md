# Tasks

## Implementation Tasks

- [x] 1. Create Ecto migration `add_observability_retention_policies.exs`
  - Follow pattern from `20260120021558_ensure_discovered_interfaces_hypertable.exs`
  - Add retention policies for all hypertables in a single migration
  - Use `if_not_exists => true` for idempotency
  - Group by retention tier (7d, 14d, 30d, 90d)
  - Add `remove_retention_policy()` for each in down migration

- [x] 2. Add CNPG spec delta for observability retention requirements
  - Document each retention policy and its interval
  - Add scenarios for policy creation and data pruning

## Validation Tasks

- [ ] 3. Test migration on fresh database
  - Verify all retention policies are created
  - Query `timescaledb_information.jobs` to confirm policy_retention jobs

- [ ] 4. Test migration rollback
  - Verify all `remove_retention_policy()` calls succeed
  - Confirm no policies remain after rollback

- [ ] 5. Test on database with existing data
  - Verify migration does not cause immediate data deletion
  - Confirm retention jobs are scheduled by TimescaleDB background worker
