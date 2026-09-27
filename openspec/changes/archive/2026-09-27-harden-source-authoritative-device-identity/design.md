## Context

The site OT isolation investigation used an independent Go verifier from `host03` against the Armis export. At the aggregate level, the verifier found 37 compliant/unreachable devices out of 395 known-IP devices, or 9.4%, which matches the Armis dashboard's roughly 9% compliant count.

The per-device reconciliation did not match ServiceRadar:

- 34 export devices disagreed between independent verification and ServiceRadar northbound candidates.
- 66 export devices were missing from ServiceRadar candidates.
- 32 of 34 mismatches had a different MAC in ServiceRadar for the same Armis Device ID, often at a different site.
- CNPG showed active rows where `metadata.integration_id` matched the export Armis ID, but `metadata.armis_device_id` or `device_identifiers.armis_device_id` pointed to a different Armis ID.
- CNPG also showed the same numeric Armis export ID represented as both `armis_device_id` and `integration_id` identifiers on different device rows.
- A live aggregate query found 825 active devices with multiple Armis identifiers attached.

Local code review found two implementation paths that can explain this:

- `SyncIngestor` has an active-IP conflict recovery path that remaps incoming records and their identifiers to the existing row for an IP. In DHCP-heavy networks this can attach a source-authoritative Armis identity to an unrelated device that currently or previously owned the IP.
- `ArmisNorthboundRunner` joins both `armis_device_id` and generic `integration_id` identifiers, then prefers `ocsf_devices.metadata->>'armis_device_id'` before the joined identifier value. If metadata is stale or a generic identifier points elsewhere, candidate loading can emit the wrong Armis ID or omit the right one.

Existing retention/reaper workers clean sweep results, telemetry, alert state, and other operational records. They do not safely repair source identity drift. Duplicate reconciliation exists conceptually, but duplicate-only cleanup cannot fix wrong source IDs attached to one active row without more provenance and conflict policy.

## Goals

- Preserve source-authoritative device identity even when IP addresses churn or collide.
- Ensure Armis northbound updates are keyed by validated Armis Device IDs only.
- Detect and expose identity drift before it affects outbound actions.
- Provide a repair/backfill path for already polluted production data.
- Keep the fix general enough for other stable integration IDs, with Armis as the first concrete integration.

## Non-Goals

- Replace DIRE or redesign all device identity rules.
- Remove active-IP uniqueness in this change.
- Make IP addresses authoritative for source-integrated devices.
- Automatically delete unresolved conflicts after a retention period.
- Change the executive verifier tool or its report format as part of the product fix.

## Decisions

### Source IDs Are Authoritative

Typed source identifiers such as `armis_device_id` are the authoritative identity for source-owned devices. Generic `integration_id` is still useful metadata, but when an integration has a typed identifier the typed identifier wins and the generic value must not create a separate authoritative mapping.

### Sync Uses The Integration Identity Abstraction

The sync layer should not branch on concrete integration drivers. Producers emit the shared identity envelope (`integration_type`, `integration_id`, `sync_service_id`, optional typed source ID fields, and legacy lookup bridges). The sync ingestor iterates over the shared identity vocabulary for lookup and registration, while integration-specific consumers such as Armis northbound can still require the typed identifier they need for their external API.

### Active-IP Conflict Recovery Cannot Rebind Strong Source IDs

When an incoming update has a source-authoritative identifier and its IP collides with another active device, ingestion must not satisfy the unique IP constraint by reassigning the source identifier to the existing row unless the existing row already matches the same source-authoritative ID or another allowed strong non-MAC identity.

For unrelated rows, ingestion must preserve the source identity and either:

- move/clear the active IP from a stale provisional row when policy can prove that row is safe to retire, or
- leave the source-identified device unchanged and record an identity conflict requiring repair.

### Northbound Uses Validated Identifiers

Armis northbound candidate loading should start from `device_identifiers.identifier_type = 'armis_device_id'` for the configured source. Metadata may be used as display/provenance, but not as the primary outbound key when it disagrees with the identifier row.

Rows with multiple Armis IDs, split typed/generic IDs, metadata disagreement, or mismatched source linkage are not silently collapsed into outbound updates. They are skipped, counted, and reported as identity conflicts.

### Repair Is Explicit And Audited

Existing drift needs a backfill/repair tool. The tool should detect:

- one active device with multiple `armis_device_id` identifiers,
- one Armis Device ID represented on multiple active device rows,
- `metadata.armis_device_id` disagreeing with typed identifiers,
- `metadata.integration_id` or `metadata.source_device_id` matching an Armis export ID while the typed Armis ID differs,
- typed and generic Armis identifiers for the same value pointing to different devices.

Repairs should be idempotent, emit audit rows, and support dry-run output. Unresolved conflicts remain visible; they are not hidden by a 30-day cleanup job.

## Risks / Trade-Offs

- Some currently passing tests intentionally validate active-IP remapping behavior. They should be narrowed to weak/IP-only cases and replaced with strong-source collision tests.
- Some existing rows may remain skipped for northbound until repair runs. This is safer than sending wrong custom-property updates to Armis.
- Retaining conflict records increases operator noise initially, but it makes the data quality problem measurable and repairable.

## Migration Plan

1. Add schema/resource support for source identity conflicts or equivalent persisted diagnostics in the `platform` schema.
2. Add dry-run audit queries and backfill tooling for Armis identity drift.
3. Update sync ingestion to use the shared integration identity abstraction for typed/source-scoped identifiers and block source-authoritative IP remaps.
4. Harden Armis northbound candidate selection and conflict accounting.
5. Run the repair dry-run against `example-namespace`, review counts, then apply repairs in controlled batches.
6. Re-run the site verifier comparison and confirm candidate mismatches/missing rows drop to expected explainable cases.

## Open Questions

- Should active-IP conflict repair clear the IP from stale source-owned rows, or only from provisional/IP-only rows?
- Should conflict diagnostics be a first-class Ash resource, OCSF event records, or both?
- How much of the Armis-specific repair should be generalized immediately for NetBox and future integrations?
