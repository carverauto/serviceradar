# Change: Harden source-authoritative device identity

## Why

The site Armis verifier showed that the aggregate OT isolation result is plausible, but the per-device ServiceRadar data layer is not trustworthy enough for northbound updates. A July 7, 2026 CNPG probe in `example-namespace` found Armis Device IDs split across different `armis_device_id` and `integration_id` identifier rows, active device rows with multiple Armis identifiers, and rows where metadata and authoritative identifiers disagree.

The likely root cause is that strong integration identity can be remapped through active-IP conflict recovery in a DHCP-heavy environment, while Armis northbound candidate selection trusts stale metadata and generic integration IDs. That lets transient IP evidence overwrite stable source identity and can update the wrong Armis device or skip the correct one.

## What Changes

- Treat source-owned stable IDs as source-authoritative identifiers that cannot be silently rebound because of an IP collision.
- Refactor sync ingestion around the integration identity abstraction so active-IP uniqueness does not remap strong source identifiers onto unrelated existing device rows.
- Register typed source identifiers consistently through the shared identity vocabulary, and keep generic `integration_id` scoped and non-authoritative when a typed identifier exists.
- Harden Armis northbound candidate loading so outbound updates are keyed by validated `armis_device_id` identifiers, not stale metadata or ambiguous generic IDs.
- Add identity-drift detection, operator diagnostics, and repair/backfill tooling for existing rows with conflicting Armis IDs, split typed/generic identifiers, or metadata/identifier disagreement.
- Add regression coverage for DHCP/IP reuse, strong source identity collisions, and northbound candidate conflict handling.

## Impact

- Affected specs: `device-identity-reconciliation`, `sync-service-integrations`, `device-inventory`
- Affected code:
  - `ServiceRadar.Inventory.SyncIngestor` strong identifier extraction, identifier registration, and active-IP conflict recovery
  - `ServiceRadar.Inventory.IdentityReconciler` source-authoritative conflict policy
  - `ServiceRadar.Integrations.ArmisNorthboundRunner` candidate selection and conflict reporting
  - Elixir migrations/resources for identity conflict diagnostics or audit records
  - Backfill/repair mix task or scheduled job for existing Armis identity drift
  - Integration and regression tests under `elixir/serviceradar_core/test`
