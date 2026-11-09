# edge-producer-data-plane Delta

## ADDED Requirements

### Requirement: Spool generations are per lane and freeze one authenticated identity
A spool generation SHALL be scoped to exactly ONE lane, where a lane is one
(route profile, traffic class) pair drawn from the finite platform taxonomy, and
SHALL freeze that lane's `network_scope_id` and authenticated agent identity for
every record it contains.

One OPEN generation SHALL exist per lane, not per agent. Bulk, interactive, and
recovery lanes therefore run concurrently, each with its own open generation,
sequence space, and reclamation state. Serializing them behind a single open
generation would collapse the lane architecture and let a slow bulk lane block
interactive or recovery traffic.

The authenticated agent identity and `network_scope_id` SHALL be stable for the
agent across its lanes: an agent serves ONE scope, enforced as an authenticated
identity invariant, not by serializing generations. Closed-but-unreclaimed
generations MAY coexist with the open one on the same lane and SHALL remain
independently recoverable under their own frozen identity.

A record presenting a lane that has no open generation SHALL cause that lane's
generation to be opened, not an append onto another lane's generation.

#### Scenario: Lanes have independent open generations
- **WHEN** the agent has records for the bulk and interactive lanes
- **THEN** each lane SHALL have its own open generation
- **AND** neither SHALL block the other's appends or reclamation

#### Scenario: Lane change rotates only that lane
- **WHEN** a lane's route profile or traffic class changes
- **THEN** that lane's generation SHALL close and a successor open
- **AND** other lanes' generations SHALL be unaffected

#### Scenario: Valid transition is retryable, not permanent
- **WHEN** an append arrives for a lane whose generation must rotate first
- **THEN** the spool SHALL answer `ROTATION_REQUIRED` as a RETRYABLE outcome
- **AND** the producer SHALL be able to retry the same append after rotation

#### Scenario: Malformed or unauthorized identity is permanent
- **WHEN** an append presents a malformed lane, or a `network_scope_id` or agent
  identity the authenticated session does not authorize
- **THEN** the spool SHALL refuse it as a PERMANENT error

### Requirement: Attribution is semantically joined to its record before durability
Attribution SHALL be proven to DESCRIBE the record it is committed with, by exact
join against that record's own authenticated fields, before the append is durable.
Physical binding alone is insufficient.

The spool SHALL verify, field by field, that the attribution's
`contract_bundle_sha256` equals the record's `EdgeOutputContractRef` bundle digest;
that `producer_assignment_id`, `run_id`, and `run_shard` equal the record's
`EdgeProducerContext` values; that `production_scope_id` and `scope_sha256` equal
the PRODUCTION scope's ID and digest, ALWAYS; that the attribution's SOURCE
IDENTITY -- kind, `context_id`, `source_scope_id`, and `source_scope_sha256`,
JOINTLY PRESENT and each compared against the record's signed source
authorization, or JOINTLY ABSENT -- matches, so a supplied attribution can neither
name a source the record does not carry nor substitute one of its members; that
`authority_epoch` equals the value asserted by the record's PRODUCTION claims, and
by its SOURCE claims when one is present; and, for ACTIVE attribution,
that `range_sha256` equals either the signed source range the record's
authorization carries, or a range derivation that the output contract explicitly
owns and that is itself frozen. Only then SHALL it commit the physical binding.

The attribution carries TWO scope digests, not one. A single `scope_sha256` cannot
equal both: in the canonical accepted record the production scope is
`digest32(0x75)` while the source scope is the target range `sweepRangeSha()`, and
`ValidateSweepRecord` accepts it today. A join demanding one value satisfy both
would permanently refuse the canonical valid ACTIVE append. `scope_sha256`
therefore means the PRODUCTION scope, and `source_scope_sha256` -- part of the
source identity, present exactly when it is -- means the SOURCE scope.

Production-claim agreement is unconditional; source-claim agreement is performed
WHENEVER A SOURCE AUTHORIZATION IS PRESENT.

Classification and source-authorization presence are INDEPENDENT AXES.
`ATTRIBUTED_PASSIVE` means "asserts no produced target range"; it does NOT mean "no
source authorization". Recovery-control work is a live example of a
source-authorized record with no produced target range. All four combinations of
{ACTIVE, PASSIVE} x {source present, source absent} are permitted AT THE RECORD AND
CLASSIFICATION LAYERS, and the source join follows PRESENCE, never classification.
That permission is about what the two axes may express together; it is SUBJECT TO
PAYLOAD CONTRACTS, which may require source authorization for their own records --
`SweepObservationBatchV1` does. A payload requirement narrows which combinations its
records may use without collapsing the two axes back into one. An earlier revision of this document
tied them together; that conflation would have made a source-authorized passive
record either unjoinable or forced to fabricate a produced range.

The join SHALL NOT equate `EdgeProducerContext.run_id` with a source correlation
key or an execution identity. That equality was proposed in an earlier revision of
this document and is WITHDRAWN as false: `run_id` is the HOST-ISSUED PRODUCER-RUN
identity, signed independently in both the production and source claims, and it is
a different fact from the source action's correlation key. A committed accepted
record proves it -- the canonical scheduled-check vector carries producer
`run_id = uuidv7(0x73)` while its source `context_id` and body `execution_id` are
`uuidv7(0x20)`, and `ValidateSweepRecord` accepts it today.

The two correspondences that DO hold are `run_shard == execution_shard` and
`authority_epoch == assignment_epoch`, and they hold ONLY where the originating
contract carries those fields: `SweepObservationBatchV1` and `MtrSweepContextV1`
do; `MtrScheduledCheckContextV1`, `MtrAdHocContextV1`, and `MtrCommandContextV1`
carry neither. Generalising from two pairs to a third was the error; generalising
them across contracts that cannot express them would be the same error again.

Source correlation SHALL be proven PER PAYLOAD CONTRACT AND CORRELATION VARIANT,
against the operands that body actually carries, never against a universal
execution identity -- because there is none. `MtrSweepContextV1` carries
`sweep_execution_id`, but `MtrScheduledCheckContextV1` carries `check_id`,
`MtrAdHocContextV1` carries `scan_run_id`, and `MtrCommandContextV1` carries
`command_id`; `SweepObservationBatchV1` carries BOTH `execution_id` and
`source_run_id`, so a source-authorization KIND alone does not determine which one a
correlation should be proven against. The batch's `source` DOES: the frozen matrix
selects EXACTLY ONE operand per source, always one and never neither, so the open
question this paragraph once described -- "which one, if either" -- is settled for
this payload and only the kind-alone shortcut remains wrong.

Both matrices are now DEFINED, and their implementation states still differ. The MTR
matrix's per-variant dispatch is the correct shape and is IMPLEMENTED. The
`SweepObservationBatchV1` matrix is FROZEN by task 1.3 in `freeze-edge-record-v1-abi`
-- the source selects both the authorization kind and WHICH body field the signed
context operand is compared against, and `source_run_id` is REQUIRED on exactly the
sources that select it and FORBIDDEN otherwise -- but it is NOT YET IMPLEMENTED: the
current join compares the signed context to `execution_id` for every source and never
reads `source_run_id`. Task 1.3 owns that rewrite. DEFINED and IMPLEMENTED are not the
same state and SHALL NOT be described as one.

Recovery attribution therefore SHALL obtain any source/execution correlation it
needs from the DURABLE ASSIGNMENT MAPPING, not by equating record fields.

THE MAPPING IS NOT TASK 1.3's. 1.3 owns only the mapping's KEY, frozen as part of the
edge record v1 wire ABI. The mapping's EXISTENCE and durable STATE belong to task
2.20, and its VALUE SHAPE -- the tagged POSITIVE / EXPLICIT_NEGATIVE result and its
durable negative reason -- to task 2.20a. Attributing the whole mapping to 1.3 would
make an ABI freeze wait on a runtime store, which is the coupling the ABI change was
extracted to break. A span freezes the producer-side assignment identity; resolving that
identity to a scheduler execution is a lookup against an authoritative record, and
attempting to shortcut it by field equality would encode a relationship the wire
contract does not have.

OWNERSHIP OF THE SHARED ATTRIBUTION RESULT IS SPLIT, and an earlier revision assigning
all of it to task 1.3 conflicted with that task's own ledger, which lists only the
correlation matrix as remaining. The split follows what each task is:

- TASK 1.3 owns the correlation RULES and the VALIDATORS that enforce them -- which
  operand each source selects, the `source_run_id` disposition, and the per-relation
  join. That is the ABI half and it is where the matrix lives.
- TASK 2.22 owns the shared validated-attribution RESULT: its type, its production by
  the contract-specific validators from the operands their own body carries, and its
  consumption. That is runtime plumbing, and putting it in 1.3 would make an ABI
  freeze wait on a spool binding.

Neither task may treat the other's half as delivered by its own.

A payload contract MAY require source authorization even though the record-level field
is optional; `SweepObservationBatchV1` does, because without it there is no signed
statement of what was authorized. The general rule below is about records whose payload
PERMITS its absence, and SHALL NOT be read as licensing a sweep body to omit it.

#### Scenario: A record whose payload permits absent source authorization joins on production claims
- **WHEN** a record whose payload contract PERMITS absent source authorization carries
  none and is appended
- **THEN** the join SHALL prove agreement against its production claims
- **AND** SHALL NOT require source claims to exist
- **AND** this SHALL NOT apply to a payload whose own contract REQUIRES source
  authorization, such as `SweepObservationBatchV1`

#### Scenario: A passive record with source authorization still joins on it
- **WHEN** an `ATTRIBUTED_PASSIVE` record carries a source authorization
- **THEN** the source join SHALL be performed
- **AND** classification SHALL NOT be used to skip it

#### Scenario: Production and source scopes are distinct
- **WHEN** a record's production scope differs from its source scope
- **THEN** the join SHALL compare each against its own attribution member
- **AND** SHALL NOT require one value to satisfy both

#### Scenario: Producer run identity is not a correlation key
- **WHEN** a record's producer `run_id` differs from its source `context_id`
- **THEN** the join SHALL NOT reject it on that basis alone

#### Scenario: Correlation is proven against the body's own operands
- **WHEN** a batch carries a scheduled-check, ad-hoc, or command correlation
- **THEN** the join SHALL prove correlation against `check_id`, `scan_run_id`, or
  `command_id` respectively
- **AND** SHALL NOT require an execution identity the body does not carry

`range_sha256` is not optional to the join. It is the field that says WHICH
produced output the attribution claims; leaving it unverified would let a valid
join name the right contract, assignment, run, and authority while asserting a
range the record never produced.

Physical binding without the semantic join is forgeable by construction: a sink
may attach record B's provenance to record A and compute a perfectly valid
`event_id`/sequence/`record_sha256` binding over A. The manifest would then
validate while naming the wrong contract, assignment, run, or authority. The join
is what makes the binding mean "this provenance came from this record".

An attribution failing ANY join SHALL be refused as a permanent error, and SHALL
NOT be committed as unattributable — a refused append never became durable, so
there is no loss to attribute.

#### Scenario: Mismatched provenance is refused, not stored
- **WHEN** an append presents attribution whose contract bundle, assignment, run,
  shard, authority epoch, or scope does not equal the record's own fields
- **THEN** the spool SHALL refuse the append as a permanent error
- **AND** SHALL NOT report the record durable

#### Scenario: Join precedes physical binding
- **WHEN** the spool commits an attribution entry
- **THEN** every join above SHALL have been verified against that record
- **BEFORE** the physical binding is written

### Requirement: Unattributable loss forces conservative repair before resolution
An unattributable span SHALL trigger conservative repair, and SHALL NOT be merely
accepted and excluded from attribution. Acknowledging unknown data loss without
repairing anything is not a safe consumer behaviour.

On applying a manifest containing an unattributable span, the platform SHALL:

- durably record the span in a loss audit/quarantine store, retained
  independently of the manifest;
- FENCE the affected generation for the agent and scope, so no consumer treats
  that generation's coverage as complete;
- reconcile with the scheduler, so work whose output may have been lost is
  re-planned rather than assumed delivered.

`RecoveryResolvedV1` SHALL NOT be emitted or accepted for a recovery containing an
unattributable span until those actions are durably committed. Resolution asserts
the loss was accounted for; emitting it while a span is unexplained asserts
something false.

Terminal and lifecycle evidence SHALL NOT be classified passive automatically. A
lost terminal record can hide the completion state of produced work, so it SHALL
be classified from its attribution, and treated as unattributable when that
attribution cannot be proven.

#### Scenario: Resolution is blocked until repair commits
- **WHEN** a manifest contains an unattributable span
- **THEN** `RecoveryResolvedV1` SHALL NOT be emitted or accepted
- **UNTIL** audit, fencing, and scheduler reconciliation are durably committed

#### Scenario: Generation is fenced, not silently trusted
- **WHEN** an unattributable span is applied
- **THEN** the affected agent/scope generation SHALL be fenced
- **AND** its coverage SHALL NOT be reported complete

#### Scenario: Lost terminal evidence is not assumed harmless
- **WHEN** a lost span held terminal or lifecycle records
- **THEN** it SHALL NOT be classified passive by kind alone
- **AND** SHALL be unattributable when its attribution cannot be proven

### Requirement: Segment deletion requires a durable coverage proof
A source segment SHALL NOT be deleted until a durable COVERAGE PROOF accounts for
every UNRECLAIMED ALLOCATED sequence it held — that is, every sequence in
`(durable_local_reclaim_watermark, sequence_high_water]` — as exactly one of:

- a FULLY COMMITTED, SENDER-VISIBLE destination slot — not merely an fsynced
  destination record. Its own commit evidence SHALL cover the new wrapper and
  coordinates, the REBOUND attribution, the durable old->new mapping, the
  destination sequence high-water, and the directory metadata that makes the slot
  discoverable after restart; or
- a FROZEN loss span whose required recovery pages have been PubAcked AND whose every
  covered sequence is independently backed by the coordinator's DURABLE PER-SEQUENCE
  loss/classification evidence, WITH that journaled classification MATCHING the span's
  COMPLETE ONEOF BODY. All conjuncts are required.

A PubAcked span is NOT self-authorizing coverage, for TWO distinct reasons. A widened
`[1,3]` is byte-identical whether sequence 2 was lost or preserved, so the PubAck
alone would let an incorrectly-constructed merge authorize deleting a sequence that
survived. And a span can cover a sequence that genuinely WAS lost while carrying a
complete oneof body DIFFERENT from what the coordinator journaled -- say a PubAcked
ATTRIBUTED span over a sequence journaled `UNATTRIBUTABLE(BINDING_CORRUPT)`. Boolean
loss membership would authorize deleting the record and binding evidence needed to
prove that mismatch, so congruence must be checked BEFORE deletion, not after.

An fsynced destination record alone is insufficient: a copy that is durable but
not yet committed and sender-visible is indistinguishable, after a crash, from an
ambiguous allocated slot — so deleting the source would destroy the only intact
evidence for a slot the destination cannot yet serve.

Coverage SHALL be over ALLOCATED sequences, not committed slots. A markerless but
high-water-allocated sequence is exactly the slot restart classifies as ambiguous,
and it is not "committed" — so a predicate over committed slots alone is
satisfiable while such a sequence exists. Concretely: sequence 9 committed,
sequence 10 allocated and markerless; copying 9 satisfies a committed-only
predicate, the segment is deleted, and sequence 10 disappears with no manifest
entry and no evidence it ever existed.

The phase and delete INTENT SHALL be persisted before any destructive step, so a
crash mid-rollover resumes deterministically instead of re-deriving intent from
whatever survived.

Copying SHALL rebind attribution to the destination spool and sequence while
PRESERVING the verified source binding and the mapping, so the destination remains
provably descended from the same authenticated record rather than newly asserted.

Both recovery journal copies and the manifest page proofs SHALL be retained until a
durable `RecoveryResolvedV1` for that recovery. Journalling a manifest alone SHALL
NOT authorize deleting the source, because an unacknowledged manifest is not yet
proof that the loss was reportable.

#### Scenario: Deletion blocked without full coverage
- **WHEN** any sequence in `(durable_local_reclaim_watermark, sequence_high_water]`
  is neither committed and sender-visible at the destination, nor covered by a
  PubAcked frozen classification span that is ALSO backed by durable per-sequence
  loss evidence for that exact sequence WHOSE JOURNALED CLASSIFICATION MATCHES THE
  SPAN'S COMPLETE ONEOF BODY
- **THEN** the source segment SHALL NOT be deleted
- **AND** a PubAcked span alone SHALL NOT satisfy the proof, since a widened span
  cannot show whether an omitted sequence was lost or preserved

#### Scenario: A span whose body contradicts the journal blocks deletion
- **GIVEN** a sequence journaled `UNATTRIBUTABLE(BINDING_CORRUPT)`
- **WHEN** a PubAcked frozen span covers it carrying an ATTRIBUTED body, or an
  `UNATTRIBUTABLE` body with a different `reason`
- **THEN** the coverage relation SHALL NOT hold and the segment SHALL NOT be deleted
- **AND** loss MEMBERSHIP alone SHALL NOT authorize deletion, because deleting the
  record and binding evidence would destroy the proof that the bodies disagree

#### Scenario: Markerless allocated sequence blocks deletion
- **WHEN** a segment holds a committed sequence and a later allocated, markerless
  sequence
- **THEN** covering only the committed sequence SHALL NOT authorize deletion
- **AND** the allocated sequence SHALL appear in the coverage proof

#### Scenario: Durable-but-uncommitted destination does not authorize deletion
- **WHEN** a destination record is fsynced but its commit evidence does not yet
  cover wrapper, coordinates, rebound attribution, mapping, high-water, and
  directory metadata
- **THEN** the source segment SHALL NOT be deleted

#### Scenario: Intent persists before destruction
- **WHEN** rollover begins a destructive phase
- **THEN** the phase and delete intent SHALL already be durable
- **AND** a crash SHALL resume from that intent

#### Scenario: Rebinding preserves ancestry
- **WHEN** a record is copied to a new spool and sequence
- **THEN** its attribution SHALL be rebound to the destination
- **AND** the verified source binding and old->new mapping SHALL be preserved

#### Scenario: Proofs retained until resolved
- **WHEN** a manifest has been journalled but not resolved
- **THEN** both journal copies and the page proofs SHALL be retained
- **UNTIL** a durable `RecoveryResolvedV1` for that recovery

### Requirement: Recovery bounds hold for a whole generation
Recovery sizing SHALL be bounded for an entire recovery GENERATION, not only per
segment. Implementations SHALL either emit one bounded recovery manifest per
corrupt segment, or enforce a cumulative per-generation manifest budget; per
segment bounds alone do not prove a multi-segment recovery fits.

Known attribution SHALL NEVER be downgraded to `UNATTRIBUTABLE` because coarsening
or sizing failed. `UNATTRIBUTABLE` states that provenance could not be proven; using
it to shed bytes would forge that claim and silently discard evidence the spool
actually holds. Where bounds cannot be met with attribution retained, the recovery
SHALL be split across manifests rather than degraded.

Manifest byte ceilings SHALL be enforced against the EXACT RECEIVED page bytes. A
validator that re-marshals a decoded page measures its own canonical encoding, so
duplicate fields, non-minimal varints, and other non-canonical wire bloat evade the
physical ceiling while inflating what the receiver actually stored and forwarded.

The recovery reserve SHALL cover, concurrently for the bounded number of
simultaneous recoveries: a destination segment, the attribution sidecar, BOTH
journal copies, the manifest and tombstone pages, the old->new mapping, and
filesystem metadata overhead. Reserving for "one corrupt segment" understates every
other artifact recovery must durably write.

#### Scenario: Generation budget is enforced
- **WHEN** several segments in one generation are corrupt
- **THEN** either each SHALL produce its own bounded manifest, or a cumulative
  generation budget SHALL bound the total

#### Scenario: Sizing pressure never forges unattributable
- **WHEN** coarsening or sizing cannot fit a manifest with attribution retained
- **THEN** the recovery SHALL be split
- **AND** known attribution SHALL NOT be relabelled `UNATTRIBUTABLE`

#### Scenario: Byte ceiling measures received bytes
- **WHEN** a page arrives with duplicate fields or non-minimal encoding
- **THEN** the ceiling SHALL be applied to the exact received bytes
- **AND** SHALL NOT be applied to a re-marshalled canonical form

#### Scenario: Reserve covers every recovery artifact
- **WHEN** the recovery reserve is sized
- **THEN** it SHALL cover destination segment, attribution sidecar, both journal
  copies, manifest/tombstone pages, mapping, and filesystem metadata
- **FOR** the bounded number of concurrent recoveries

### Requirement: Coarsening preserves attribution truth
Coarsening MAY combine only CONTIGUOUS LOST intervals whose COMPLETE classification bodies are EQUAL, and SHALL NOT collapse unrelated assignments or runs into a single fabricated span, nor widen a span over any sequence that is not itself lost.

SAME KEY IS NOT SUFFICIENT; CONTIGUITY IN THE LOSS SET IS ALSO REQUIRED. A sequence
outside the span union is frozen upstream as NOT LOST, so merging across a gap
declares a preserved sequence lost. Same-key lost spans `[1,1]` and `[3,3]` with
sequence 2 successfully preserved SHALL NOT merge into `[1,3]`: the key did produce
sequence 2, so a "never produced" test permits the merge, but sequence 2 was not
LOST, and the widened span would falsely declare it so. That is not a cosmetic
over-report -- the widened span is PubAcked and can then participate in reclaim
coverage, so a merge across a gap can authorize reclaiming a sequence that was
preserved.

A merge is therefore permitted only when every sequence it swallows is independently
in the loss set -- in practice, immediately adjacent spans with no omitted sequence
between them.

EQUALITY IS OVER THE COMPLETE ONEOF BODY, not a loosely-named "attribution key". Two
spans MAY merge only if they set the SAME oneof member and every member field is
equal -- for ATTRIBUTED bodies the whole identity including the source identity or
its joint absence, and `range_sha256` on ACTIVE. `UNATTRIBUTABLE` bodies have NO
attribution key at all, so a key-based rule leaves their merge undefined and a
nil-key implementation would merge spans carrying DIFFERENT reasons, discarding
evidence about why each range could not be attributed. Two `UNATTRIBUTABLE` spans MAY
merge only when their `reason` is identical.

THE NO-GAP RULE IS A CONSTRUCTION-TIME REFUSAL, NOT A RECEIVER CHECK. A received page
`[1,3]` is byte-identical whether it was formed legally from lost `[1,1] + [2,3]` or
illegally from lost `[1,1] + [3,3]` with sequence 2 preserved; the wire carries no
commitment to the pre-coarsening loss set, so no receiver can infer the gap. The
coordinator SHALL refuse an illegal merge against its DURABLE PER-SEQUENCE loss and
classification evidence, and reclaim SHALL be authorized by that per-sequence
evidence rather than by the mere existence of a PubAcked widened span.

Where a span cannot be coarsened without merging spans whose COMPLETE
CLASSIFICATION BODIES differ in any member, OR without crossing a not-lost gap, the
manifest SHALL retain the separate intervals or split the recovery, never invent
coverage and never relabel proven attribution as unattributable.

#### Scenario: Adjacent intervals with equal complete bodies merge
- **GIVEN** lost spans `[1,1]` and `[2,2]` whose complete classification bodies are
  equal in EVERY member -- the same oneof member, the same identity including the
  source identity or its joint absence, the same `range_sha256` on ACTIVE, or the
  same `reason` on `UNATTRIBUTABLE` -- and no omitted sequence between them
- **WHEN** coarsening runs
- **THEN** it MAY emit the single interval `[1,2]` carrying that same body

#### Scenario: Equal-bodied intervals do not merge across a not-lost gap
- **GIVEN** lost spans `[1,1]` and `[3,3]` with EQUAL complete bodies, and sequence 2 absent from the
  loss union because it was preserved
- **WHEN** coarsening runs
- **THEN** the coordinator SHALL REFUSE the merge at construction, against its
  durable per-sequence evidence, and the two spans SHALL remain separate
- **AND** reclaim SHALL NOT treat a widened span as coverage on its own, because a
  received `[1,3]` cannot show whether sequence 2 was lost or preserved -- the
  per-sequence evidence, not the span, is what authorizes deletion

#### Scenario: Distinct complete bodies never merge
- **WHEN** adjacent lost intervals carry classification bodies that are not equal in
  every member -- a differing identity or `range_sha256` member, or two
  `UNATTRIBUTABLE` spans with different `reason` values
- **THEN** the coordinator SHALL REFUSE the merge at construction, against its
  journaled per-sequence classification evidence, and SHALL emit them as separate
  spans
- **AND** this SHALL NOT be stated as a receiver check: a merged `[1,2]` does not
  reveal whether its precursors carried one body or two, so the refusal is only
  enforceable where the precursor evidence still exists

### Requirement: Recovery ownership is separated by authority
Recovery responsibilities SHALL be owned as follows, and SHALL NOT be relocated
into a component that lacks the authority or the evidence:

- the SPOOL detects corruption and retains attribution and copy evidence;
- the agent RECOVERY COORDINATOR freezes, pages, hashes, and JOURNALS the manifest
  and tombstone;
- the SENDER transmits already-frozen committed recovery records and never authors
  them;
- the GATEWAY validates, stamps transport provenance, and publishes the bytes
  unchanged;
- the EVENTWRITER applies only a complete validated manifest.

The coordinator SHALL NOT be specified as SIGNING the manifest unless and until an
agent-signature ABI exists to sign with. Integrity within the agent is provided by
the journalled content-addressed chain; authenticity on the wire is provided by the
existing authenticated session and capability model.

#### Scenario: Sender does not author manifests
- **WHEN** a sender retries or crashes mid-transmission
- **THEN** the manifest and tombstone identity SHALL be unchanged
- **AND** SHALL remain exactly what the coordinator froze and journalled

#### Scenario: Gateway does not synthesize recovery
- **WHEN** the gateway receives a recovery record
- **THEN** it SHALL validate and publish the frozen bytes
- **AND** SHALL NOT construct, extend, or re-page the manifest

### Requirement: The assignment mapping's durable behaviour is replay-safe
The durable assignment mapping SHALL be replay-safe, repairable, and bounded, over the KEY frozen by the edge record v1 wire ABI change.

That change owns the mapping's KEY ONLY, because the attributed span omits execution
and plan identity on the strength of it. It does NOT own the tagged
positive/explicit-negative VALUE: no message there represents one, so claiming it was
frozen described prose rather than a contract. THIS change owns that value shape (see
the assignment-mapping value task) and everything the runtime must then do with it: storage,
replay, conflict repair, retention, collection, and the lookup-outcome transitions
a consumer acts on. Splitting it this way is deliberate -- freezing a state machine
alongside a wire contract is what made the predecessor change unreviewable.

CANDIDATE EVIDENCE and the SELECTED PROJECTION SHALL be distinct. The candidate
log is APPEND-ONLY and MAY hold more than one candidate under a key; the SELECTED
PROJECTION SHALL resolve to at most ONE value. Writing a differing second candidate
SHALL be an integrity CONFLICT that leaves the projection UNRESOLVED, never an
overwrite. "Exactly one value" always refers to the projection, never to the
evidence -- an earlier revision of this requirement used the phrase for both, which
cannot hold once conflicting candidates are retained.

The mapping SHALL be durably committed BEFORE the assignment or grant can produce
an accepted record. That ordering is what makes a definite absence meaningful.

It SHALL outlive spool recovery, redrive, and lifecycle GC for at least as long as
any manifest that can reference it. Collection SHALL be safety-based, never
time-based.

A write of the SAME value under an existing key SHALL be an idempotent NO-OP that
preserves the FIRST record; assignment and grant creation can be replayed, and a
replay is not a conflict.

A CONFLICT SHALL be resolved by an APPEND-ONLY conflict-resolution record that
SELECTS one candidate as the projection. The rejected candidate SHALL be retained
as evidence. Freezing the resolution record's OWN replay semantics and authority --
same-selection replay, a later record selecting the other candidate, a stale or
future resolver fence, and conflicting resolution records -- belongs to runtime task 2.20,
which implements the mapping; without it two append-only resolution records could
select A then B with no deterministic lookup. MISSING repair SHALL likewise require
evidence that a backfilled record is the ORIGINAL authoritative pre-accept mapping,
not merely a value that appeared later.

Lookup SHALL return one of SIX DISTINCT results, each with a defined consumer
transition:

- FOUND -- resolve and proceed.
- NOT_SCHEDULED -- an explicit, durably committed NEGATIVE mapping. Because the
  mapping is committed before any accepted record can exist, a lookup MISS is NOT
  this result: a definite missing entry is an INTEGRITY condition. Only a recorded
  negative means "there is no execution", and it is a terminal, resolvable answer.
- TEMPORARILY_UNAVAILABLE -- the recovery stays PENDING with NO terminal
  disposition and NO ACK, and it SHALL be retried. It SHALL NOT be downgraded to
  NOT_SCHEDULED.
- MISSING -- the durable action is to record an integrity audit entry, FENCE the
  affected generation against further reclamation, and leave the delivery PENDING
  with no terminal disposition. Retry SHALL be permitted only once a durably
  committed mapping (positive or negative) appears.
- CORRUPT or CONFLICTING -- the durable action is to record an integrity audit
  entry and QUARANTINE the affected slot; the delivery receives NO terminal ACK.
  Retry SHALL be permitted only once repair evidence resolves the PROJECTION to a
  single value: for CORRUPT, a re-read that verifies; for CONFLICTING, an
  authoritative resolution record selecting one candidate.

MISSING, CORRUPT, and CONFLICTING SHALL each BLOCK `RecoveryResolvedV1`. A recovery
SHALL NOT resolve over evidence it could not read or could not reconcile.

#### Scenario: A lookup miss is not a negative answer
- **WHEN** a lookup finds no entry for an accepted record's identity
- **THEN** the result SHALL be MISSING, an integrity condition
- **AND** SHALL NOT be reported as NOT_SCHEDULED

#### Scenario: Unavailability does not resolve a recovery
- **WHEN** a lookup is temporarily unavailable
- **THEN** the recovery SHALL remain pending with no terminal disposition or ACK

#### Scenario: Durable partial receipt does not imply completion
- **WHEN** an exact page or tombstone is committed to receipt storage but the
  complete manifest has not arrived
- **THEN** the consumer MAY acknowledge that durable receipt to free its bounded
  broker delivery window
- **AND** it SHALL NOT advance the source prefix or emit `RecoveryResolvedV1`
- **AND** the record that completes assembly SHALL remain unacknowledged when
  mapping lookup is unavailable or blocked

#### Scenario: Unreadable evidence blocks resolution
- **WHEN** a lookup is MISSING, CORRUPT, or CONFLICTING
- **THEN** `RecoveryResolvedV1` SHALL be blocked
- **AND** retry SHALL require the defined repair evidence

#### Scenario: A second differing value is a conflict
- **WHEN** a DIFFERING second value is written under an existing key
- **THEN** it SHALL be an integrity conflict, not an overwrite

#### Scenario: An identical replay is a no-op, positive or negative
- **WHEN** the SAME positive value, or the SAME explicit negative, is written again
  under an existing key
- **THEN** it SHALL be an idempotent no-op preserving the first record
- **AND** SHALL NOT be reported as a conflict

#### Scenario: Positive and negative under one key conflict
- **WHEN** a POSITIVE value and an EXPLICIT NEGATIVE exist under one key
- **THEN** it SHALL be an integrity conflict
- **AND** the projection SHALL remain unresolved until a resolution record selects
  one

#### Scenario: Conflict resolution preserves the rejected evidence
- **WHEN** a conflict is resolved
- **THEN** an append-only resolution record SHALL select one authoritative value
- **AND** the rejected value SHALL be retained as audit evidence
