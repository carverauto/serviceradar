# Production-time authority admission for late edge data

Status: proposed 2026-11-15. The product owner directed the goal: no record
captured at the edge is left stranded on disk. This design records the
decisions that make that possible, including the owner's answers of
2026-11-15 (see "Owner decisions"). [survey.md](survey.md) lists every
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
| Producer identity (SVID principal) | `producer_context.origin_principal_id`. The claims bind it to the grant. The gateway binds it to the authenticated mTLS principal; a mismatch no longer resolves as `identity_conflict`: on a late session the frame goes to security quarantine with both principals recorded, before the identity rejection and any grant check, and on a live session whose lane open advertised `late_admission_protocol_version >= 1` it resolves as `LATE_ADMISSION_REQUIRED` so the agent holds the bytes first (Decision 7). |
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
  legacy layout, authority that lapsed before admission, or a live-lane record
  the gateway resolved as `LATE_ADMISSION_REQUIRED` because its fence is stale
  or missing, on a session whose lane open advertised the late-admission
  protocol (Decision 7).

Late records go into a dedicated **late generation** per lane key, stored
under `<root>/late/`, and are sent on their own **late session**. A spool
generation's identity is frozen to one `(network scope, origin principal)`: a
late record from another scope rotates to a new generation of the same lane
key, and the agent opens one late session per generation, in turn. So every
late session carries a single network scope, which the gateway's
one-scope-per-pipeline-lane invariant requires (owner decision 2026-11-17);
"at most one late session per lane key" holds because the agent drains those
generations serially. The record's
route profile and traffic class are immutable signed fields, so "the recovery
lane" means a separate generation and session for the same lane key, not a
different route. The late session opens with `EdgeRecordLaneOpen.late_admission =
true`, a bool rather than an enum: the frozen enum-policy guards refuse an enum's
zero member, which every older agent's lane open would carry. When the gateway's
Hello advertised late admission, every lane open, live and late, carries
`late_admission_protocol_version = 1`, and `late_admission = true` is set only on
the late session. When Hello did not advertise it, neither field is set, because
an older gateway rejects unknown lane-open fields. The gateway applies the late rule only on late sessions and never
accepts a late grant on a live session, so a late record can never pass as
live. The late session has its own credits and runs concurrently below live
priority, so a late tail waiting for grants never blocks live delivery.

A record whose origin principal is not the authenticated agent goes into a
**per-principal hold**: a separate late generation keyed by `(lane key, origin
principal)`, under `<root>/late/hold/<origin principal hex>/<lane>/<generation>`;
the agent's own late generations live under `<root>/late/own/<lane>/<generation>`. Hold
generations share their lane key's single late session, so the route profile
and traffic class still match. Hold frames, and frames whose key is
`HISTORICALLY_REVOKED`, are sent without waiting for a grant; the gateway
resolves them to security quarantine (Decision 6) before it would withhold a
frame for a missing grant. They therefore never stall the host's own late
records, and the hold never blocks the in-order handoff of the host's own
records.

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
   - `UNAVAILABLE` is retried. It clears with connectivity, and it is one of
     only two outcomes that stop the ordered legacy handoff.
   - `HISTORICALLY_REVOKED` is admitted to the late generation with the
     security outcome already fixed (Decision 6). It is never refused into a
     local dead end.
3. **Time.** The agent does not judge `produced_at` against its own clock. A
   record whose `produced_at` is later than the local clock plus tolerance is
   still appended to the late generation; core judges it with its own clock
   and withholds the grant until core's clock passes `produced_at` minus the
   tolerance. The record waits in the late generation without blocking the
   legacy handoff.
4. **Identity.** A trust snapshot must be loaded; until it is, the record is
   retried. That is the other outcome that stops the ordered handoff. The record's origin principal must equal the authenticated agent.
   A different origin principal (a revoked or superseded predecessor on the
   same host) is not retryable: the record is appended to the per-principal
   hold for `(lane key, origin principal)` and is delivered for security
   quarantine only. Once the snapshot is loaded, an absent scope binding is
   admissible: core decides from retained history, or `history_unknown`.
5. **Fence.** With a loaded snapshot, a current fence, a stale fence, an
   absent fence entry (for example, a deleted assignment) and an epoch ahead
   of the known fence are all admissible. Only core holds the history needed
   to judge them; an epoch core has no interval for gets AUDIT
   (`history_unknown`).

The agent does not apply the maximum late age. Core owns that bound
(Decision 5), so a record too old to project still leaves the edge, as audit.

**Core, when issuing the late delivery grant** (`ServiceRadar.Edge.LateAdmission`):

6. **Authority history.** An authority-history interval must exist for
   `(producer_assignment_id, authority_epoch)` (Decision 4). It must bind the
   same agent, network scope and run shard, and satisfy
   `active_from - tolerance <= produced_at < coalesce(active_until, +inf) +
   tolerance`. In other words, the epoch the record names was the live epoch
   of that assignment when the record was produced.
7. **Not compromise-ended.** The interval did not end for an explicit
   `compromised` reason. A record naming an interval that ended with
   `certificate_revoked` or `revoked_cause_unknown` is not judged by checks 6 to 9 at all: whoever
   presents it, including the same principal on a new certificate or after
   re-enrollment, core issues no grant and returns the refusal
   `certificate_revoked_interval`, and the gateway publishes the frame to
   security quarantine (Decision 6).
8. **Age and ledger coverage.** `now - produced_at <=
   late_admission_max_age`, and `produced_at >= ledger_complete_since + clock
   tolerance` (Decision 5).
9. **Contract.** The record's registry epoch is still admitted. This is the
   existing registry rule, and late admission adds no schema bypass.

If all of checks 6 to 9 pass, core issues a grant with **PRIMARY** publication.
If the record verified but any of checks 6 to 9 fails, core issues a grant with
**AUDIT** publication and states the reason: `fenced_at_production`,
`history_unknown`, `compromise_ended`, `beyond_late_window`, `ledger_pruned`
or `contract_retired`. Core never refuses a verified record outright. Core
issues no grant only for an item that does not bind to the requesting agent,
such as a foreign origin principal (`not_assignment_owner`), and for a record
naming a `certificate_revoked` or `revoked_cause_unknown` interval
(`certificate_revoked_interval`). Neither frame is rejected: the gateway
publishes it to security quarantine without a grant, before the missing-grant
withhold, so it never waits. The gateway does not remember RPC refusals: it
recognizes a foreign origin from the frame and authenticated identity, and a
revoked interval from the terminal-interval list in its trust snapshot
(Decision 4). A record whose `produced_at` is still in core's future is
different: core answers "not yet" and issues no grant. A future `produced_at`
is not itself a reason to reject or quarantine, and it does not suppress the
three quarantine classes (a terminal interval in the snapshot, a foreign
origin, a `HISTORICALLY_REVOKED` key), which still apply first. Otherwise the
frame is withheld as retryable and waits in the late generation until core's
clock passes `produced_at` minus the tolerance, and is then judged normally.

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
which is the lesson recorded in AGENTS.md. An insert opens an interval. An
update of epoch, state, agent, scope or shard closes the open interval and
opens the next one in the same transaction. A delete only closes the open
interval with `ended_reason = deleted` and never opens a successor, so a
record produced after the delete falls outside every window and gets AUDIT
(`fenced_at_production`). `OutputGrants.revoke_agent`
takes the cause (`identity_superseded` or `certificate_revoked`) and records
it, because the two must be told apart. Rows are never updated except to set
`active_until` and `ended_reason` once.

**Seed.** The migration seeds one open interval per existing row:
`active_from = epoch_changed_at` (or `inserted_at`), and `active_until =
revoked_at` when the row is revoked. An already-revoked output grant is
seeded with `ended_reason = revoked_cause_unknown`, because the grant row does
not record whether the cause was certificate revocation or supersession; it is
handled exactly like `certificate_revoked` (security quarantine, no grant,
never pruned), so the cutover never backfills. An already-revoked sweep
assignment keeps its normal reason and stays PRIMARY-eligible for records
produced within its window. That is exact for every current epoch.
Earlier epochs have no evidence and are not invented. A record naming one gets
`history_unknown`, which means AUDIT.

**Retention.** Intervals that ended more than `late_admission_max_age` plus the
clock tolerance ago may be pruned in bounded batches. Open intervals, and
intervals that ended with `certificate_revoked` or `revoked_cause_unknown`, are never pruned,
so their records stay quarantine-only; no separate tombstone table is needed.
A pruned `compromised` interval collapses to `history_unknown`, which stays
AUDIT. A record naming a pruned interval gets `history_unknown`, so raising the
setting later never invents history.

**Terminal intervals in the trust document.** Core's trust document carries,
separately from the current fences, the identity of every interval that ended
with `certificate_revoked` or `revoked_cause_unknown`: `(producer_assignment_id, network_scope_id,
run_shard, authority_epoch)`. The gateway's `EdgeRecordTrust` snapshot and the
Go `TrustSnapshot` parse this list. Frame authorization stays stateless
(frame, lane, identity, snapshot): a record whose `(assignment, epoch)` is in
the list goes to security quarantine, before the missing-grant withhold and
regardless of any already-issued grant. A higher current fence alone never
quarantines; a normal epoch advance stays PRIMARY-eligible through its late
grant. These intervals are never pruned, so the list is complete.

**Bounding the terminal-interval list.** Pruning cannot bound it. Nothing
bounds how old a late record may be and still leave the edge: the agent does
not apply the maximum late age, and its spool never evicts an unresolved
record by age, so a record too old for PRIMARY is still delivered, as AUDIT
(Decision 3). `late_admission_max_age` bounds PRIMARY, not admission. A
terminal interval can therefore match an admissible record of any age, and
pruning it would turn that record's outcome from security quarantine into
`history_unknown` AUDIT. That is a quiet downgrade of exactly the case this
list exists for. The list is instead bounded by its own cap, and fails
closed past it exactly as the assignment cap does: the gateway's document
lists at most 100,000 terminal intervals and is refused
(`trust_snapshot_too_large`) beyond that. An agent's own document lists only
that agent's terminal intervals, under the 10,000 assignment cap that Go's
`maxTrustFences` already enforces. Terminal intervals come only from
certificate revocations, which are operator events, so the cap is orders of
magnitude above realistic use (each entry is about 120 bytes of JSON, so the
cap is about 12 MB). A partial index over terminal rows keeps both reads off
the rest of the history.

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
  at least `late_admission_max_age`.
- **Ledger coverage.** Core persists `ledger_complete_since`, a monotonic
  timestamp: every ledger row with `inserted_at` at or after it is still
  retained. The migration seeds it with the retention cutoff already in force
  (the migration time minus the `EdgeLedgerRetentionWorker` retention horizon
  in force then), because rows older than that may already be gone. That
  horizon is at least the output-grant lifetime, so the upgrade tail stays
  PRIMARY-eligible. It advances only when pruning deletes rows, to that batch's `inserted_at`
  cutoff, and it never moves backward. Retention prunes by `inserted_at` while
  the check uses `produced_at`, and a producer's clock may run ahead of core's
  by up to the clock tolerance, so a row's `inserted_at` is at least
  `produced_at - tolerance`. Late PRIMARY therefore requires `produced_at >=
  ledger_complete_since + clock tolerance`, which guarantees any earlier
  application of the record is still in the ledger; an older record gets AUDIT
  (`ledger_pruned`). Raising `late_admission_max_age_seconds` is therefore
  safe: rows pruned before or after the migration keep their records on AUDIT,
  and no duplicate is ever projected.
- **Volume.** Late sessions get their own credit budget, at most one late
  session per lane key (which also drains that lane key's per-principal
  holds), and lower scheduling priority than live sessions. Late
  grants are issued in bounded batches, using the existing 64-item and 2 MiB
  request bounds.

## Decision 6: revocation and compromise never backfill

- **Compromised issuer key** (`HISTORICALLY_REVOKED`). The record never applies.
  The agent admits it to the late generation and sends it without waiting for
  a grant, and the gateway publishes it to security quarantine without a
  grant. That path already exists in
  `ValidateFrameSigned` and `authorize_frame`, and it matches the frozen rule
  that this status is "reachable as audit/quarantine evidence; NEVER a
  permanent reject".
- **Revoked certificate.** Every late record naming an authority interval
  that ended with `certificate_revoked` or `revoked_cause_unknown` (the seeded label for an
  output grant already revoked at cutover) goes to security quarantine only,
  whoever presents it. When revocation denylisted the principal, the host's
  currently authenticated agent presents the records from the per-principal
  hold (Decision 2). When the revocation left the principal able to
  authenticate (for example an operator-request revocation followed by a new
  certificate or re-enrollment), the same principal presents them from its own
  late generation. Either way core issues no grant and returns
  `certificate_revoked_interval`, and the gateway publishes the frame to
  security quarantine, after signature verification, before the missing-grant
  withhold. It is never projected and never PRIMARY or AUDIT-applied, and the
  quarantine row records both the origin principal and the presenting
  principal. This holds even for a record produced before the revocation: the
  compromise time is unknown, so the conservative answer is never to
  backfill.
- **Explicitly compromised interval.** An interval ended for an explicit
  `compromised` reason, whose principal still authenticates and presents its
  own records, resolves to AUDIT (`compromise_ended`) for every late record
  that names it.
- **Superseded identity.** Records whose origin principal was superseded by
  re-enrollment are foreign to the new principal, so they follow the same
  per-principal hold and security quarantine. No principal ever obtains PRIMARY
  or AUDIT publication for another principal's records.
- **Normal rotation** does not block late admission. Examples are a rotated
  key, a reassigned target or a new epoch. A record its own principal produced
  while its epoch was live is legitimate data.

## Decision 7: late grants and late publication

Add a third delivery transition to `EdgeDeliveryClaimsV1`, so that a late grant
cannot pass as a renewal or rollover:

```proto
message EdgeDeliveryLateAdmissionV1 {
  int64 produced_at_unix_nano = 1;   // == UUIDv7 time of event_id
  uint64 authority_epoch = 2;        // == record producer_context.authority_epoch
  EdgeLatePublication publication = 3; // PRIMARY or AUDIT, decided by core
  EdgeLateDecisionReason reason = 4;   // see below
}

enum EdgeLateDecisionReason {
  EDGE_LATE_DECISION_REASON_UNSPECIFIED = 0;
  EDGE_LATE_DECISION_REASON_ADMITTED = 1;
  EDGE_LATE_DECISION_REASON_FENCED_AT_PRODUCTION = 2;
  EDGE_LATE_DECISION_REASON_HISTORY_UNKNOWN = 3;
  EDGE_LATE_DECISION_REASON_COMPROMISE_ENDED = 4;
  EDGE_LATE_DECISION_REASON_BEYOND_LATE_WINDOW = 5;
  EDGE_LATE_DECISION_REASON_CONTRACT_RETIRED = 6;
  EDGE_LATE_DECISION_REASON_LEDGER_PRUNED = 7;
}
```

Phase 1 shipped `CONTRACT_RETIRED = 6`, so `LEDGER_PRUNED` takes 7: the
numbering follows the proto wire-compatibility gate, which forbids renaming a
released enum value.

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
  today, for every frame whose origin principal is not the authenticated
  agent, whatever grant it carries, and for every frame whose `(assignment,
  epoch)` is in the trust snapshot's terminal-interval list (Decision 4). The
  origin mismatch is decided before the identity rejection, and all three
  before any grant check, so these frames never wait for a grant. Because the
  terminal-interval check runs at frame authorization regardless of grant, a
  PRIMARY or AUDIT grant issued before the revocation loses once the snapshot
  carries the interval, and the frame goes to security quarantine. A higher
  current fence alone never quarantines.
- **A frame without a valid late grant** on a late session, other than those
  above, is withheld (retry). It is never rejected for that reason alone. A
  record whose `produced_at` is in core's future is one such frame.

EventWriter accepts `LATE_ADMISSION` on both routes. Projectors use the grant's
historical decision in place of `OutputGrants.check_current` for a late
primary record. A current-state projector applies a late record only when it is
newer than the stored state, by `produced_at`. Time-series rows append at their
own time. Every late record gets an audit row in the ledger: admission `late`,
`produced_at`, publication, reason, grant issuer key id and receiving gateway.

**In-lane records.** A record already in a live lane whose fence is stale or
missing at the gateway cannot be delivered live, whatever its production
window (expired or still current), and the live lane never waits on a late
grant. On a live session whose `EdgeRecordLaneOpen` carried
`late_admission_protocol_version >= 1`, the gateway resolves that live
slot immediately with a `REJECTED_PERMANENT` disposition carrying rejection
code `LATE_ADMISSION_REQUIRED`; the kind alone resolves the slot, as for every
permanent rejection, and the capable agent does not copy the record into the
evicting local quarantine. On the same sessions the gateway resolves a live
frame whose origin principal is not the authenticated agent the same way, in
place of `identity_conflict`, and a live frame whose network scope is no longer
bound to the agent (`scope_unbound` / `scope_not_bound`) the same way: deleting
an assignment removes its scope binding together with its fence, and the scope
check runs before the fence check, so without this its in-lane records would
be withheld forever (owner decision 2026-11-17). Exactly these cases resolve
`LATE_ADMISSION_REQUIRED`: a stale fence with no grant, a missing fence with no
grant or with a renewal grant, an unbound scope, and a foreign origin. The
grant-backed audit paths stay as they are (a stale fence with a delivery grant
is `LATE_FENCED_DELIVERY` audit; a missing fence with a recovery rollover is
audit), and a fence the gateway has not learned yet (an epoch ahead of it) is
still withheld. `LATE_ADMISSION_REQUIRED` neither withholds the
frame nor sends it to the `fence_stale` quarantine.

**Registry epochs and routing on a late session.** Whether a late record's
registry epoch is still admitted is core's check 9, and core issues PRIMARY
only for an admitted epoch. So on a late session the gateway does not reject a
frame for a retired or installation-static registry epoch. Every AUDIT frame,
whatever its reason, and every security-quarantine frame on a late session is
routed from the lane: the session's route profile and traffic class,
partitioned by network scope (`network_scope_v1`). Core reports only the first
failing check, and history, age and ledger precede the contract check, so a
retired-epoch record can carry any AUDIT reason, not only `contract_retired`.
Neither an audit nor a quarantined record is ever projected, so neither needs
an installed registry entry; a foreign-origin record would also fail the
registry's session-principal check before it could reach quarantine. Only a
PRIMARY late publication is admitted through the registry, exactly as live
records are (owner decision 2026-11-17).

**Recovery coverage on a late session.** Before publishing, the gateway checks
that no recovery operation has fenced or already applied the session's spool.
On a live session that lookup is authorized by the agent's current scope
binding. On a late session it is authorized by the record's signed scope
instead: the gateway has already verified the production capability, which
binds exactly this agent principal to that network scope, so the agent owned
the scope when it produced the record. The current binding is not required,
because deleting an assignment removes it and the record must still drain. The
check itself stays; only its authorization changes, and only on late sessions
(owner decision 2026-11-17). For an older agent, whose
lane open carries no version (absent or 0), the gateway keeps today's live
dispositions unchanged: a missing fence is still withheld, a stale fence is
still `fence_stale`, and an origin mismatch is still `identity_conflict`.
Before the capable agent persists the resolution (resolved prefix or reclaim), it appends the
exact record bytes to the late generation for that lane key, or, when the
record's origin principal is not the authenticated agent, to the hold for
`(lane key, origin principal)`, exactly as the handoff does, and waits for the
append to be durable. If the append fails, the resolution is not persisted and
the record stays in the live lane for retry. The late session and core's
authority history then decide the record. The gateway never accepts a late
grant on a live session. For sessions whose lane open carried
`late_admission_protocol_version >= 1`, this replaces the forever-withhold on a
missing fence and the `fence_stale` dead end.

## Decision 8: upgrade-time handoff

New code cannot reach an already-installed old updater or old agent. So the
new agent cleans up after them on its first start. `OpenRecordSpool` consults
a registry of known legacy layouts. Today that is `flat_v1`, the pre-lane
single spool. For each layout present:

1. **Inspect read-only.** This is `spool.InspectLegacyFlat` from #6652. A
   drained layout is retired as #6652 already does. Unrecognized root entries
   are left untouched and flagged as `unsupported_legacy_storage`, as now. That
   is the only remaining retained state.
2. **Check capacity.** Before appending anything, the pass compares free
   ordinary capacity with a conservative bound: one append charge plus one
   generation charge for every record still to be appended. If free capacity
   does not cover it, the pass copies nothing, reports `insufficient_capacity`
   with `capacity_needed_bytes`, and resumes on its own once the spool budget
   covers the need. Releasing a resolved prefix while unresolved records remain
   (partial-prefix reclaim) is deferred to its own change.
3. **Read** committed records above the resolved watermark with the existing
   spool reader, in sequence order. Each committed record is handled in one of
   these ways:
   - **Admissible** under the agent-side late checks: append it to the late
     generation, wait for the append to be durable (fsync), then record a local
     `handed_off` disposition for that sequence in the legacy layout's own
     evidence, through its resolve path.
   - **Foreign origin principal**: append it to the per-principal hold for
     `(lane key, origin principal)`, wait for the append to be durable, then resolve it. The
     pass continues with the host's own records.
   - **Permanently invalid** (structure, body, or `INVALID` key): write it to
     the rejection evidence (Decision 9), then resolve it. An evidence write
     that is paused or refused, for example because the quarantine is at its
     bound, is retryable: the legacy record stays unresolved until the evidence
     write succeeds.
   - **Retryable** (only an unloaded trust snapshot or an `UNAVAILABLE` key
     lookup, both of which clear with connectivity): stop and retry on the
     next pass. Never skip a record and never reorder. A fence ahead of the
     known fence, or a `produced_at` ahead of the local clock, is not
     retryable: the record is admissible and core judges it.
4. **Retire** the layout with `RetireDrainedLegacyFlat` once every committed
   record is resolved locally. Retirement already requires structural
   emptiness.

**Crash safety.** A crash after the late append but before the local resolve
re-admits the same record on restart. The late generation's attribution binding
recognizes an event id it already holds with the same digest and skips it.
Core's ledger idempotency is the backstop.

**Readiness.** `legacy_storage_handoff_pending`, with a reason and oldest age,
replaces `unsupported_legacy_storage` while records remain. The status fields
`legacy_handoff_pending_records` and `legacy_handoff_reason` carry that
condition; they do not replace its name. `unsupported_legacy_storage` stays only
for entries the handoff cannot account for. It is not a not-ready condition for
live production.

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
  generation moved. A seal with no retained history, or one ended for a
  compromise-class reason, is never published for playback (approved by the
  owner). The drainer's terminal depends on the mode. With an archive
  destination configured, only a verified archive receipt or a verified
  quarantine-destination receipt ends it, never a local publication or a
  local-archive quarantine placement; a bad
  seal goes to the quarantine destination, and its verified receipt permits
  local deletion. In local-only mode (no archive destination configured),
  publishing the block into the qualified durable local archive with its
  central index receipt persisted is terminal, and local deletion then follows
  the retention and hold policy; a bad seal is placed in a quarantine
  partition or flag of that same archive, and that placement is terminal, and
  permits removing the recorder spool copy, only once its central index
  receipt is persisted. The quarantined block is retained, counted and
  reported, never indexed for playback and never auto-deleted. No new store is introduced. A dispatch with an unknown
  outcome is reconciled automatically by idempotent read-back (no-clobber put,
  HEAD and ranged verify), not left for an operator.

## Threat model

| Threat | Current-time rule | Production-time rule |
| --- | --- | --- |
| Lapsed producer does new work | Refused | Still refused. Live admission is unchanged, and a late record must have `produced_at` inside a signed window. |
| Backdating: a host forges records "produced" in the past | Not possible | The record still needs a production capability that core actually signed for that principal, assignment and epoch, with `produced_at` inside its window. Core checks that the epoch was live at that time. The exposure is bounded by real grant windows, the late age, and AUDIT for anything outside the history. |
| Stolen agent SVID used to backfill | Can inject live data under current grants | It can also inject late data under grants it held, within the late age. After certificate revocation, every record naming an interval that ended `certificate_revoked` (or `revoked_cause_unknown` at cutover) reaches security quarantine only, whoever presents it, including the same principal on a new certificate; core issues no grant and they never project or AUDIT-apply. Live injection was already possible, so the new exposure is time, not authority. |
| An agent presents another principal's records | Rejected (origin binding) | Security quarantine only, with both principals recorded. The records must still verify, never project, and are bounded by late-session credits. The exposure is quarantine volume, not authority. |
| Compromised issuer key | Security quarantine | Security quarantine. It never backfills. |
| Replay or duplicate of a delivered record | Ledger idempotency | Ledger idempotency, with retention extended to cover the late window. A record produced before `ledger_complete_since` plus the clock tolerance is AUDIT (`ledger_pruned`), so raising the late age never projects a duplicate. |
| Fenced-out producer replays old epoch data | Rejected or audit | AUDIT (`fenced_at_production`). It never applies. |
| Agent clock skew | Tolerance | Tolerance. `produced_at` is bounded by the signed window, so skew cannot widen authority. |

## Rollout

1. **Phase 1, edge (Go).** `EdgeRecordLaneOpen` gains `uint32
   late_admission_protocol_version`; when the gateway's Hello advertised late
   admission, an agent that implements the late generation sends 1 on every
   lane open, live and late, so the gateway that authorizes the session sees
   it, and sets `late_admission = true` only on the late session. When Hello did
   not advertise it, the agent sets neither field. `AgentHelloResponse` gains `uint32
   edge_late_admission_protocol_version`, through which the gateway advertises
   `late_admission_v1` (value >= 1, set in phase 2). Agents hand off legacy layouts into late
   generations and per-principal holds, and resolve `LATE_ADMISSION_REQUIRED`
   live slots into late generations. They open late sessions only when the
   gateway advertises `late_admission_v1`; until then late records stay on
   disk, accounted and reported as `late_pending_gateway_support`. Because the
   regenerated Elixir bindings decode `EdgeRecordLaneOpen.late_admission`, phase 1
   also makes the gateway refuse a lane open with `late_admission = true` until
   phase 2 implements the late path. A legacy handoff copies nothing while free
   ordinary capacity does not cover the tail and reports `insufficient_capacity`;
   releasing a resolved prefix while records remain unresolved (partial-prefix
   reclaim) is deferred to its own change.
2. **Phase 2, core and gateway (Elixir):** authority history, ledger coverage,
   late grants, late sessions, EventWriter and projectors. The gateway then
   advertises `late_admission_v1`. Phase 2 must be deployed before late
   sessions do anything. The provenance `LATE_ADMISSION` delivery mode
   (grammar-8 transport provenance, value 5) is assigned in phase 2 together
   with its Elixir peer, so phase 1 does not change the shared Go/Elixir
   provenance vectors.
3. **Phases 3 and 4** follow without changing the wire again.

Runtime settings have code defaults. There are no Helm-only knobs and no bypass
switch. Mixed versions fail closed. An old gateway never sees a late session.
An old agent never asks for late grants and its lane opens carry no
`late_admission_protocol_version`, so the gateway never sends it
`LATE_ADMISSION_REQUIRED`, and its records follow today's paths.

## Owner decisions (2026-11-15)

- The default `late_admission_max_age_seconds` of 14 days is approved, as a
  runtime setting with a code default.
- A late PRIMARY record of a current-state contract is stored as history only
  and never overwrites newer state.
- The implementation is split: phase 1 edge Go, phase 2 core and gateway, with
  the gateway's refusal of late lane opens in phase 1 (see Rollout).
- On a live session whose lane open advertised the late-admission protocol,
  any live-lane record whose fence is stale or missing is resolved
  immediately as `LATE_ADMISSION_REQUIRED`, whatever its production window,
  and moved to the late generation; there is no late grant on a live session.
- Records of a different, revoked or superseded origin principal are presented
  by the host's current agent for security quarantine only, through a hold
  keyed by `(lane key, origin principal)`. A record naming a
  `certificate_revoked` interval goes to security quarantine whoever presents
  it, the same principal included: no grant (`certificate_revoked_interval`)
  and no AUDIT. AUDIT `compromise_ended` remains only for an explicit
  `compromised` interval its own principal still presents.
- The history trigger only closes the open interval on delete; it never opens
  a successor.
- With a loaded trust snapshot, an absent fence entry or scope binding, an
  epoch ahead of the known fence and a `produced_at` ahead of the local clock
  are all admissible late; core judges them. Only an unloaded snapshot or an
  `UNAVAILABLE` key lookup stops the handoff. Rejection evidence is only for
  structurally invalid records or an `INVALID` key.
- Already-revoked output grants are seeded as `revoked_cause_unknown`,
  handled like `certificate_revoked`; neither is ever pruned. A current
  revocation state beats an already-issued late grant at publication.
- An origin-principal mismatch replaces `identity_conflict`: security
  quarantine on a late session, `LATE_ADMISSION_REQUIRED` on a live one whose
  lane open carried `late_admission_protocol_version >= 1` (today's
  disposition otherwise).
- `LATE_ADMISSION_REQUIRED` is a `REJECTED_PERMANENT` rejection code sent only
  on live sessions whose `EdgeRecordLaneOpen.late_admission_protocol_version`
  is at least 1; older agents (absent or 0) keep today's live dispositions.
  The gateway's own capability is advertised in
  `AgentHelloResponse.edge_late_admission_protocol_version`.
- Ledger coverage is tracked by a monotonic `ledger_complete_since` seeded at
  migration with the retention cutoff then in force, with PRIMARY requiring
  `produced_at` at or after it plus the clock tolerance, and reason
  `ledger_pruned`.
- A verified quarantine-destination archive receipt is a terminal disposition
  for a sealed media block when an archive destination is configured.
- The media seal-quarantine rule is approved. In local-only mode, publication
  into the qualified durable local archive with its central index receipt is
  terminal, and a bad seal's placement in a quarantine partition or flag of
  that archive is terminal once its central index receipt is persisted; it is
  never indexed for playback and never auto-deleted. With an archive
  destination configured, only a verified archive or quarantine-destination
  receipt ends the drainer; a local publication or local-archive quarantine
  placement never does.
