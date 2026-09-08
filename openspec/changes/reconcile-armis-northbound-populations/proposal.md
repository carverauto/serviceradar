# Change: Reconcile Armis inbound and northbound populations

## Why

The customer Armis integration currently reports a successful northbound run with
14,431 updates out of a displayed population of 17,772 and 3,341 skips. Of the
skips, 3,295 are canonical devices carrying multiple typed Armis IDs and 46 are
metadata/identifier disagreements. The same source displays 22,308 devices for
its last inbound sync. These three numbers are not counts of the same
population:

- inbound `last_device_count` is recomputed from active canonical inventory
  rows linked to the source and can include devices accumulated across runs;
- northbound `device_count` is the safe outbound candidates plus conflicted
  canonical rows, so one multi-ID row counts once even when it owns many Armis
  IDs; and
- neither count is bound to the exact completed Armis collection that the
  northbound run is supposed to reflect.

The UI therefore cannot answer the operational question: for each distinct
Armis device ID returned by the latest complete import, was it updated, safely
deduplicated, explicitly withheld, or missed? Repeated Armis records with the
same ID and distinct Armis IDs that may represent one physical asset also need
separate treatment; neither is evidence that ServiceRadar may silently merge
source identities.

## What Changes

- Define one population-accounting contract from a completed Armis source
  collection through northbound execution. Raw rows, distinct source IDs,
  duplicate occurrences, invalid rows, eligible IDs, withheld IDs, accepted
  updates, failures, and unattempted IDs become disjoint, reconcilable counts.
- Reuse the activated `device_source_snapshots` and
  `device_source_observations` collection as the authoritative inbound
  membership. Northbound runs bind to one immutable collection ID instead of
  comparing against mutable canonical inventory or only the source's latest
  aggregate count.
- Persist one disposition per distinct source ID for each northbound run so the
  summary can be reproduced after later source collections or identity repairs.
- Classify repeated records carrying the same normalized Armis ID as source-row
  duplicates. Collapse compatible repetitions to one source identity; withhold
  conflicting repetitions with an explicit reason.
- Treat distinct Armis IDs that appear to describe the same physical asset as
  source-alias candidates, not as proven duplicates. Do not merge or fan out
  automatically without independent source-side or operator-approved alias
  evidence.
- Fence every automatic device merge path against combining disjoint,
  non-empty source-authoritative ID sets. Record blocked pair and transitive
  component merges for diagnosis.
- Add dry-run-first, auditable remediation for the existing multi-ID and
  metadata-disagreement populations, with post-write and post-sync convergence
  checks.
- Replace the opaque inbound/northbound count cards with a collection-bound
  reconciliation funnel and explicit reason totals. Transport success remains
  separate from population reconciliation status.

## Impact

- Affected specs: `sync-service-integrations`,
  `device-identity-reconciliation`
- Related active changes:
  - builds on `harden-source-authoritative-device-identity` candidate safety and
    conflict diagnostics;
  - complements, but does not replace,
    `remediate-armis-overmerge-disposition`, whose mega-device cleanup concerns
    MAC-group reconstruction rather than current Armis source-ID accounting;
  - supplies runtime accounting scenarios for `add-hermetic-armis-dire-e2e`.
- Affected code:
  - Go Armis sync pagination/mapping and sync collection metadata
  - `ServiceRadar.Inventory.DeviceSourceObservationIngestor`,
    `DeviceSourceSnapshot`, and `DeviceSourceObservation`
  - `ServiceRadar.Inventory.Identity.MergeEngine`, `DuplicateSweep`, and all
    callers capable of automatic merges or raw identifier reassignment
  - `ServiceRadar.Integrations.ArmisNorthboundRunner` and
    `IntegrationUpdateRun`, plus a persisted per-source-ID run disposition
    resource
  - source identity audit/remediation resources and workers
  - the web-ng Integration Sources details and recent-run views
- Affected data: new northbound run-disposition rows and collection references;
  existing Armis identity rows are changed only by an explicitly approved
  remediation execution.
- No implementation or production data mutation begins until this proposal is
  approved.
