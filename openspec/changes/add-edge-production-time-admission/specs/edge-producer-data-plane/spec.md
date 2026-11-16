# edge-producer-data-plane Delta

## ADDED Requirements

### Requirement: Captured edge data is never stranded
Every durable edge store that holds captured data SHALL have an automatic drainer and SHALL bring every item it holds to a central terminal disposition: applied, audit, security quarantine or reject-audit.

A drainer runs at process start and retries until the store is empty; a manual
one-shot command is not a drainer. Local bytes SHALL be deleted only after a
central receipt for each item or a structural proof that the store holds no
item. Until a store is drained it SHALL report its item count, bytes, oldest
item age and the reason it is not draining. Only bytes that cannot be parsed as
any known layout MAY remain retained and flagged. Records that carry production
authority SHALL NOT be evicted to free space.

#### Scenario: A store whose authority moved on still drains
- **GIVEN** an edge store holding a committed record whose production grant window has closed and whose fence epoch has since advanced
- **WHEN** the drainer runs
- **THEN** the record SHALL reach a central terminal disposition through late admission
- **AND** the store SHALL NOT report it as retained and flagged

#### Scenario: Unparseable bytes stay retained
- **GIVEN** an edge record root that contains an entry the agent cannot account for as a known layout
- **WHEN** the drainer runs
- **THEN** the agent SHALL leave the entry untouched, keep it charged to the storage budget and report it as unsupported legacy storage

### Requirement: Late admission is a separate generation and session
The agent SHALL admit a committed record whose live admission is no longer possible only into a dedicated late generation for the record's lane key or, for a foreign origin principal, into the hold for `(lane key, origin principal)`, and SHALL deliver both only on the lane key's late session opened with `EdgeRecordLaneOpen.admission = LATE`.

The live rule (production authority current now, fence current) SHALL remain
the only rule for live generations. A late record SHALL NOT be re-signed,
re-wrapped or appended to a live generation. A late session SHALL have its own
credit budget and lower scheduling priority than live sessions, and at most one
late session per lane key SHALL be open; the lane key's hold generations share
that session. The agent SHALL open late sessions only
when the gateway advertises `late_admission_v1`; until then late generations
SHALL be retained, accounted and reported as `late_pending_gateway_support`.

#### Scenario: A late tail does not block live delivery
- **GIVEN** a lane whose late generation holds records waiting for late grants
- **WHEN** the producer appends new records to the live generation of the same lane key
- **THEN** the live session SHALL deliver them without waiting on the late generation

#### Scenario: An old gateway never sees a late session
- **GIVEN** a gateway that does not advertise `late_admission_v1`
- **WHEN** the agent holds records in a late generation
- **THEN** the agent SHALL NOT open a late session
- **AND** SHALL report the records as `late_pending_gateway_support` with their count, bytes and oldest age

#### Scenario: A gateway never accepts a late grant on a live session
- **WHEN** a live-session frame carries a late-admission delivery grant
- **THEN** the gateway SHALL NOT accept the grant and SHALL NOT publish the frame under it

### Requirement: The agent applies the production-time rule before late admission
Before appending a record to a late generation, the agent SHALL validate it with the production-time rule: full structural and typed-body validation, production and source signatures verified under the pinned trust epoch against retained key history with the capability's signed window as evidence, and a loaded trust snapshot; a record whose origin principal is not the authenticated agent SHALL be appended to the hold for `(lane key, origin principal)`.

`produced_at` SHALL be the UUIDv7 time of `event_id`, which structural
validation already binds inside the signed production window and any source
collection window. The agent SHALL NOT require production authority to be
current at now and SHALL NOT require the fence to be current. With a loaded
trust snapshot, a stale fence, an absent fence entry, an epoch ahead of the
known fence, an absent scope binding and a `produced_at` ahead of the local
clock SHALL be admissible, because only core holds the history and the clock
to judge them.
The agent SHALL NOT apply the maximum late age. Outcomes SHALL be classified as follows:

| Outcome | Classes | Handling |
| --- | --- | --- |
| Admissible | valid key, current, stale, absent or ahead fence, absent scope binding, `produced_at` ahead of the local clock | appended to the late generation |
| Admissible, security | `HISTORICALLY_REVOKED` key | appended to the late generation; sent without a grant; the gateway quarantines it |
| Foreign principal | origin principal is a different, revoked or superseded principal | appended to the hold for `(lane key, origin principal)`; never retried as a refusal; sent without a grant; the gateway quarantines it |
| Retryable | `UNAVAILABLE` key, trust snapshot not loaded | left in its source; retried |
| Permanent | structural or body failure, `INVALID` key | written to rejection evidence |

#### Scenario: A days-old record is admissible late
- **GIVEN** a committed record produced six days ago under a production grant that has since expired, signed by a normally rotated issuer key that the trust snapshot still holds as valid
- **WHEN** the agent validates it with the production-time rule
- **THEN** the record SHALL be admissible to the late generation
- **AND** the live rule SHALL still refuse it with `ErrAuthorityExpired`

#### Scenario: A flat record whose assignment was deleted is admissible late
- **GIVEN** a loaded trust snapshot and a flat-spool record whose sweep assignment lifecycle cleanup deleted, so the snapshot holds no fence entry or scope binding for it
- **WHEN** the agent validates it with the production-time rule
- **THEN** the record SHALL be admissible to the late generation and SHALL NOT be classified as retryable
- **AND** core SHALL decide it from the retained history interval or as `history_unknown`

#### Scenario: A record ahead of the local clock waits in the late generation
- **WHEN** a record's `produced_at` is later than the local clock plus the clock tolerance
- **THEN** the agent SHALL append it to the late generation and SHALL NOT block the legacy handoff
- **AND** core SHALL withhold its grant until core's clock passes `produced_at` minus the tolerance

#### Scenario: An epoch ahead of the known fence is judged by core
- **WHEN** a record names an epoch ahead of the fence in the loaded trust snapshot
- **THEN** the agent SHALL append it to the late generation
- **AND** core SHALL issue AUDIT `history_unknown` when it holds no interval for that epoch

#### Scenario: An unknown signing key is refused permanently
- **WHEN** a record's production capability resolves to an `INVALID` key
- **THEN** the agent SHALL NOT admit it late and SHALL write it to rejection evidence

#### Scenario: A foreign-principal record goes to its own hold
- **GIVEN** a committed record whose origin principal is a revoked predecessor of the authenticated agent on the same host
- **WHEN** the agent validates it with the production-time rule
- **THEN** the agent SHALL append it to the hold for its lane key and that origin principal
- **AND** SHALL NOT classify it as retryable

#### Scenario: A compromise-revoked key cannot reach projection
- **GIVEN** a committed record whose production signing key is compromise-revoked
- **WHEN** the agent validates it with the production-time rule
- **THEN** the production-time rule SHALL NOT authorize it for primary publication
- **AND** the record SHALL be delivered only to security quarantine

### Requirement: Core judges late records against authority history
Core SHALL decide a late record's publication when it issues the late delivery grant, from the authority that was valid at `produced_at`, never from current assignment or grant state.

Core SHALL issue a grant with PRIMARY publication only when an authority-history
interval exists for the record's `(producer_assignment_id, authority_epoch)` that
binds the requesting agent, the record's network scope and run shard, satisfies
`active_from - tolerance <= produced_at < coalesce(active_until, +infinity) +
tolerance`, and did not end for an explicit `compromised` reason; and when
`now - produced_at` does not exceed `late_admission_max_age_seconds`; and when
`produced_at` is at or after `ledger_complete_since` plus the clock tolerance;
and when the record's
registry epoch is still admitted. A record that verified but fails any of these
SHALL receive a grant with AUDIT publication and one reason:
`fenced_at_production`, `history_unknown`, `compromise_ended`,
`beyond_late_window`, `ledger_pruned` or `contract_retired`. Core SHALL issue
no grant only for an item that does not bind to the requesting agent,
including a record whose origin principal is not the requesting agent
(`not_assignment_owner`), for a record naming an interval that ended with
`certificate_revoked` or `revoked_cause_unknown` (`certificate_revoked_interval`); such a
frame SHALL NOT be rejected, and the gateway SHALL publish it to security
quarantine without a grant. Core SHALL also issue no grant yet for a record
whose `produced_at` is ahead of core's clock; that frame SHALL be withheld as
retryable, SHALL NOT be rejected or quarantined, and SHALL wait in the late
generation until core's clock passes `produced_at` minus the tolerance, when
core SHALL judge it normally.

#### Scenario: A record produced while its epoch was live is applied after the epoch moved
- **GIVEN** an output grant whose epoch 4 was live from day 1 to day 5 and whose epoch 5 is live now
- **WHEN** a late record names epoch 4 and was produced on day 3
- **THEN** core SHALL issue a late grant with PRIMARY publication

#### Scenario: A record produced after its epoch was fenced is audit only
- **GIVEN** the same grant
- **WHEN** a late record names epoch 4 and was produced on day 6
- **THEN** core SHALL issue a late grant with AUDIT publication and reason `fenced_at_production`

#### Scenario: A record naming an epoch with no history is audit only
- **WHEN** a late record names an epoch for which no authority-history interval exists
- **THEN** core SHALL issue a late grant with AUDIT publication and reason `history_unknown`
- **AND** SHALL NOT infer an interval from the current row

#### Scenario: A deleted assignment still has history
- **GIVEN** a sweep producer assignment that lifecycle cleanup deleted, so its history interval was closed with `ended_reason = deleted`
- **WHEN** a late record produced during that interval arrives within the late age
- **THEN** core SHALL decide it from the closed history interval
- **AND** SHALL NOT withhold it for a missing fence

#### Scenario: A record produced after the delete is audit only
- **GIVEN** the same deleted assignment
- **WHEN** a late record naming its epoch was produced after the delete
- **THEN** core SHALL issue a late grant with AUDIT publication and reason `fenced_at_production`

#### Scenario: Another agent cannot claim the record
- **WHEN** a late grant request names an assignment whose history interval binds a different agent
- **THEN** core SHALL issue no grant for that item, reporting `not_assignment_owner`, and SHALL NOT publish it PRIMARY or AUDIT

### Requirement: Authority history is append-only and written by every writer
Core SHALL record every producer-assignment and output-grant authority interval in an append-only `platform.edge_authority_history` table, written by a database trigger on insert, on any change of epoch, state, agent, network scope or run shard, and on delete.

An insert SHALL open an interval. An update of epoch, state, agent, network
scope or run shard SHALL close the open interval and open the next in the same
transaction, so a raw upsert that bypasses Ash changesets is recorded too. A
delete SHALL only close the open interval with `ended_reason = deleted` and
SHALL NOT open a successor. A
history row SHALL be updated only once, to set `active_until` and
`ended_reason`, and SHALL NOT reference the assignment by foreign key, so
deleting an assignment keeps its history. Revoking an agent's grants SHALL record
whether the cause was `identity_superseded` or `certificate_revoked`. The seeding
migration SHALL create one interval per existing row from `epoch_changed_at` (or
`inserted_at`) and `revoked_at`, SHALL end an already-revoked output-grant
interval with `revoked_cause_unknown`, SHALL keep the normal reason for an
already-revoked sweep assignment, and SHALL NOT invent intervals for earlier
epochs. Ended intervals older than `late_admission_max_age_seconds` plus the
clock tolerance MAY be pruned in bounded batches; open intervals and intervals
ended with `certificate_revoked` or `revoked_cause_unknown` SHALL NOT be pruned. Retired issuer keys SHALL remain in the trust document as valid for at
least `late_admission_max_age_seconds` after their last signed window ends.

#### Scenario: An upsert that bypasses Ash still records history
- **WHEN** an assignment's epoch changes through a raw `on_conflict` update
- **THEN** the previous interval SHALL be closed and a new interval opened in the same transaction

#### Scenario: A delete closes the interval without opening another
- **WHEN** an assignment row is deleted, including through `ON DELETE CASCADE`
- **THEN** its open interval SHALL be closed with `ended_reason = deleted`
- **AND** no interval for that assignment SHALL remain open

#### Scenario: An output grant revoked before cutover never backfills
- **GIVEN** an output grant already revoked when the seeding migration runs
- **WHEN** its principal presents a late record produced within that grant's window
- **THEN** the seeded interval SHALL have ended with `revoked_cause_unknown`
- **AND** core SHALL issue no grant, returning `certificate_revoked_interval`, and the gateway SHALL publish the record only to security quarantine

#### Scenario: A sweep assignment revoked before cutover stays PRIMARY-eligible
- **GIVEN** a sweep producer assignment already revoked when the seeding migration runs
- **WHEN** a late record produced within its window arrives within the late age
- **THEN** core SHALL be able to issue PRIMARY publication for it

#### Scenario: A certificate-revoked interval is never pruned
- **GIVEN** an interval that ended with `certificate_revoked` longer ago than the late age plus the clock tolerance
- **WHEN** history pruning runs
- **THEN** the interval SHALL remain, so a late record naming it still reaches security quarantine only and never AUDIT `history_unknown`

#### Scenario: History rows cannot be rewritten
- **WHEN** any statement tries to change `authority_epoch`, `active_from` or the binding columns of an existing history row
- **THEN** the statement SHALL fail

### Requirement: Late grants bind the production-time decision
A late-admission delivery grant SHALL carry `EdgeDeliveryLateAdmissionV1` in `EdgeDeliveryClaimsV1.transition`, binding `produced_at_unix_nano`, `authority_epoch`, the decided publication and its reason, alongside the existing `event_id`, `record_sha256`, `spool_id` and `sequence`.

The gateway SHALL accept a late grant only when it is signed by a key valid for
the `delivery` purpose, is current, its `produced_at` and epoch equal the
record's, and the record's `(producer_assignment_id, authority_epoch)` is not
in the trust snapshot's terminal-interval list. Core's trust document SHALL
carry, separately from the current fences, `(producer_assignment_id,
network_scope_id, run_shard, authority_epoch)` for every interval that ended
with `certificate_revoked` or `revoked_cause_unknown`; frame authorization SHALL quarantine a record
whose interval is in that list before the missing-grant withhold and
regardless of any already-issued grant, so that revocation beats the grant. A
higher current fence alone SHALL NOT quarantine a record. The gateway SHALL
NOT depend on remembering a late-grant RPC refusal. A late
grant SHALL NOT be accepted where a renewal or rollover is expected, nor the
reverse. On a late session, a frame whose origin principal is not the
authenticated agent SHALL be published to security quarantine, recording both
principals, before the identity rejection and before any grant check, and
SHALL NOT be rejected as `identity_conflict`. A frame whose production or
source key is compromise-revoked, or whose interval is in the trust
snapshot's terminal-interval list, SHALL be published to security quarantine without a grant, decided before the
missing-grant check; any other frame with no valid
late grant SHALL be withheld as retryable. The agent SHALL send those
quarantine-bound frames without waiting for a grant, so they never stall the
host's own late records.
Published late records SHALL carry delivery mode `LATE_ADMISSION` in their
transport provenance on both the primary and audit routes.

#### Scenario: A late grant with a mismatched production time is refused
- **WHEN** a late grant's `produced_at_unix_nano` differs from the UUIDv7 time of the record's `event_id`
- **THEN** the gateway SHALL refuse the grant and withhold the frame

#### Scenario: A late session frame without a grant is withheld
- **WHEN** a late-session frame of the authenticated agent's own origin principal carries no delivery capability, its keys are valid, and its interval has not ended with `certificate_revoked` or `revoked_cause_unknown`
- **THEN** the gateway SHALL withhold it as retryable and SHALL NOT publish it

#### Scenario: A bare frame after a revocation refusal is quarantined through the snapshot
- **GIVEN** a late record of the authenticated agent's own origin principal for which core refused a grant as `certificate_revoked_interval`, and a trust snapshot whose terminal-interval list holds that interval
- **WHEN** its frame arrives with no delivery capability, at any gateway
- **THEN** the gateway SHALL publish it to security quarantine and SHALL NOT withhold it

#### Scenario: A revocation after grant issue beats the grant
- **GIVEN** a late grant with PRIMARY publication issued while the record's interval was open
- **WHEN** the interval is closed with `certificate_revoked` inside the grant's lifetime and the trust snapshot carries it
- **THEN** the gateway SHALL publish the frame only to security quarantine

#### Scenario: A normal epoch advance does not quarantine
- **GIVEN** a late record naming epoch 4 under a valid PRIMARY late grant, while the current fence is epoch 5 and the terminal-interval list does not hold epoch 4
- **WHEN** the gateway authorizes the frame
- **THEN** it SHALL publish the record PRIMARY

#### Scenario: A record in core's future waits, not quarantined
- **WHEN** a late record's `produced_at` is ahead of core's clock and core issues no grant yet
- **THEN** the gateway SHALL withhold its frame as retryable and SHALL NOT quarantine or reject it
- **AND** core SHALL judge it normally once its clock passes `produced_at` minus the tolerance

#### Scenario: A foreign-origin frame is quarantined, not identity-rejected
- **WHEN** a late-session frame's origin principal is not the authenticated agent
- **THEN** the gateway SHALL publish it to security quarantine with both principals recorded
- **AND** SHALL NOT resolve it as `identity_conflict`

#### Scenario: A quarantine-bound frame does not wait for a grant
- **GIVEN** a late session whose next frame comes from a per-principal hold and carries no delivery capability
- **WHEN** the gateway authorizes it
- **THEN** the gateway SHALL publish it to security quarantine
- **AND** the host's own late records behind it SHALL proceed

### Requirement: Compromise and certificate revocation never backfill
A late record SHALL NOT be published PRIMARY when its production or source signing key is compromise-revoked, when the authority interval it names ended with `certificate_revoked`, or when that interval ended for an explicit `compromised` reason.

A compromise-revoked key SHALL route the record to security quarantine. A
late record naming an interval that ended with `certificate_revoked` or `revoked_cause_unknown`,
including one produced before the revocation, SHALL reach security quarantine
only, whoever presents it: a successor through the per-principal hold, or the
same principal on a new certificate or after re-enrollment from its own late
generation. Core SHALL issue no grant for it and SHALL return
`certificate_revoked_interval`; the gateway SHALL publish it to security
quarantine before the missing-grant withhold, and it SHALL NOT receive PRIMARY
or AUDIT publication. An interval ended for an explicit
`compromised` reason, presented by its own still-authenticated principal,
SHALL yield AUDIT (`compromise_ended`) for every late record that names it.
Normal key rotation, reassignment and epoch changes SHALL NOT block PRIMARY
publication of records their own origin principal produced while their epoch
was live.

#### Scenario: A revoked principal's records are quarantined only
- **GIVEN** an agent whose certificate was revoked and whose successor on the same host authenticates
- **WHEN** the successor presents a late record the revoked principal produced before the revocation
- **THEN** the gateway SHALL publish it only to security quarantine
- **AND** core SHALL issue no grant for it

#### Scenario: The same principal re-authenticating after revocation gets quarantine only
- **GIVEN** an agent whose certificate was revoked by operator request, closing its output grant interval with `certificate_revoked`, and which later authenticates again under the same principal
- **WHEN** it presents a late record produced during the revoked interval
- **THEN** core SHALL issue no grant and SHALL return `certificate_revoked_interval`
- **AND** the gateway SHALL publish the record only to security quarantine, before the missing-grant withhold
- **AND** the record SHALL NOT be projected or AUDIT-applied

#### Scenario: An explicitly compromised interval is audit only
- **GIVEN** an output grant interval that ended with reason `compromised`
- **WHEN** its still-authenticated origin principal presents a late record produced during that interval
- **THEN** core SHALL issue a late grant with AUDIT publication and reason `compromise_ended`

#### Scenario: A rotated key still verifies
- **WHEN** a late record is signed by an issuer key that was rotated out of issuance but not compromised
- **THEN** the key SHALL resolve as valid and the record SHALL be eligible for PRIMARY publication

### Requirement: Another principal's records reach security quarantine only
The currently authenticated agent on a host SHALL deliver records whose origin principal is a different, revoked or superseded principal from a per-principal hold on a late session, and the gateway SHALL publish them only to security quarantine.

A per-principal hold SHALL be a separate late generation keyed by `(lane key,
origin principal)`, drained by that lane key's late session, and SHALL NOT
block the in-order handoff or late delivery of the host's own records.
Such a record SHALL still pass signature verification. It SHALL NOT be
projected and SHALL NOT receive PRIMARY or AUDIT publication, whatever grant it
carries. Its security quarantine row SHALL record both the origin principal and
the presenting principal. No such record SHALL be left on the host.

#### Scenario: A foreign-principal record is never projected, even with a grant
- **GIVEN** a late-session frame whose origin principal is not the authenticated agent
- **WHEN** the frame carries a late-admission grant with PRIMARY publication
- **THEN** the gateway SHALL publish it only to security quarantine
- **AND** the quarantine row SHALL record the origin principal and the presenting principal

#### Scenario: The host's own records hand off past a foreign record
- **GIVEN** a flat spool whose first committed record has a revoked predecessor's origin principal and whose later records are the authenticated agent's own
- **WHEN** the handoff runs
- **THEN** the foreign record SHALL be appended to its per-principal hold
- **AND** the agent's own records SHALL be appended to the late generation in sequence order

### Requirement: Late admission is bounded and idempotent
Core SHALL bound late PRIMARY publication by `late_admission_max_age_seconds`, a runtime setting in `platform.edge_pipeline_settings` with a code default of 14 days, and SHALL keep event-ledger rows for at least that long.

The edge ledger retention horizon SHALL be at least the configured late age.
Core SHALL persist `ledger_complete_since`, a monotonic timestamp such that
every event-ledger row with `inserted_at` at or after it is still retained. It
SHALL start as "nothing pruned" (the earliest representable time), SHALL
advance only when pruning deletes rows, to that batch's `inserted_at` cutoff,
and SHALL NOT move backward. A late record SHALL receive PRIMARY publication
only when its `produced_at` is at or after `ledger_complete_since` plus the
clock tolerance; an older record SHALL be delivered as AUDIT
(`ledger_pruned`). A record older
than `late_admission_max_age_seconds` SHALL be delivered as AUDIT
(`beyond_late_window`). Neither SHALL be refused. A late
PRIMARY record SHALL pass through the idempotent event ledger: the same
`(network_scope_id, event_id)` with the same semantic digest SHALL be a replay
no-op, and a different digest SHALL be `EVENT_ID_CONFLICT`. Late grants SHALL be
issued in batches within the existing request bounds.

#### Scenario: A record older than the late age is stored, not projected
- **WHEN** a verified late record's `produced_at` is older than `late_admission_max_age_seconds`
- **THEN** core SHALL issue a grant with AUDIT publication and reason `beyond_late_window`

#### Scenario: A record delivered before the upgrade is not applied twice
- **GIVEN** a record that the old agent delivered and core applied, but whose acknowledgement was lost before the upgrade
- **WHEN** the new agent hands the same record off through late admission within the late age
- **THEN** EventWriter SHALL treat it as a replay and SHALL NOT project it again

#### Scenario: The ledger horizon follows the late age
- **WHEN** an operator raises `late_admission_max_age_seconds`
- **THEN** the ledger retention horizon SHALL be at least the new value

#### Scenario: The upgrade tail is PRIMARY-eligible before any pruning
- **GIVEN** a deployment whose ledger has never been pruned
- **WHEN** a late record produced five days ago arrives within the late age with a live authority interval
- **THEN** core SHALL NOT issue AUDIT `ledger_pruned` for it

#### Scenario: Producer clock skew cannot pass a pruned duplicate
- **GIVEN** `ledger_complete_since` at cutoff C after pruning rows with `inserted_at` before C
- **WHEN** a late record arrives whose `produced_at` is after C but before C plus the clock tolerance
- **THEN** core SHALL issue a grant with AUDIT publication and reason `ledger_pruned`

#### Scenario: Raising the late age after pruning never replays a duplicate
- **GIVEN** ledger rows pruned up to a cutoff 30 days ago, so `ledger_complete_since` is 30 days ago
- **WHEN** an operator raises `late_admission_max_age_seconds` to 90 days and a late record produced 40 days ago arrives
- **THEN** core SHALL issue a grant with AUDIT publication and reason `ledger_pruned`
- **AND** `ledger_complete_since` SHALL NOT move backward

### Requirement: Late records stay distinguishable end to end
Every late record SHALL be recorded as late in an audit trail that stores admission `late`, `produced_at`, publication, decision reason, the grant's issuer key id and the receiving gateway.

EventWriter SHALL accept delivery mode `LATE_ADMISSION` on the primary and audit
routes. A projector SHALL authorize a late PRIMARY record from the grant's
historical decision instead of `OutputGrants.check_current`. A current-state
projector SHALL apply a late record only when it is newer, by `produced_at`,
than the state it holds; time-series rows SHALL be written at their own time.

#### Scenario: A late primary record is not dead-lettered for a moved grant
- **GIVEN** a late record published PRIMARY under a late grant whose interval has since ended
- **WHEN** its projector runs
- **THEN** the projector SHALL NOT refuse it as `output_grant_not_current`

#### Scenario: An old snapshot does not regress current state
- **GIVEN** a current-state contract whose stored state was produced on day 5
- **WHEN** a late record of that contract produced on day 3 is applied
- **THEN** the stored state SHALL remain the day 5 state and the late record SHALL be retained as history

### Requirement: A live-lane record that needs late admission moves to the late generation
The gateway SHALL immediately resolve any live-lane record whose fence is stale or missing at the gateway, or whose origin principal is not the authenticated agent, with the rejection code `late_admission_required`, whatever its production window and in place of `identity_conflict`, and the agent SHALL append the exact record bytes durably to the late generation for that lane key, or to the hold for `(lane key, origin principal)` when the origin principal is not the authenticated agent, before it persists that resolution.

`late_admission_required` SHALL be a resolving disposition: the gateway SHALL
NOT withhold the frame and SHALL NOT reject it as `fence_stale` into the local
quarantine. The live lane SHALL NOT wait on a late grant, and a late grant
SHALL be accepted only on a late session. If the late append is not durable,
the agent SHALL NOT persist the resolution (resolved prefix or reclaim) and
SHALL retry. The late session and core's authority history then decide the
record's publication.

#### Scenario: A missing fence no longer wedges a lane
- **GIVEN** a live-lane record whose producer assignment was deleted after the record was produced during a live epoch
- **WHEN** the sender delivers it on the live session
- **THEN** the gateway SHALL resolve it with `late_admission_required`
- **AND** SHALL NOT withhold it for a missing fence
- **AND** the live lane SHALL continue with the records behind it

#### Scenario: A stale fence resolves while the production window is still open
- **GIVEN** a live-lane record whose assignment was revoked the same day, so its fence is stale while its signed production window still contains now
- **WHEN** the sender delivers it on the live session
- **THEN** the gateway SHALL resolve it with `late_admission_required` and SHALL NOT reject it as `fence_stale`
- **AND** the agent SHALL append it to the late generation, where core decides it from authority history

#### Scenario: A foreign-origin live record is held, not identity-rejected
- **WHEN** a live-session frame's origin principal is not the authenticated agent
- **THEN** the gateway SHALL resolve it with `late_admission_required` and SHALL NOT resolve it as `identity_conflict`
- **AND** the agent SHALL append it durably to the hold for `(lane key, origin principal)` before persisting the resolution

#### Scenario: The late append precedes the live resolution
- **GIVEN** a live-lane record the gateway resolved with `late_admission_required`
- **WHEN** the agent crashes after the gateway response and before the late append is durable
- **THEN** the record SHALL remain unresolved in the live lane after restart
- **AND** the agent SHALL append it to the late generation before persisting the resolution

## MODIFIED Requirements

### Requirement: Record authorization is four separate typed decisions
Record authorization SHALL be evaluated as FOUR distinct decisions, each returning a TYPED disposition, and SHALL NOT be collapsed into a single boolean result.

A signature-verification helper MAY exist, but its boolean SHALL NOT be the only
authorization result. The four dimensions and their typed outcome sets are:

1. HISTORICAL COLLECTION/PROVENANCE PROOF -- whether the production/source
   capability was valid over the signed collection interval. This dimension has an
   INPUT on the wire and an OUTPUT that is not on the wire, and this change freezes
   only the input.
   The INPUT is `source_authorization`, whose kind is the generated
   `EdgeSourceAuthorizationKind`. Its members are frozen here, in full:
   `EDGE_SOURCE_AUTHORIZATION_KIND_UNSPECIFIED`,
   `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP`,
   `EDGE_SOURCE_AUTHORIZATION_KIND_SWEEP_PROFILE`,
   `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK`,
   `EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC`,
   `EDGE_SOURCE_AUTHORIZATION_KIND_ON_DEMAND`,
   `EDGE_SOURCE_AUTHORIZATION_KIND_INTEGRATION_RUN`, and
   `EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL`.
   ABSENCE AND PRESENT-ZERO ARE DIFFERENT. `source_authorization` is OPTIONAL, and
   its ABSENCE is the only way to express "no source authorization"; such a record
   is REPRESENTABLE and valid AT THIS LAYER. A PRESENT `source_authorization` whose
   kind is `EDGE_SOURCE_AUTHORIZATION_KIND_UNSPECIFIED` SHALL be REJECTED: it
   asserts a source authorization while naming none.
   THESE RULES ARE RECORD-LAYER REPRESENTABILITY, SUBJECT TO PAYLOAD-SPECIFIC
   REQUIREMENTS. "Valid at the record layer" does NOT mean every payload accepts it:
   a payload contract MAY REQUIRE source authorization, and `SweepObservationBatchV1`
   DOES -- see the sweep correlation requirements below. The record layer says the
   field is optional and therefore no structural gate can demand it; a payload
   contract may still demand it, and where it does that demand governs. Read as an
   unqualified permission, this paragraph would contradict the sweep matrix.
   SOURCE PRESENCE IS INDEPENDENT OF ATTRIBUTION CLASSIFICATION. Absence SHALL NOT
   be read as, or equated with, PASSIVE -- PASSIVE asserts only that a record claims
   no produced target range, which is a different question from whether a source
   authorization is carried. All four combinations of
   {ACTIVE, PASSIVE} x {source present, source absent} are legal and SHALL each be
   REPRESENTABLE at the record and classification layers; no component SHALL infer
   one axis from the other. Representable is not the same as accepted by every
   payload: a payload contract requiring source authorization narrows which of the
   four its own records may use, without making any of them unrepresentable.
   The OUTPUT -- the historical-proof RESULT -- is NOT frozen here. It is not
   carried on the wire, it is not this enum (which says which authorization a record
   CLAIMS, never whether that claim proved out), and it exists even for records with
   no source authorization at all. This change freezes only the INVARIANT that the
   historical proof is a decision SEPARATE from the authorization kind the record
   carries. Its outcome vocabulary, its key-rotation versus compromise-revocation
   rules, and its evidence are owned downstream.
2. GATEWAY PUBLICATION -- the outcome delivered ON THE WIRE SHALL be one of the
   generated `EdgeRecordDispositionKind` members and nothing else:
   `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE`, `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY`, `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE`,
   `EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT`, `EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE` (`UNSPECIFIED` is rejected). Any
   INTERNAL publication subtype -- for example a security-quarantine variant --
   SHALL MAP onto one of those five and SHALL NOT appear as a sixth wire value.
   The internal subtypes themselves, and which maps to which, are runtime and are
   defined downstream.
3. DELIVERY MODE -- carried on the wire as a `u64` in the transport-provenance
   grammar, NOT as a proto enum. The frozen constants are
   `DeliveryModeUnspecified = 0` (rejected), `DeliveryModeFresh = 1`,
   `DeliveryModeRenewal = 2`, `DeliveryModeRollover = 3`,
   `DeliveryModeLateFenced = 4`, and `DeliveryModeLateAdmission = 5`.
   `DeliveryModeLateAdmission` marks a record published under a late-admission
   delivery grant on a late session, on the primary or audit route. Its
   `delivery_proof_digest` SHALL be computed over the grant's
   `EdgeDeliveryLateAdmissionV1` transition, which SHALL be admitted alongside
   the renewal and rollover transitions; a late-admission proof SHALL be valid
   only with `DeliveryModeLateAdmission`, and a renewal or rollover proof SHALL
   NOT be valid with it.
4. PROJECTION -- the outcome set is RUNTIME and is defined downstream, because it
   is not carried on the wire. This change freezes only that projection is a
   SEPARATE decision from publication, and that a publication accept SHALL NOT
   imply an authoritative projection.

This requirement defines the four DIMENSIONS. What it freezes is only the values
carried on the wire, and they are not all of the same kind:

- dimension 1's `EdgeSourceAuthorizationKind` is a wire INPUT -- the source
  authorization a record CLAIMS. It is NOT dimension 1's outcome vocabulary. Note
  also that source authorization is only ONE input to the historical proof, which
  also weighs production authority and therefore runs even when
  `source_authorization` is absent. Dimension 1's OUTCOME is runtime-owned.
- dimension 2's `EdgeRecordDispositionKind` members and dimension 3's
  `DeliveryMode` constants ARE outcome vocabularies, and are frozen as such.
- dimension 4's outcome vocabulary is runtime-owned. Dimension 4's outcome set is NOT frozen here; the
only projection facts frozen here are that it is a separate decision from
publication and that a publication accept does not imply an authoritative
projection.

Everything about applying any dimension -- the projection outcome set and its
meanings, which component evaluates which dimension and in what order, how
capability grants may be cached and fenced, which destination stream or DLQ each
outcome routes to, the PubAck requirement, and whether the agent may resolve its
spool entry -- is runtime behaviour and is specified in the companion runtime
change, as one complete requirement there.

An earlier revision split this requirement MID-SENTENCE across the two changes:
decision 1 ended on "at the trust-policy" here and continued with "epoch) is a
reusable grant..." there. A requirement SHALL be complete in the change that owns
it.

#### Scenario: One boolean cannot stand in for the four decisions
- **WHEN** a component needs an authorization outcome
- **THEN** it SHALL consume the typed historical-proof, publication, delivery-mode,
  and projection dispositions
- **AND** a single `ValidateRecordSigned`-style boolean SHALL NOT be the sole basis
  for publication or projection

#### Scenario: Audit and quarantine are distinct generated ACK values
- **WHEN** a delivery ACK carries `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY` or `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE`
- **THEN** each SHALL be distinguishable from `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE` and from
  `EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT`
- **AND** a reader SHALL NOT collapse them into either

#### Scenario: An internal subtype maps onto a generated value
- **WHEN** the runtime distinguishes an internal publication subtype such as a
  security quarantine
- **THEN** it SHALL be delivered as one of the five generated
  `EdgeRecordDispositionKind` members
- **AND** SHALL NOT introduce a sixth wire value

#### Scenario: A record asserts a source authorization without naming one
- **WHEN** a record carries a present `source_authorization` whose kind is
  `EDGE_SOURCE_AUTHORIZATION_KIND_UNSPECIFIED`
- **THEN** it SHALL be rejected
- **AND** an ABSENT `source_authorization` SHALL remain valid AT THE RECORD LAYER, being the
  only way to express no source authorization
- **AND** this SHALL NOT be read as accepting absence in a payload whose own contract
  REQUIRES source authorization, such as `SweepObservationBatchV1`

#### Scenario: Source presence is not read as an attribution classification
- **GIVEN** a record whose `source_authorization` is absent
- **WHEN** its attribution classification is determined
- **THEN** the absence SHALL NOT make it PASSIVE, and an ACTIVE record with no
  source authorization SHALL remain legal AT THE RECORD AND CLASSIFICATION LAYERS
- **AND** neither axis SHALL be inferred from the other
- **AND** a payload contract MAY still require source authorization, narrowing which
  combinations its own records may use without making any of them unrepresentable

#### Scenario: A late-admission record carries its own delivery mode
- **WHEN** the gateway publishes a record under a late-admission delivery grant
- **THEN** its transport provenance SHALL carry `DeliveryModeLateAdmission = 5`
- **AND** its `delivery_proof_digest` SHALL be computed over the `EdgeDeliveryLateAdmissionV1` transition
- **AND** a late-admission proof paired with any other delivery mode SHALL be rejected
