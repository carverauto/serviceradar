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
Before appending a record to a late generation, the agent SHALL validate it with the production-time rule: full structural and typed-body validation, production and source signatures verified under the pinned trust epoch against retained key history with the capability's signed window as evidence, `produced_at <= now + clock tolerance`, a loaded trust snapshot, and a record epoch that is not ahead of a present fence; a record whose origin principal is not the authenticated agent SHALL be appended to the hold for `(lane key, origin principal)`.

`produced_at` SHALL be the UUIDv7 time of `event_id`, which structural
validation already binds inside the signed production window and any source
collection window. The agent SHALL NOT require production authority to be
current at now and SHALL NOT require the fence to be current. With a loaded
trust snapshot, a stale fence, an absent fence entry and an absent scope
binding SHALL be admissible, because only core holds the history to judge them.
The agent SHALL NOT apply the maximum late age. Outcomes SHALL be classified as follows:

| Outcome | Classes | Handling |
| --- | --- | --- |
| Admissible | valid key, current, stale or absent fence, absent scope binding | appended to the late generation |
| Admissible, security | `HISTORICALLY_REVOKED` key | appended to the late generation; sent without a grant; the gateway quarantines it |
| Foreign principal | origin principal is a different, revoked or superseded principal | appended to the hold for `(lane key, origin principal)`; never retried as a refusal; sent without a grant; the gateway quarantines it |
| Retryable | `UNAVAILABLE` key, trust snapshot not loaded, epoch ahead of a present fence, `produced_at` in the future | left in its source; retried |
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

#### Scenario: A record from the future is not late
- **WHEN** a record's `produced_at` is later than now plus the clock tolerance
- **THEN** the agent SHALL refuse it as not yet valid, leave it in its source and retry

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
including a record whose origin principal is not the requesting agent; such a
frame SHALL NOT be rejected, and the gateway SHALL publish it to security
quarantine without a grant.

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
- **GIVEN** a sweep producer assignment that lifecycle cleanup deleted after its epoch ended
- **WHEN** a late record produced during that epoch arrives within the late age
- **THEN** core SHALL decide it from the retained history interval
- **AND** SHALL NOT withhold it for a missing fence

#### Scenario: Another agent cannot claim the record
- **WHEN** a late grant request names an assignment whose history interval binds a different agent
- **THEN** core SHALL issue no grant for that item, reporting `not_assignment_owner`, and SHALL NOT publish it PRIMARY or AUDIT

### Requirement: Authority history is append-only and written by every writer
Core SHALL record every producer-assignment and output-grant authority interval in an append-only `platform.edge_authority_history` table, written by a database trigger on insert, on any change of epoch, state, agent, network scope or run shard, and on delete.

The trigger SHALL close the open interval and open the next in the same
transaction, so a raw upsert that bypasses Ash changesets is recorded too. A
history row SHALL be updated only once, to set `active_until` and
`ended_reason`, and SHALL NOT reference the assignment by foreign key, so
deleting an assignment keeps its history. Revoking an agent's grants SHALL record
whether the cause was `identity_superseded` or `certificate_revoked`. The seeding
migration SHALL create one interval per existing row from `epoch_changed_at` (or
`inserted_at`) and `revoked_at`, and SHALL NOT invent intervals for earlier
epochs. Ended intervals older than `late_admission_max_age_seconds` plus the
clock tolerance MAY be pruned in bounded batches; open intervals SHALL NOT be
pruned. Retired issuer keys SHALL remain in the trust document as valid for at
least `late_admission_max_age_seconds` after their last signed window ends.

#### Scenario: An upsert that bypasses Ash still records history
- **WHEN** an assignment's epoch changes through a raw `on_conflict` update
- **THEN** the previous interval SHALL be closed and a new interval opened in the same transaction

#### Scenario: History rows cannot be rewritten
- **WHEN** any statement tries to change `authority_epoch`, `active_from` or the binding columns of an existing history row
- **THEN** the statement SHALL fail

### Requirement: Late grants bind the production-time decision
A late-admission delivery grant SHALL carry `EdgeDeliveryLateAdmissionV1` in `EdgeDeliveryClaimsV1.transition`, binding `produced_at_unix_nano`, `authority_epoch`, the decided publication and its reason, alongside the existing `event_id`, `record_sha256`, `spool_id` and `sequence`.

The gateway SHALL accept a late grant only when it is signed by a key valid for
the `delivery` purpose, is current, and its `produced_at` and epoch equal the
record's. A late grant SHALL NOT be accepted where a renewal or rollover is
expected, nor the reverse. On a late session, a frame whose production or
source key is compromise-revoked, or whose origin principal is not the
authenticated agent, SHALL be published to security quarantine without a
grant, decided before the missing-grant check; any other frame with no valid
late grant SHALL be withheld as retryable. The agent SHALL send those
quarantine-bound frames without waiting for a grant, so they never stall the
host's own late records.
Published late records SHALL carry delivery mode `LATE_ADMISSION` in their
transport provenance on both the primary and audit routes.

#### Scenario: A late grant with a mismatched production time is refused
- **WHEN** a late grant's `produced_at_unix_nano` differs from the UUIDv7 time of the record's `event_id`
- **THEN** the gateway SHALL refuse the grant and withhold the frame

#### Scenario: A late session frame without a grant is withheld
- **WHEN** a late-session frame of the authenticated agent's own origin principal carries no delivery capability and its keys are valid
- **THEN** the gateway SHALL withhold it as retryable and SHALL NOT publish it

#### Scenario: A quarantine-bound frame does not wait for a grant
- **GIVEN** a late session whose next frame comes from a per-principal hold and carries no delivery capability
- **WHEN** the gateway authorizes it
- **THEN** the gateway SHALL publish it to security quarantine
- **AND** the host's own late records behind it SHALL proceed

### Requirement: Compromise and certificate revocation never backfill
A late record SHALL NOT be published PRIMARY when its production or source signing key is compromise-revoked, when its origin principal's certificate was revoked, or when the authority interval it names ended for an explicit `compromised` reason.

A compromise-revoked key SHALL route the record to security quarantine.
Records of a principal whose certificate was revoked, including records
produced before the revocation, SHALL reach security quarantine only, through
the per-principal hold; core SHALL issue no grant for them and they SHALL NOT
receive PRIMARY or AUDIT publication. An interval ended for an explicit
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
The gateway SHALL immediately resolve any live-lane record whose fence is stale or missing at the gateway with the rejection code `late_admission_required`, whatever its production window, and the agent SHALL append the exact record bytes durably to the late generation for that lane key, or to the hold for `(lane key, origin principal)` when the origin principal is not the authenticated agent, before it persists that resolution.

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

#### Scenario: The late append precedes the live resolution
- **GIVEN** a live-lane record the gateway resolved with `late_admission_required`
- **WHEN** the agent crashes after the gateway response and before the late append is durable
- **THEN** the record SHALL remain unresolved in the live lane after restart
- **AND** the agent SHALL append it to the late generation before persisting the resolution
