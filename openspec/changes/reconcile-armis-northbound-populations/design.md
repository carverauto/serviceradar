## Context

The current counters describe different universes. `SyncIngestorQueue` records
the inbound source count by querying distinct active canonical device UIDs after
ingestion. `ArmisNorthboundRunner` loads safe typed-ID candidates, collapses by
Armis ID, and adds the number of withholding conflict *rows* to its denominator.
The run is not linked to the Armis collection that produced either population.

The 2026-09-01 customer investigation makes the distortion concrete:

- the Integration Source displayed 22,308 inbound devices;
- northbound considered 17,772, accepted 14,431, and skipped 3,341;
- 3,295 skipped canonical rows owned 10,699 typed Armis identifiers;
- 2,390 of those rows had exactly one ID refreshed by the latest sync and stale
  extras, while 541 had multiple refreshed IDs and 364 had none refreshed;
- 46 additional rows had metadata/typed-identifier disagreement; and
- duplicate reconciliation had merged identifiers into many of the affected
  survivors without a source-ID preflight.

ServiceRadar already has the right basis for a collection-consistent answer:
`device_source_snapshots` activates one complete collection for a source
instance, and `device_source_observations` records each source object in that
collection and its resolved canonical UID. The proposal extends this contract
instead of creating a second inbound inventory system.

## Goals

- Account for every raw Armis row and every distinct Armis source ID in one
  completed collection.
- Make the desired parity precise: every distinct valid Armis ID has exactly
  one northbound disposition, even when raw import and update counts differ.
- Prevent automatic identity reconciliation from manufacturing additional
  multi-Armis-ID canonical devices.
- Distinguish source API repetition from distinct source objects that may be
  duplicates of one physical asset.
- Repair current identity drift without deleting provenance or allowing the
  bad-data writer to recreate it.
- Give operators a reproducible, collection-bound explanation for every gap.

## Non-Goals

- Promise that raw Armis rows always equal northbound updates.
- Infer that two distinct Armis IDs are the same source object from shared IP,
  MAC, hostname, or a prior ServiceRadar merge alone.
- Automatically update all IDs on an ambiguous multi-ID canonical row.
- Verify that Armis committed each property after a successful bulk HTTP
  response; `accepted` means the Armis bulk endpoint accepted the operation.
- Replace the general DIRE identity model or the existing Armis mega-device
  disposition proposal.
- Mutate production data as part of proposal authoring.

## Decisions

### The accounting unit is a completed Armis collection

A northbound run selects the newest successfully activated collection for the
same partition, source type, and integration source instance. It persists the
collection ID, content hash, observed time, and activation time on the run.
Incomplete, rejected, stale, or in-progress collections never become a
northbound basis.

The collection producer and activation path preserve these counts:

- `raw_rows`: all records returned across all configured queries/pages;
- `excluded_rows`: returned rows intentionally excluded by configured network policy;
- `invalid_rows`: rows that cannot yield a bounded normalized Armis ID;
- `valid_occurrences`: raw rows with a valid normalized Armis ID;
- `distinct_source_ids`: unique normalized Armis IDs;
- `duplicate_occurrences`: valid occurrences beyond the first occurrence of
  each normalized ID; and
- `conflicting_duplicate_ids`: distinct IDs whose repeated payloads disagree
  on identity-critical source fields.

The activation metadata must satisfy:

```text
raw_rows = excluded_rows + invalid_rows + valid_occurrences
valid_occurrences = distinct_source_ids + duplicate_occurrences
```

The existing snapshot `device_count` becomes the explicitly labelled
`distinct_source_ids`, not an accumulated canonical inventory count. Legacy
sources that do not yet publish these fields remain displayable as
`accounting_unavailable`; their inferred values are never presented as exact.

### One immutable disposition is recorded per distinct source ID

At run start, the runner reads source observations whose `collection_id` equals
the bound snapshot collection. It materializes a bounded run-target row for
each distinct source ID before sending any batch. Each row records the source
ID, collection ID, resolved canonical UID when present, disposition, reason,
and final outbound outcome. The record is an audit snapshot; later identity
merges or source collections do not rewrite it.

The top-level source-ID accounting is:

```text
distinct_source_ids = eligible_ids + withheld_ids
eligible_ids = accepted_ids + failed_ids + unattempted_ids
```

`withheld_ids` is grouped by mutually exclusive reasons such as unresolved
canonical identity, deleted canonical device, missing availability, metadata
disagreement, multiple current source IDs without approved alias evidence,
conflicting duplicate payload, or source-linkage mismatch. Diagnostics that do
not withhold an ID are reported separately and never added to the denominator.

The existing `updated_count` remains available for compatibility, but its UI
label and contract become `accepted_count`. A 2xx response increments accepted
IDs for that batch. A rejected/failed batch increments failed IDs. If execution
halts, every later eligible ID is finalized as unattempted rather than silently
disappearing from the equation.

### Duplicate records and duplicate assets are different

Repeated API rows with the same normalized Armis ID are transport/query
duplicates. Compatible repeats collapse to one source observation and increase
`duplicate_occurrences`; they do not become northbound skips. If repeated
payloads disagree on identity-critical fields, the source ID is retained in
the collection but withheld as `conflicting_duplicate_payload` until reviewed.

Two distinct Armis IDs that share MAC, IP, serial number, hostname, or a
canonical ServiceRadar UID are only `source_alias_candidates`. This is a report,
not proof. Shared IP is especially unsafe in a DHCP-heavy estate, and a shared
canonical UID may itself be the result of the over-merge being repaired.

The first implementation does not fan out an availability value across such
IDs automatically. A future or configured alias relationship may make multiple
distinct IDs eligible only when it carries independent source-side evidence or
an explicit operator approval with audit history. Alias membership remains a
source-integration relation; it does not authorize merging the source IDs into
one authoritative device identifier.

### Automatic merges have a source-authority fence

Before any automatic merge or identifier reassignment, the operation loads the
source-authoritative ID sets for every member under the same partition and
source instance. If two members have disjoint, non-empty current Armis ID sets,
the operation fails closed. For a transitive duplicate component, the preflight
examines the entire component before the first write, not only each selected
pair.

Blocked operations persist the proposed members, source-ID sets, evidence,
initiator, and reason. This applies to scheduled duplicate sweep, ingest-time
convergence, merge engine callers, and raw conflict/reassignment paths. A prior
merge, common MAC/IP evidence, or an unreviewed alias candidate does not bypass
the fence.

This fence complements the post-v1.4.50 transitive-component limits on staging:
component-size protection reduces blast radius, while the source-authority
fence protects even an isolated two-device merge.

### Remediation closes the writer before changing data

The current 3,295 multi-ID rows are classified against a newly completed,
collection-consistent Armis snapshot and the merge/identifier audit trail:

- exactly one current source ID plus stale extras: propose separation or stale
  identifier retirement only after the extras are absent from completed
  collections for the configured grace rule;
- multiple current source IDs: retain as unresolved alias/over-merge candidates
  until independent evidence selects a safe split or approved alias relation;
- no current source IDs: classify as historical/stale identity and require
  explicit disposition; and
- metadata disagreement with one current typed ID: eligible for the existing
  audited metadata repair.

The tool is dry-run by default, idempotent, bounded, and manifest-audited. Apply
mode requires the source-authority fence and duplicate-sweep containment to be
deployed first. Every mutation is re-read immediately, then checked again after
a fresh inbound collection and a subsequent northbound run. A job success log
without artifact-level count and ownership checks is not verification.

### The UI shows a funnel, not three incomparable totals

Integration details shows the selected collection and the equations as a
funnel:

```text
raw rows
  -> policy-excluded rows + invalid rows + valid occurrences
  -> duplicate occurrences + distinct source IDs
  -> withheld IDs + eligible IDs
  -> accepted + failed + unattempted IDs
```

Operators can open each nonzero reason group and inspect bounded examples or
export the full run disposition. Inbound transport status, snapshot accounting
status, northbound transport status, and reconciliation status are separate.
A run may be transport-successful but population-degraded; it is not labelled
fully reconciled while withheld, failed, unattempted, stale-snapshot, or
accounting-unavailable populations remain.

## Risks / Trade-Offs

- Per-ID run dispositions add rows proportional to each northbound run. Use
  bounded retention for successful detail rows while retaining aggregate run
  summaries and all conflict/repair audit evidence under the existing audit
  retention contract.
- Existing source snapshots may not carry exact raw/duplicate statistics.
  Those collections will show `accounting_unavailable` until a new producer and
  activation path complete successfully.
- A fail-closed alias policy can initially keep legitimate Armis duplicates
  withheld. That is safer than writing to unrelated Armis objects, and the
  source-alias candidate report provides the evidence needed to decide whether
  an approved fan-out contract is warranted.
- Binding northbound to a completed collection makes stale or missing snapshot
  state visible and can temporarily block runs that previously queried live
  inventory. Manual override, if provided, must be explicit, audited, and may
  not claim reconciled parity.
- Remediation may reduce canonical device counts or identifier cardinality, but
  those changes are not assumed to improve parity until a fresh collection and
  outbound run prove the equations.

## Migration Plan

1. Extend the Armis collection producer and source snapshot metadata with exact
   raw, invalid, distinct, and duplicate counts; activate a fresh collection in
   dry-run/test environments and prove its equations.
2. Add the collection reference and population fields to integration update
   runs, plus the immutable per-source-ID disposition resource and retention
   policy.
3. Change candidate selection to start from the bound collection's source
   observations and finalize one disposition for every distinct source ID.
4. Add the source-authority preflight to every automatic merge/reassignment
   writer and deploy it before any repair.
5. Add the reconciliation funnel and run-detail reason views.
6. Run the hermetic Armis/DIRE scenarios for repeated rows, alias candidates,
   merge fences, stopped batches, and exact equations.
7. In production, capture a fresh snapshot and run remediation dry-run. Review all
   multiple-current-ID and alias candidates before approving any mutation.
8. Apply approved repairs in bounded batches, re-query ownership immediately,
   wait for a post-rollout inbound collection, run northbound, and require the
   artifact-level equations to pass.

## Open Questions

- Does the customer Armis API actually return the same normalized ID more than once
  across configured queries/pages, and do any repeats disagree on
  identity-critical fields?
- Does Armis expose an authoritative alias/duplicate relationship for distinct
  device IDs, or must any fan-out relationship remain operator-approved?
- Which snapshot metadata fields are identity-critical for detecting a
  conflicting repeat without treating harmless descriptive drift as a block?
- What retention window balances per-ID forensic history with the roughly
  hourly 15k-25k-row run volume?
