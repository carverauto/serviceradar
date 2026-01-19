## 1. Investigation
- [ ] 1.1 Identify the update payload fields that carry interface MAC lists (mapper/sweep metadata) and document the source of truth.
- [ ] 1.2 Confirm which tables and foreign keys must be re-pointed during a device merge (ocsf_devices, device_identifiers, discovered_interfaces, service_checks, ocsf_agents, device_alias_states, device_updates).

## 2. Identity Reconciliation
- [ ] 2.1 Extend identity extraction to include additional MACs (from metadata) and normalize them.
- [ ] 2.2 Update lookup logic to resolve multiple identifiers in a single update and detect conflicting device IDs.
- [ ] 2.3 Implement deterministic canonical device selection and merge flow (Ash action, atomic).
- [ ] 2.4 Record merge_audit entries with reason and details when merges occur.

## 3. Interface Storage Consolidation
- [ ] 3.1 Identify interface publishers writing to `platform.discovered_interfaces` (mapper) and update them to write to `ocsf_devices.network_interfaces`.
- [ ] 3.2 Batch interface updates per device to avoid excessive writes.

## 4. Backfill and Ops
- [ ] 4.1 Add a mix task or one-off script to reconcile existing duplicates (demo-staging first).
- [ ] 4.2 Run reconciliation + interface rollup in demo-staging and validate that `tonka01` is single and interfaces populate.

## 5. Tests
- [ ] 5.1 Add unit tests for multi-identifier resolution and merge outcomes.
- [ ] 5.2 Add integration test for interface rollup population.
