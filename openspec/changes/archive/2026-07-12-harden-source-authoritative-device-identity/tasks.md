## 1. Investigation and Data Audit

- [x] 1.1 Capture a repeatable SQL audit for Armis identity drift: multiple typed IDs per device, one typed ID on multiple devices, metadata/identifier disagreement, and split typed/generic identifiers.
- [x] 1.2 Add a dry-run repair report that includes affected device UID, current IP/MAC/site, conflicting source IDs, proposed action, and confidence.

## 2. Identity Model and Ingestion

- [x] 2.1 Add persisted source identity conflict diagnostics in the `platform` schema, or extend an existing audit/event model if it already fits.
- [x] 2.2 Update `SyncIngestor` to use the shared identity vocabulary when registering typed source-authoritative identifiers.
- [x] 2.3 Keep generic `integration_id` values scoped to the integration source and prevent them from creating separate authoritative mappings when a typed source ID exists.
- [x] 2.4 Refactor active-IP conflict recovery so source-authoritative identifiers are not remapped to unrelated active IP owners.
- [x] 2.5 Add identity conflict logging/telemetry for blocked source-authoritative remaps.

## 3. Northbound Candidate Safety

- [x] 3.1 Change Armis northbound candidate loading to key outbound updates from validated `armis_device_id` identifiers.
- [x] 3.2 Skip and count candidates with metadata/identifier disagreement, multiple Armis IDs, split typed/generic mappings, or source linkage conflicts.
- [x] 3.3 Expose skipped conflict counts and examples in northbound run metadata/events so operators can see why rows were not updated.

## 4. Backfill and Repair

- [x] 4.1 Implement an idempotent dry-run/apply repair task for existing Armis identity drift.
- [x] 4.2 Repair safe cases automatically, such as stale metadata disagreeing with a single typed Armis identifier.
- [x] 4.3 Leave ambiguous cases unresolved with persisted conflict diagnostics and no northbound update until reviewed.

## 5. Tests and Verification

- [x] 5.1 Add regression tests for DHCP IP reuse where the same Armis ID moves IP and remains the same canonical device.
- [x] 5.2 Add regression tests for source-authoritative integration updates colliding with an unrelated active IP row.
- [x] 5.3 Add regression tests for Armis northbound candidate selection with stale metadata and split typed/generic identifiers.
- [x] 5.4 Update existing active-IP conflict tests so weak/IP-only remapping remains covered without permitting strong source ID rebinding.
- [x] 5.5 Run focused Elixir tests for identity reconciliation, sync ingestion, and Armis northbound runner.
  - Focused non-DB tests passed locally. DB-backed `sync_batch_resolution_test --include integration` was attempted but blocked by local `localhost:5432` refusal and a stale local Kubernetes context (`127.0.0.1:55345` refused).
