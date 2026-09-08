# Tasks

## 1. Contract and live baseline

- [ ] 1.1 Capture a fresh customer Armis collection and report raw rows, valid ID
  occurrences, distinct normalized Armis IDs, repeated occurrences, conflicting
  repeated payloads, configured-query overlap, and invalid rows. Do not infer
  these values from active canonical inventory.
- [ ] 1.2 Classify distinct Armis IDs sharing canonical UID, MAC, serial,
  hostname, or IP as source-alias candidates; determine whether Armis supplies
  an authoritative alias/duplicate relation. Keep shared-IP-only matches out of
  any approval set.
- [x] 1.3 Record the pre-change customer reconciliation baseline for source
  `0f001c87-ebbb-42c1-93a0-95b9ed61bb3c`, including the 3,295 multi-ID rows,
  46 metadata disagreements, source-ID freshness distribution, and merge audit
  linkage.

## 2. Inbound collection accounting

- [x] 2.1 Extend the Go Armis producer to normalize IDs across all configured
  queries/pages, preserve one source observation per distinct ID, and publish
  exact raw/excluded/valid/invalid/distinct/duplicate counts plus bounded
  duplicate diagnostics.
- [x] 2.2 Define and test compatible duplicate consolidation and
  identity-critical conflicting duplicate detection. Repeated rows with the
  same ID must not silently use order-dependent last-write-wins behavior.
- [x] 2.3 Extend `DeviceSourceObservationIngestor` and `DeviceSourceSnapshot` to
  validate and persist the accounting equations. Reject inconsistent metadata
  and never activate an incomplete collection.
- [x] 2.4 Stop deriving the displayed inbound Armis population from accumulated
  active canonical rows. Display the activated collection's distinct source-ID
  count, while marking legacy/unavailable accounting explicitly.

## 3. Collection-bound northbound ledger

- [x] 3.1 Add Ash resources and generated migrations for northbound collection
  references, reconciliation totals, and one immutable per-source-ID run
  disposition. Add restrictive identities/indexes and bounded retention without
  purging unresolved conflict/repair audit evidence.
- [x] 3.2 Change `ArmisNorthboundRunner` to select one complete activated
  collection for the configured source instance and materialize all source IDs
  before any outbound request.
- [x] 3.3 Resolve each source observation to exactly one mutually exclusive
  eligible or withheld disposition, including unresolved canonical identity,
  deleted canonical device, missing availability, metadata disagreement,
  unapproved multiple-ID/alias evidence, conflicting duplicate payload, and
  source-linkage mismatch.
- [x] 3.4 Finalize eligible rows as accepted, failed, or unattempted. Preserve
  stopped-batch outcomes and enforce both count equations before a run can be
  finalized as reconciled.
- [x] 3.5 Update OCSF events, logs, and telemetry with collection identity,
  exact totals, reason counts, and bounded examples. Keep non-withholding
  diagnostics outside the source-ID denominator.

## 4. Automatic merge containment

- [ ] 4.1 Inventory every writer that can merge devices, reassign identifiers,
  or clear ownership, including Ash actions and raw Ecto conflict paths.
- [x] 4.2 Add a shared source-authority preflight that blocks any pair or full
  transitive component with disjoint, non-empty current Armis ID sets for the
  same partition/source instance.
- [ ] 4.3 Apply the preflight to ingest-time convergence, `MergeEngine`,
  `DuplicateSweep`, repair paths, and raw reassignment writers. Persist blocked
  members, ID sets, evidence, initiator, and reason.
- [ ] 4.4 Add concurrency tests proving the preflight and writes share an
  appropriate lock/transaction boundary and cannot pass on stale ID sets.

## 5. Existing-data remediation

- [x] 5.1 Extend the source identity repair dry-run to classify one-current-ID,
  multiple-current-ID, and no-current-ID canonical rows against one activated
  collection and the audit trail.
- [ ] 5.2 Add bounded, idempotent apply actions only for approved safe cases.
  Preserve prior ownership/provenance in an append-only manifest and fail closed
  for every source-alias candidate without independent evidence.
- [x] 5.3 Re-read every changed identifier/device immediately and expose an
  explicit failure result for ownership or count drift.
- [ ] 5.4 After the protected writer is deployed, execute an approved customer batch,
  wait for a new inbound collection, and verify both the collection membership
  and the next northbound per-ID ledger. Do not treat job success or stale
  aggregate counts as verification.

## 6. Operator experience

- [x] 6.1 Replace the Integration Source count cards with the collection-bound
  reconciliation funnel, timestamps, collection ID, accounting availability,
  and separate inbound/northbound/reconciliation statuses.
- [x] 6.2 Add drill-down for nonzero duplicate, withheld, failed, and unattempted
  reason groups with bounded examples and an authorized full export.
- [x] 6.3 Relabel `updated` as `accepted by Armis` and document that HTTP
  acceptance is not a downstream read-after-write verification.

## 7. Tests and verification

- [x] 7.1 Add unit tests for count equations, ID normalization, compatible same-ID
  repeats, conflicting same-ID repeats, and distinct-ID alias candidates.
- [ ] 7.2 Add database tests for immutable collection binding, one disposition
  per source ID, all withholding reasons, stopped batches, idempotent reruns,
  retention, and legacy accounting-unavailable collections.
- [ ] 7.3 Extend the hermetic Armis/DIRE E2E with query-overlap duplicates, two
  distinct IDs sharing hardware evidence, isolated two-device merge attempts,
  transitive components, and exact captured-operation/ledger parity.
- [ ] 7.4 Add UI tests for a fully reconciled run, a transport-successful but
  withheld run, stale/missing collection state, duplicate occurrences, and a
  stopped batch with unattempted IDs.
- [ ] 7.5 Run focused Go and Elixir tests, then the repository Bazel test target.
  Verification must assert persisted per-ID outcomes from a run started after
  the merge-fence rollout, and must include an explicit failing branch for every
  expected equation.
