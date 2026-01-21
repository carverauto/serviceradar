## 1. Investigation
- [x] 1.1 Identify the interface MAC source used for identifier enrichment (mapper interface observations) and document the source of truth.
- [x] 1.2 Confirm which tables and foreign keys must be re-pointed during a device merge (device_identifiers, discovered_interfaces, service_checks, alerts, agents, device_alias_states).

## 2. Identity Reconciliation
- [x] 2.1 Extend identity extraction to include additional MACs (from interfaces) and normalize them.
- [x] 2.2 Update lookup logic to resolve multiple identifiers in a single update and detect conflicting device IDs.
- [x] 2.3 Implement deterministic canonical device selection and merge flow (Ash action, atomic).
- [x] 2.4 Record merge_audit entries with reason and details when merges occur.
- [ ] 2.5 Emit IP alias metadata from mapper discovery before publishing device updates.
- [ ] 2.6 Persist IP alias sightings using DeviceAliasState (AliasEvents) during sync ingestion.
- [ ] 2.7 Resolve IP-only updates via confirmed alias states in DeviceLookup and IdentityReconciler.

## 3. Merge Reassignment
- [x] 3.1 Reassign `discovered_interfaces` records to the canonical device during merges (drop duplicates when keys collide).

## 4. Backfill and Ops
- [x] 4.1 Add AshOban scheduled reconciliation job with run logging/stats.
- [x] 4.2 Seed default reconciliation schedule configuration.
- [ ] 4.3 Run reconciliation in demo-staging and validate that `tonka01` collapses to a single device.

## 5. Tests
- [ ] 5.1 Add unit tests for multi-identifier resolution and merge outcomes.
- [ ] 5.2 Add integration test for reconciliation job and interface reassignment.
