# Production-time authority admission for late edge data

Status: proposed 2026-11-15. The product owner directed the goal: no record
captured at the edge is left stranded on disk. This design records the
decisions that make that possible. [survey.md](survey.md) lists every
stranding path and its cause.

## Context

Every edge-record authorization decision today asks one question: is this
record's authority current *now*?

- **Agent lane admission.** `RecordSpool.PrepareRecord` builds a policy at
  `time.Now()` and calls `ValidateRecordSigned`. That requires the production
  capability window to contain now and the record's `authority_epoch` to equal
  the active fence.
- **Gateway.** `EdgeRecordAuthorization.authorize_frame` applies the current
  fence. Missing withholds and stale rejects, unless a current delivery grant
  exists.
- **Core delivery grants.** `DeliveryGrants.issue` requires the producer
  assignment to be `:active` now.
- **Core projectors.** `OutputGrants.check_current` requires an active grant at
  the exact current epoch.

The current-time question is right for **new** production: it stops a fenced-out
or lapsed producer from doing new work. It is wrong for data **already
captured** under authority that was valid when it was captured. Such data then
has no admissible path, and the fix cannot be to stop checking. The rule has to
ask a second question: was this record produced under valid authority, verified
from evidence that cannot be forged after the fact?

### What a record already proves

`EdgeRecordV1` already carries everything needed, and its bytes are immutable.
No agent re-signs anything, and no new record field is needed:

| Proof | Carried by |
| --- | --- |
| Signing key | `production_capability.issuer_id` and `issuer_key_id`. Any `source_authorization.capability` names its own. |
| Grant and its version | Production claims: `producer_assignment_id`, `effective_grant_sha256`, `registry_epoch`, `contract_bundle_sha256`, `registry_snapshot_sha256`, cost ceiling. |
| Fence epoch | `producer_context.authority_epoch`, bound by validation to the claims' `authority_epoch`. |
| Producer identity (SVID principal) | `producer_context.origin_principal_id`. The gateway binds it to the authenticated mTLS principal, and the claims bind it to the grant. |
| `produced_at` | The UUIDv7 time in `event_id`. `validateIdentityTime` already requires it to lie inside the signed production window, and inside the source collection window when one is present. |

So a record cannot claim a production time outside a window that core
actually signed for that principal, assignment and epoch. That is the anchor
the late rule builds on.

## Decision 1: one invariant for every edge store

Every durable edge store SHALL have:

1. An **automatic drainer** that runs at process start and keeps retrying. A
   manual one-shot command is not a drainer.
2. A **central terminal disposition** for every item: applied, audit, security
   quarantine or reject-audit. Local bytes are deleted only after a central
   receipt for each item, or after a structural proof that no item exists.
3. **Visibility** until drained: item count, bytes, oldest item age and the
   reason it is not draining.

"Retained and flagged" is acceptable only for bytes the agent cannot parse as
any known layout. Evicting with a count is loss, so it is allowed only where an
explicit, owner-approved byte budget already governs, as with the OTel spool's
`max_bytes`. It is never allowed for records that carry production authority.

## Decision 2: two admission rules, two paths

- **Live admission** is unchanged. New production is admitted by the
  current-time rule into the live lane generation.
- **Late admission** uses the production-time rule (Decision 3). A committed
  record is admitted late when its live admission is no longer possible: a
  legacy layout, or authority that lapsed before admission.

Late records go into a dedicated **late generation** per lane key, stored
under `<root>/late/`, and are sent on their own **late session**. The record's
route profile and traffic class are immutable signed fields, so "the recovery
lane" means a separate generation and session for the same lane key, not a
different route. The late session opens with `EdgeRecordLaneOpen.admission =
LATE`. The gateway applies the late rule only on late sessions and never
accepts a late grant on a live session, so a late record can never pass as
live. The late session has its own credits and runs concurrently below live
priority, so a late tail waiting for grants never blocks live delivery.

Rejected alternatives:

- **Append late records to the live generation.** A record that needs a grant
  caps the session window, so one late record would block live data behind it.
  Live and late records would also share one prefix and could not be told
  apart.
- **Re-sign or re-wrap late records with fresh authority.** That would launder
  old data as new production. The bytes stay immutable.
- **A "trust old records" flag.** That is a bypass. It is forbidden.

## Decision 3: the production-time rule

A late record is admissible only if every check below passes. The checks are
grouped by who can decide them.

**Agent, before appending to the late generation** (`ValidateRecordProduced` in
`go/pkg/edge/edgerecord`):

1. **Structure and body.** Full structural validation, including identity time
   inside the signed windows and the semantic digest, and the contract's typed
   body validator. These are the same validators live admission uses.
2. **Signatures.** Production and source signatures are verified under the
   pinned trust epoch through `CapabilityTrust.ResolveKey`, with the
   capability's own signed window as evidence. That is historical
   verification, not "is the key active now".
   - A `VALID` result proceeds, including for a normally rotated key.
   - `INVALID` is a permanent rejection.
   - `UNAVAILABLE` is retried.
   - `HISTORICALLY_REVOKED` is admitted to the late generation with the
     security outcome already fixed (Decision 6). It is never refused into a
     local dead end.
3. **Time sanity.** `produced_at <= now + clock tolerance`. A record from the
   future is not late; it is refused as not yet valid and retried.
4. **Identity.** The record's origin principal equals the authenticated agent,
   and its network scope is bound to that agent in the trust snapshot.
   Otherwise the record is retried, because the binding may arrive later.
5. **Fence.** An unavailable fence, or an epoch ahead of the known fence, is
   retried. Current and stale fences are both admissible. Only core holds the
   history needed to judge a stale epoch.

The agent does not apply the maximum late age. Core owns that bound
(Decision 5), so a record too old to project still leaves the edge, as audit.

**Core, when issuing the late delivery grant** (`ServiceRadar.Edge.LateAdmission`):

6. **Authority history.** An authority-history interval must exist for
   `(producer_assignment_id, authority_epoch)` (Decision 4). It must bind the
   same agent, network scope and run shard, and satisfy
   `active_from - tolerance <= produced_at < coalesce(active_until, +inf) +
   tolerance`. In other words, the epoch the record names was the live epoch
   of that assignment when the record was produced.
7. **Not compromise-ended.** The interval did not end for a compromise-class
   reason: `certificate_revoked` or an explicit `compromised`.
8. **Age.** `now - produced_at <= late_admission_max_age`.
9. **Contract.** The record's registry epoch is still admitted. This is the
   existing registry rule, and late admission adds no schema bypass.

If all of checks 6 to 9 pass, core issues a grant with **PRIMARY** publication.
If the record verified but any of checks 6 to 9 fails, core issues a grant with
**AUDIT** publication and states the reason: `fenced_at_production`,
`history_unknown`, `compromise_ended`, `beyond_late_window` or
`contract_retired`. Core never refuses a verified record outright. Refusal is
reserved for an item that does not bind to the requesting agent, which is a
permanent rejection of that frame.

The agent cannot fake checks 6 to 8. They read core-owned history and core's
clock, and the record's `produced_at` is already bound inside a window that
core signed.

## Decision 4: core keeps authority history

Assignment and grant rows are current-state rows. `authority_epoch`,
`epoch_changed_at` and `revoked_at` are overwritten, and lifecycle cleanup
deletes rows. The README of `add-edge-spool-recovery-coordinator` already notes
that they are not historical evidence.

Add `platform.edge_authority_history`, an append-only table:

| Column | Meaning |
| --- | --- |
| `assignment_id`, `assignment_kind` | `sweep` or `output_grant`. No foreign key, so deleting the assignment keeps its history. |
| `agent_id`, `network_scope_id`, `run_shard` | The binding during the interval. |
| `authority_epoch` | The epoch of the interval. |
| `active_from`, `active_until` | The interval. `active_until` is NULL while the epoch is current. |
| `ended_reason` | `epoch_changed`, `revoked`, `identity_superseded`, `certificate_revoked`, `deleted`, `reactivated` and so on. |

**Writers.** A database trigger on `sweep_producer_assignments` and
`edge_output_grants` writes the history: on insert, on any change of epoch,
state, agent, scope or shard, and on delete. A trigger catches every writer,
including raw Ecto `on_conflict` upserts that never build an Ash changeset,
which is the lesson recorded in AGENTS.md. The trigger closes the open interval
and opens the next one in the same transaction. `OutputGrants.revoke_agent`
takes the cause (`identity_superseded` or `certificate_revoked`) and records
it, because the two must be told apart. Rows are never updated except to set
`active_until` and `ended_reason` once.

**Seed.** The migration seeds one open interval per existing row:
`active_from = epoch_changed_at` (or `inserted_at`), and `active_until =
revoked_at` when the row is revoked. That is exact for every current epoch.
Earlier epochs have no evidence and are not invented. A record naming one gets
`history_unknown`, which means AUDIT.

**Retention.** Intervals that ended more than `late_admission_max_age` plus the
clock tolerance ago may be pruned in bounded batches. Open intervals are never
pruned.

**Keys.** Historical verification needs the issuer key's evidence (see
"Current permission and historical verification are separate questions").
Retired issuer keys SHALL stay in the trust document with `valid` status for at
least `late_admission_max_age` after their last signed window ends.
Compromised keys stay as `historically_revoked` for good.

## Decision 5: bounds

- **Maximum late age.** `late_admission_max_age_seconds` is a runtime setting
  in `platform.edge_pipeline_settings`, with a code default of 14 days. It is
  not a Helm value. A record older than this is delivered as AUDIT
  (`beyond_late_window`). It is stored and never projected, so the bound limits
  backfill without stranding anything.
- **Replay and duplicates.** Late primary records go through the same
  idempotent `event_ledger`, keyed by `(network_scope_id, event_id)`. The same
  digest is a replay no-op. A different digest is `EVENT_ID_CONFLICT`. This is
  only sound while the ledger still holds an event id that might have been
  applied before, for example a flat-spool record that was sent but whose ACK
  was lost before the upgrade. So `EdgeLedgerRetentionWorker`'s horizon SHALL be
  at least `late_admission_max_age`, and core SHALL treat the effective late
  age as the smaller of the setting and the ledger horizon, so it never projects
  a record whose duplicate could already have been pruned.
- **Volume.** Late sessions get their own credit budget, at most one late
  session per lane key, and lower scheduling priority than live sessions. Late
  grants are issued in bounded batches, using the existing 64-item and 2 MiB
  request bounds.

## Decision 6: revocation and compromise never backfill

- **Compromised issuer key** (`HISTORICALLY_REVOKED`). The record never applies.
  The agent admits it to the late generation, and the gateway publishes it to
  security quarantine without a grant. That path already exists in
  `ValidateFrameSigned` and `authorize_frame`, and it matches the frozen rule
  that this status is "reachable as audit/quarantine evidence; NEVER a
  permanent reject".
- **Compromised agent identity.** A revoked certificate cannot open a session,
  and another principal cannot present the records because origin binding
  fails. Grant intervals ended by `certificate_revoked` resolve to AUDIT for
  every late record, even if the record was produced before the revocation:
  the compromise time is unknown, so the conservative answer is never to
  backfill.
- **Normal rotation and supersession** do not block late admission. Examples
  are a rotated key, an identity superseded by re-enrollment, a reassigned
  target or a new epoch. A record produced while its epoch was live is
  legitimate data.

## Decision 7: late grants and late publication

Add a third delivery transition to `EdgeDeliveryClaimsV1`, so that a late grant
cannot pass as a renewal or rollover:

```proto
message EdgeDeliveryLateAdmissionV1 {
  int64 produced_at_unix_nano = 1;   // == UUIDv7 time of event_id
  uint64 authority_epoch = 2;        // == record producer_context.authority_epoch
  EdgeLatePublication publication = 3; // PRIMARY or AUDIT, decided by core
  EdgeLateDecisionReason reason = 4;   // ADMITTED, FENCED_AT_PRODUCTION, ...
}
```

The claims still bind `event_id`, `record_sha256`, `spool_id` and `sequence`.
The grant is short-lived and signed by the issuer key for the `delivery`
purpose, as renewal grants are.

The gateway accepts such a grant only on a late session. It checks the grant
against the record (event id, digest, `produced_at`, epoch) and publishes it as
follows:

- **PRIMARY** goes to the primary route, with the provenance delivery mode
  `LATE_ADMISSION`.
- **AUDIT** goes to the audit route, with the same mode and the reason.
- **Security quarantine** is the outcome for a compromise-revoked key, as
  today.
- **A frame without a valid late grant** on a late session is withheld (retry).
  It is never rejected for that reason alone.

EventWriter accepts `LATE_ADMISSION` on both routes. Projectors use the grant's
historical decision in place of `OutputGrants.check_current` for a late
primary record. A current-state projector applies a late record only when it is
newer than the stored state, by `produced_at`. Time-series rows append at their
own time. Every late record gets an audit row in the ledger: admission `late`,
`produced_at`, publication, reason, grant issuer key id and receiving gateway.

**In-lane records.** A record already in a live lane whose production
authority lapsed while its fence went stale or missing is not a late
admission. It was admitted on time and is being delivered late. The sender
asks for a late grant for it on its existing coordinate in place of a renewal.
The gateway accepts a late grant on a live session only for a record whose
fence is stale or missing at the gateway, which is exactly the case that
withholds or rejects today. The publication then follows the grant, as above.
This replaces the forever-withhold on a missing fence and the `fence_stale`
dead end.

## Decision 8: upgrade-time handoff

New code cannot reach an already-installed old updater or old agent. So the
new agent cleans up after them on its first start. `OpenRecordSpool` consults
a registry of known legacy layouts. Today that is `flat_v1`, the pre-lane
single spool. For each layout present:

1. **Inspect read-only.** This is `spool.InspectLegacyFlat` from #6652. A
   drained layout is retired as #6652 already does. Unrecognized root entries
   are left untouched and flagged as `unsupported_legacy_storage`, as now. That
   is the only remaining retained state.
2. **Read** committed records above the resolved watermark with the existing
   spool reader, in sequence order. Each committed record is handled in one of
   three ways:
   - **Admissible** under the agent-side late checks: append it to the late
     generation, wait for the append to be durable (fsync), then record a local
     `handed_off` disposition for that sequence in the legacy layout's own
     evidence, through its resolve path.
   - **Permanently invalid** (structure, body, or `INVALID` key): write it to
     the rejection evidence (Decision 9), then resolve it.
   - **Retryable**: stop and retry on the next pass. Never skip a record and
     never reorder.
3. **Retire** the layout with `RetireDrainedLegacyFlat` once every committed
   record is resolved locally. Retirement already requires structural
   emptiness.

**Crash safety.** A crash after the late append but before the local resolve
re-admits the same record on restart. The late generation's attribution binding
recognizes an event id it already holds with the same digest and skips it.
Core's ledger idempotency is the backstop.

**Readiness.** `legacy_storage_handoff_pending`, with a reason and oldest age,
replaces `unsupported_legacy_storage` while records remain. It is not a
not-ready condition for live production.

Draining before the old updater stops the old agent stays out of scope. New
code cannot change installed software. The handoff makes that unnecessary,
because the new agent drains whatever the old one left behind.

## Decision 9: local rejections are delivered, not evicted

The spool's local quarantine stays the immediate landing place for permanent
rejections. Its entries become a drained queue rather than an evicting buffer.
The sender delivers each one as rejection evidence on the late session to the
reject-audit stream, and evicts it only after the central receipt. A full
quarantine pauses admission of new rejections with a count. It never evicts an
undelivered entry.

## Decision 10: other queues

- **OTel add-on relay spool.** When `spool_dir` or the backend changes, the
  add-on drains the old directory to the agent before abandoning it, or adopts
  the old directory's segments into the new one. It never silently orphans
  unacknowledged frames.
- **NVR/VMS media.** The invariant in Decision 1 applies to sealed media. The
  requirements in the `camera-recording` delta say what must hold. The
  implementation belongs with the archive changes already open
  (`add-edge-recording-archive`, `define-nvr-local-copy-registration`,
  `add-longshore-object-storage`). Tasks in phase 4 point there, so that two
  changes do not each build their own drainer. The production-time principle
  carries over directly. A sealed block is judged against the recovery
  generation and archive binding it was sealed under, verified from retained
  generation and binding history. It is not refused because the current
  generation moved. A dispatch with an unknown outcome is reconciled
  automatically by idempotent read-back (no-clobber put, HEAD and ranged
  verify), not left for an operator.

## Threat model

| Threat | Current-time rule | Production-time rule |
| --- | --- | --- |
| Lapsed producer does new work | Refused | Still refused. Live admission is unchanged, and a late record must have `produced_at` inside a signed window. |
| Backdating: a host forges records "produced" in the past | Not possible | The record still needs a production capability that core actually signed for that principal, assignment and epoch, with `produced_at` inside its window. Core checks that the epoch was live at that time. The exposure is bounded by real grant windows, the late age, and AUDIT for anything outside the history. |
| Stolen agent SVID used to backfill | Can inject live data under current grants | It can also inject late data under grants it held, within the late age. Certificate revocation turns every interval of that agent into AUDIT, so it never projects. Live injection was already possible, so the new exposure is time, not authority. |
| Compromised issuer key | Security quarantine | Security quarantine. It never backfills. |
| Replay or duplicate of a delivered record | Ledger idempotency | Ledger idempotency, with retention extended to cover the late window. |
| Fenced-out producer replays old epoch data | Rejected or audit | AUDIT (`fenced_at_production`). It never applies. |
| Agent clock skew | Tolerance | Tolerance. `produced_at` is bounded by the signed window, so skew cannot widen authority. |

## Rollout

1. **Core and gateway** (phase 2): authority history, late grants, late
   sessions, EventWriter and projectors. The gateway advertises
   `late_admission_v1`.
2. **Agents** (phase 1 code may land earlier): agents hand off legacy layouts
   into the late generation at once. They open late sessions only when the
   gateway advertises the capability, and until then report
   `late_pending_gateway_support` with counts.
3. **Phases 3 and 4** follow without changing the wire again.

Runtime settings have code defaults. There are no Helm-only knobs and no bypass
switch. Mixed versions fail closed. An old gateway never sees a late session.
An old agent never asks for late grants, and its records follow today's paths.

## Open questions for the product owner

1. The default `late_admission_max_age`: 14 days is proposed. It sizes the
   event-ledger retention, so a longer window costs ledger rows on every
   deployment. A SaaS tenant upgrading from 1.4.82 after a longer gap would get
   older tail records as AUDIT rather than projected.
2. Should a late PRIMARY record of a current-state contract apply when it is
   older than the stored state, or only as history? The proposal is history
   only, by `produced_at`.
