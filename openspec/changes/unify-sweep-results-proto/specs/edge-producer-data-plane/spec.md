# edge-producer-data-plane Delta

## ADDED Requirements

> **BOUNDARY:** the wire-ABI requirements moved to the `freeze-edge-record-v1-abi`
> change, which owns the record/frame shapes, the identity and digest grammars, the
> classification-span freeze, the completion-disposition enum, the exact-received-byte
> rule, and the assignment-mapping KEY. The requirements below describe RUNTIME
> behaviour over that frozen contract. This change DEPENDS ON that one and MUST NOT
> restate or re-freeze anything it owns.

### Requirement: Durable edge producers use one agent-owned record sink
All durable edge producers SHALL use one agent-owned record sink. Built-in
collectors, Wasm plugins, native add-ons, and embedded agent-side integrations
SHALL submit persistent observations, telemetry, inventory,
findings, traces, events, and results through one agent-owned durable record
sink. Producers SHALL NOT construct edge transport frames, receive broker or
database credentials, choose NATS subjects/streams/partitions, stamp trusted
agent or network-scope provenance, select traffic class, or write CNPG directly.
The command/execution plane, coalescible ephemeral state plane, and blob/media
plane SHALL remain separate from this durable record plane.

The sink SHALL encode one authoritative producer-neutral `EdgeRecordV1` containing
the immutable semantic envelope and typed payload. Edge transport SHALL wrap
those bytes in a separate `EdgeDeliveryFrameV1` containing mutable spool/sequence coordinates and delivery proof. Gateway validation MAY decode the
bounded semantic record, but JetStream SHALL store the exact `EdgeRecordV1`
bytes produced by the sink; minimal NATS headers SHALL carry transport-only
publish controls. Recovery MAY replace delivery coordinates but SHALL NOT
change the semantic bytes, event identity, or digest.

#### Scenario: A plugin emits a durable finding
- **GIVEN** a plugin assignment grants an approved finding output contract
- **WHEN** the plugin submits a bounded finding
- **THEN** the agent-owned sink SHALL validate and durably spool it through the
  shared producer data plane
- **AND** the plugin SHALL receive no transport frame, subject, broker
  credential, or database destination

#### Scenario: A plugin emits runtime health
- **WHEN** a plugin reports a bounded coalescible health/status update that is
  explicitly classified ephemeral
- **THEN** the runtime MAY use the existing status path
- **AND** that update SHALL NOT be described as crash-safe durable telemetry

#### Scenario: A producer creates a large artifact
- **WHEN** a producer creates packet-capture, media, archive, or other opaque
  artifact bytes
- **THEN** those bytes SHALL use the separately authorized blob/media contract
- **AND** the record plane MAY carry only bounded immutable references and
  lifecycle/audit records

#### Scenario: A spool generation rolls over
- **GIVEN** an accepted semantic record must move to a replacement spool
- **WHEN** recovery assigns new delivery coordinates
- **THEN** only its `EdgeDeliveryFrameV1` coordinates and proof MAY change
- **AND** the exact `EdgeRecordV1` bytes later stored in JetStream SHALL remain
  identical to the bytes the sink originally encoded from the accepted producer
  submission

### Requirement: Record cost is calculated by trusted platform code
Producer-supplied cost, count, or expansion hints SHALL be non-authoritative.
For each contract, the immutable registry bundle SHALL contain a deterministic
platform-owned validator and cost-model version. Before spool acceptance, the
agent SHALL compute a conservative trusted row/write-byte charge from canonical
bytes or reserve the contract's fixed maximum. The gateway SHALL validate that
trusted charge against the active bundle and grant without treating opaque
caller fields as authority. After decode and before credit refund or side
effects, EventWriter SHALL recompute actual bounded cost with the same model.
Unknown models, arithmetic overflow, nondeterministic results, or actual cost
above the trusted bound SHALL fail before partial projection.

#### Scenario: A plugin underdeclares database cost
- **WHEN** a plugin claims one row but its approved payload deterministically
  expands to more rows or write bytes
- **THEN** the agent SHALL replace the claim with the trusted conservative charge
  or reject the record before local acceptance
- **AND** EventWriter SHALL independently detect any remaining mismatch before
  writing domain state

#### Scenario: EventWriter lacks the cost model
- **GIVEN** a record is otherwise valid under a contract bundle
- **WHEN** EventWriter cannot load the exact cost-model version
- **THEN** that deployment SHALL be not ready or paused for the contract
- **AND** the record SHALL NOT fall back to producer estimates or generic
  projection

### Requirement: Local acceptance transfers ownership crash-safely
A successful local producer receipt SHALL mean the exact record bytes the sink
emitted, approved contract and provenance, stable semantic identity, and producer
idempotency binding are committed to the common crash-safe agent spool. It SHALL
NOT mean gateway, JetStream, EventWriter, or database commit. A retryable
`WOULD_BLOCK`, cancellation with known no-commit, or permanent rejection SHALL
mean ownership was not transferred and the producer remains responsible.

The producer SHALL supply bounded UNCOMPRESSED contract-payload submission bytes;
the sink SHALL compute `submission_sha256` over those pre-compression bytes and
perform retry/receipt lookup BEFORE compressing or constructing `EdgeRecordV1`,
then, only on a journal miss, compress at most once with the contract-selected
codec (`NONE` performs no compression), hash the exact stored payload as
`payload_sha256`, and construct and spool the record. The sink SHALL atomically bind `(package digest,
producer assignment, host-issued run, output contract, producer idempotency key)`
to event ID, `submission_sha256`, and durable receipt with the spool append. It
SHALL retain this binding for the grant-declared retry horizon after spool
reclamation and until the run/epoch is durably closed and fenced, support receipt
lookup after an uncertain timeout, return the original receipt for the same key and
`submission_sha256`, and reject the same key presented with a DIFFERENT
`submission_sha256` as an integrity conflict. On a journal hit the sink SHALL
return the ORIGINAL durable artifact (its original `payload_sha256`/`record_sha256`)
without re-compressing or re-encoding; the original `payload_sha256`/`record_sha256`
are preserved (re-compression would change `payload_sha256`, and because the
semantic digest commits `payload_sha256`, would fabricate an `EVENT_ID_CONFLICT`
under the original event ID). The durable producer-key journal SHALL key ONLY on the
tuple `(package digest, producer assignment, host-issued run, output contract,
producer idempotency key)` and SHALL store and compare `submission_sha256` as an
immutably-compared value on that binding, never as a key component and never on the
post-compression payload or record digest. Once a binding is safely garbage-collected, a retry
against its closed run handle SHALL return an explicit `retry_horizon_expired`
result and SHALL NOT create a new semantic event under that key.

#### Scenario: Agent crashes after fsync but before replying
- **WHEN** a producer retries the same key after the agent durably appended the
  record but the success response was lost
- **THEN** receipt lookup or retry SHALL return the original event/receipt
  identity
- **AND** a second semantic record SHALL NOT be created

#### Scenario: Producer reuses a key for changed semantics
- **WHEN** one assignment/run/contract key is submitted with a different
  `submission_sha256`
- **THEN** the sink SHALL return a permanent integrity error
- **AND** the original durable binding SHALL remain immutable

#### Scenario: Producer retries after the receipt horizon
- **GIVEN** a run is durably closed and fenced and its receipt binding passed
  the declared safe-GC watermark
- **WHEN** a producer retries an old key on that run handle
- **THEN** the sink SHALL reject it as `retry_horizon_expired`
- **AND** it SHALL NOT allocate a new event ID or reopen the run

### Requirement: Producer pressure and fairness are bounded
Every grant SHALL bound record/frame/run bytes and counts, rate, concurrent
runs, pages, checkpoints, terminal attempts, outstanding spool bytes, retained
idempotency entries, and contract-specific expansion/write cost. The agent SHALL
run an approved bounded validator/cost engine before spooling or charge the
contract's fixed worst-case grant cost. Retryable pressure SHALL be distinct from
permanent size, schema, capability, revocation, and quota errors and SHALL expose
bounded retry-after or credit notification.

Byte-based fair scheduling SHALL include network scope, agent, producer
assignment, run/execution, and immutable traffic class. A producer SHALL NOT
promote itself, create a lane, consume the recovery floor, or monopolize another
producer. A source incapable of honoring backpressure SHALL be explicitly lossy
or loss-audited and SHALL NOT be advertised as durable.

#### Scenario: A huge inventory run shares an agent with an interactive check
- **WHEN** the inventory run exhausts its bulk credits or spool quota
- **THEN** it SHALL receive `WOULD_BLOCK` or admission deferral
- **AND** the interactive check and recovery lane SHALL continue within their
  reserved bounds

#### Scenario: A Wasm guest busy-loops on backpressure
- **WHEN** a guest repeatedly ignores `WOULD_BLOCK` or credit notification
- **THEN** the runtime SHALL pause, fuel-limit, or terminate that producer
- **AND** already accepted records and other producers' reserved capacity SHALL
  remain intact

### Requirement: Run and snapshot lifecycles are bounded and explicit
A finite producer run SHALL use host-issued start, independently useful data,
bounded checkpoint, and complete/partial/aborted terminal identities. A
perpetual producer SHALL rotate bounded epochs. RPC close, producer exit, or the
last received page SHALL NOT imply completion.

Atomic snapshot pages SHALL be staged immutably by assignment-authorized source
instance and scheduler-owned generation without current-state or absence side
effects. A terminal MAY wait pending until every declared page ordinal/hash and
object-key uniqueness check succeeds and its bounded ordered Merkle/checkpoint
root validates. Activation SHALL atomically fence older generations and swap the
source's current snapshot pointer. Conflicting pages/terminals, abort-after-
complete, and late older terminals SHALL NOT replace current state; abandoned
staging SHALL have bounded repair retention and garbage collection.

Absence/deletion SHALL require a complete terminal with an assignment-scoped
provider snapshot token/revision or contract-specific consistency proof and
exact coverage scope. Without that proof, the run SHALL be upsert-only.

#### Scenario: Terminal arrives before one page
- **WHEN** a snapshot terminal arrives before all pages named by its root
- **THEN** the terminal SHALL remain pending and current inventory SHALL remain
  unchanged
- **AND** activation MAY occur only after the missing page commits and the full
  root validates

#### Scenario: Provider changes during pagination
- **GIVEN** received pages are individually valid but no consistent provider
  snapshot token/revision or equivalent proof exists
- **WHEN** the run terminates successfully
- **THEN** its records MAY upsert observed objects
- **AND** it SHALL NOT infer absence or delete previously current objects

#### Scenario: A stale complete terminal arrives late
- **WHEN** an older generation completes after a newer generation became current
- **THEN** the older terminal SHALL NOT move the current pointer backward
- **AND** conflicting same-generation evidence SHALL be quarantined as an
  integrity failure

#### Scenario: Armis discovery emits provider pages
- **WHEN** the inbound Armis integration receives a bounded provider page
- **THEN** it SHALL emit a typed inventory page through the shared producer sink
  without whole-run JSON materialization or Core coalescing
- **AND** current inventory absence SHALL remain unchanged until a valid
  consistency-proven complete terminal activates the snapshot

#### Scenario: Armis northbound update is requested
- **WHEN** ServiceRadar must POST desired state to Armis
- **THEN** the HTTP side effect SHALL remain an idempotent command/job-plane
  action and SHALL NOT execute from EventWriter replay
- **AND** only bounded receipts, audit, progress, and telemetry MAY return
  through the durable record plane

### Requirement: Wasm and native adapters expose the common durability contract
The Wasm runtime SHALL expose a versioned binary host ABI and SDK for open,
publish, checkpoint, commit, abort, receipt lookup, and credit notification.
The bounded contract-payload (submission) bytes SHALL cross guest memory through
one bounded copy without protobuf-to-base64-to-JSON wrapping, and the guest SHALL
NOT see `EdgeRecordV1`, `EdgeDeliveryFrameV1`, spool coordinates, `record_sha256`,
or trusted routing/provenance fields.

Native add-ons SHALL use an assignment-authenticated bidirectional record relay
with byte/frame credits, host-issued session nonce, stale-session fencing,
resume watermark, and cumulative ACK only after common-spool fsync. An add-on
SHALL retain uncertain records and retry with stable producer keys. Durable
native telemetry and OTLP output SHALL migrate to this adapter; only explicitly
ephemeral runtime counters MAY remain on lossy queues.

#### Scenario: Wasm publish times out during group commit
- **WHEN** the host call times out or is cancelled while fsync outcome is
  uncertain
- **THEN** the guest SHALL retry or query with the same producer key
- **AND** the host SHALL return the original receipt if ownership transferred

#### Scenario: Native add-on reconnects after local ACK loss
- **WHEN** an add-on reconnects with an uncertain last record
- **THEN** it SHALL open a fresh fenced session and resume from the last durable
  watermark
- **AND** stable producer keys SHALL prevent record loss or duplicate domain
  side effects

### Requirement: Projection is platform-owned and replay-safe
EventWriter SHALL dispatch by exact trusted `(route profile, contract ID,
version, complete contract digest)` and use only a compiled platform projector or
an approved bounded declarative processor contribution. Packages SHALL NOT
execute BEAM/native/JavaScript code, SQL, DDL, or choose physical storage during
ingestion. Deterministic validation/projection failures SHALL use the durable DLQ
policy; deployment-not-ready versions SHALL pause rather than poison valid data.
EventWriter SHALL advertise readiness only after the exact validator, cost
engine, projector, database schema, route, and credit policy are installed. It
SHALL atomically select the control-plane active epoch, continue planned
retirement only with the pinned draining bundle, and hold security-revoked
records rather than reinterpreting them with another version.

Every contract SHALL define domain idempotency and authoritative-versus-derived
status. A producer grant SHALL prevent the same fact from being emitted
simultaneously as typed output, extension output, `MetricBatch`, OCSF,
`plugin_result` JSON, or a lossy copy unless one platform-owned idempotent
derivation is the sole owner of the secondary representation.

#### Scenario: Extension record selects a package subject and SQL table
- **WHEN** package metadata attempts to provide a subject filter, SQL, DDL,
  executable processor, or destination table
- **THEN** import or contract approval SHALL reject those transport/storage
  authorities
- **AND** no dynamic EventWriter subscription or database mutation path SHALL be
  created

#### Scenario: One authoritative record needs a compatibility metric
- **WHEN** an existing consumer cannot yet read the canonical contract
- **THEN** one platform-owned idempotent downstream normalizer MAY derive a
  bounded correlated metric
- **AND** the producer SHALL NOT emit both authoritative forms

### Requirement: Durable records become subscribable before CNPG persistence
Every persistent agent-originated record SHALL obtain an authoritative
JetStream PubAck through the authenticated gateway publisher before its agent
spool sequence is resolved, and CNPG projection SHALL occur only through
EventWriter. The gateway SHALL be the sole NATS publisher to the durable
edge-record subject for agent-originated records, while governed cluster-local
services publish only to their own mapped service-ingress subjects; this is
per-class publisher-subject isolation, NOT a global "only the gateway may publish"
rule. Agents, plugins, and add-ons SHALL receive no NATS credentials. A NATS
leaf MAY transport gateway publications, but the declared durability/RPO policy
SHALL state whether its PubAck is authoritative or hub replication must complete
first. The record
SHALL remain available to authorized real-time consumers before database
persistence. Fixed bounded record batches and manifests SHALL remain JetStream
stream records; oversize output SHALL be contract-paged, rejected, or
quarantined and SHALL NOT be silently diverted to Object Store.

#### Scenario: Native add-on metric is accepted
- **WHEN** the gateway obtains the authoritative PubAck for a canonical metric
  record
- **THEN** real-time consumers MAY subscribe concurrently with EventWriter
- **AND** no direct agent, add-on, gateway, or Core write SHALL bypass JetStream

#### Scenario: JetStream is unavailable
- **WHEN** the gateway cannot obtain an authoritative PubAck
- **THEN** it SHALL leave the spool sequence unresolved and the agent SHALL
  retain the frame
- **AND** local producer pressure SHALL eventually receive bounded admission or
  `WOULD_BLOCK` rather than acknowledged loss

#### Scenario: A site has a NATS leaf
- **GIVEN** a NATS leaf transports gateway publications toward the authoritative
  JetStream domain
- **WHEN** a plugin publishes a durable record through the common sink
- **THEN** the agent SHALL still relay it through the authenticated gateway
- **AND** the gateway SHALL resolve the spool sequence only after the deployment's
  configured authoritative PubAck boundary

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

### Requirement: Restart resolution is total over redundant commit evidence
Restart resolution SHALL be TOTAL over COMMIT EVIDENCE that is itself redundant
and corruption-independent, considering the record wrapper, the assigned sequence
high-water, the producer idempotency/receipt binding, and the attribution binding
together with the record bytes.

Commit evidence SHALL NOT be a single point of failure. It SHALL be stored with
redundancy independent of the record segment, so that losing ONE copy never
decides an outcome. Evidence SHALL NEVER be classified discardable merely because
its only marker copy became unreadable — that would convert a storage fault into
silent deletion of proof that data was acknowledged.

Every copy SHALL carry a monotonically increasing EVIDENCE GENERATION and a digest
over its own contents, so copies can be compared rather than merely read. Because
copies cannot be updated atomically with respect to each other, a crash between
writing copy A as COMMITTED and updating copy B leaves two READABLE copies in
DIFFERENT states, which unreadable-copy handling does not cover. Resolution SHALL
therefore be:

- all valid copies AGREE -> use the agreed state;
- any two valid copies DISAGREE -> AMBIGUOUS ALLOCATED SLOT, regardless of which
  copy carries the higher generation. A higher generation proves only that one
  write landed, not that the append was acknowledged, so preferring it would
  invent a commit the producer may never have been told about.

A producer receipt SHALL NOT be issued until ALL required evidence copies AND the
directory metadata that makes them discoverable are durable. Issuing earlier makes
the acknowledged/unacknowledged distinction unrecoverable by construction.

For every slot present after restart, exactly one outcome SHALL apply:

- commit evidence intact, attribution/wrapper/receipt binding valid, record bytes
  present and intact -> COMMITTED; the receipt stands and the sender MAY expose it.
- commit evidence intact, bindings verifying for the slot, the span REPRESENTABLE in
  the frozen identity, record bytes MISSING OR CORRUPT -> ATTRIBUTED LOSS;
  manifested as an attributed lost span.
- commit evidence intact and bindings VERIFYING for the slot, but the verified
  evidence NOT REPRESENTABLE in the frozen identity -> UNATTRIBUTABLE with reason
  `DISCRIMINATOR_UNREPRESENTABLE`. Attribution was proven and cannot be carried; the
  span SHALL NOT be emitted as attributed with a substituted or dropped
  discriminator.
- commit evidence intact but ATTRIBUTION, WRAPPER, or RECEIPT BINDING missing or
  unverifiable -> AMBIGUOUS ALLOCATED SLOT (below).
- commit evidence MISSING OR CORRUPT for a slot whose append may have been
  ACKNOWLEDGED — including a sequence high-water allocated with no marker, and a
  COMPLETE prepared record with no marker -> AMBIGUOUS ALLOCATED SLOT.
- no commit evidence, no high-water allocation, and no complete record ->
  DISCARDABLE PREPARATION; the append never became durable.

An AMBIGUOUS ALLOCATED SLOT SHALL enter rollover coverage rather than being
discarded or silently retained. It SHALL be classified ATTRIBUTED when its
attribution binding satisfies BOTH frozen predicates: `binding_verifies_for_slot`
under the relation frozen by the edge record v1 wire ABI change -- evaluated against
the surviving trusted slot/generation/namespace and commit/wrapper/receipt evidence,
NOT against the record bytes, so it still holds on the BYTE-UNAVAILABLE path this
requirement's positive restart case depends on -- AND `span_is_representable`. When
the binding verifies but the span is NOT representable, the slot SHALL be
UNATTRIBUTABLE with reason `DISCRIMINATOR_UNREPRESENTABLE`; when the binding does not
verify, UNATTRIBUTABLE with the reason its frozen precedence selects. A slot whose sequence was allocated cannot
simply vanish: the sequence is already reflected in the high-water, so an
unresolved slot permanently pins the cumulative prefix.

The sender SHALL expose COMMITTED entries only. The deciding scan SHALL be bounded
by the generation's segment count, and a quarantined or ambiguous sequence SHALL
NOT be reused.

#### Scenario: Committed slot with lost bytes is attributed loss
- **WHEN** restart finds intact commit evidence, a binding that VERIFIES FOR THIS
  SLOT, and a REPRESENTABLE span, but missing or corrupt record bytes
- **THEN** the slot SHALL be manifested as an ATTRIBUTED lost span

#### Scenario: Verified attribution that the frozen identity cannot carry
- **GIVEN** a slot whose binding VERIFIES FOR THIS SLOT
- **WHEN** the verified evidence differs in a discriminator the frozen span identity
  cannot express
- **THEN** the slot SHALL be UNATTRIBUTABLE with reason
  `DISCRIMINATOR_UNREPRESENTABLE`
- **AND** it SHALL NOT be emitted as an attributed span with the discriminator
  substituted or dropped, which would record attribution the wire cannot justify

#### Scenario: A single corrupt marker copy decides nothing
- **WHEN** one copy of a slot's commit evidence is unreadable
- **THEN** resolution SHALL use the redundant copy
- **AND** the slot SHALL NOT be classified discardable on that basis alone

#### Scenario: Disagreeing readable copies are ambiguous
- **WHEN** two valid evidence copies for one slot record different states
- **THEN** the slot SHALL be an AMBIGUOUS ALLOCATED SLOT
- **AND** the higher evidence generation SHALL NOT be taken as authoritative

#### Scenario: Receipt waits for all copies and directory metadata
- **WHEN** any required evidence copy or its directory metadata is not yet durable
- **THEN** the producer receipt SHALL NOT be issued

#### Scenario: Allocated high-water without a marker is ambiguous
- **WHEN** restart finds a sequence allocated in the high-water with no readable
  commit evidence
- **THEN** the slot SHALL enter rollover coverage as an AMBIGUOUS ALLOCATED SLOT
- **AND** SHALL be ATTRIBUTED only if its binding VERIFIES FOR THIS SLOT **and** the
  span is REPRESENTABLE; if it verifies but is not representable, UNATTRIBUTABLE with
  `DISCRIMINATOR_UNREPRESENTABLE`; otherwise UNATTRIBUTABLE with the reason its
  frozen precedence selects

#### Scenario: Complete prepared record without a marker is ambiguous
- **WHEN** restart finds a complete record whose commit evidence is absent
- **THEN** it SHALL be treated as an AMBIGUOUS ALLOCATED SLOT, not as preparation

#### Scenario: Committed marker with missing bindings is ambiguous
- **WHEN** commit evidence is intact but attribution, wrapper, or receipt binding
  is missing or unverifiable
- **THEN** the slot SHALL enter rollover coverage
- **AND** SHALL be ATTRIBUTED only if its attribution binding VERIFIES FOR THIS SLOT
  **and** the span is REPRESENTABLE
- **AND** a binding that verifies while the span is NOT representable SHALL be
  UNATTRIBUTABLE with `DISCRIMINATOR_UNREPRESENTABLE`, never attributed

#### Scenario: True preparation is discarded
- **WHEN** restart finds no commit evidence, no high-water allocation, and no
  complete record
- **THEN** the slot SHALL be discarded as preparation

#### Scenario: Sender never exposes non-committed state
- **WHEN** the sender selects entries to transmit
- **THEN** it SHALL transmit only committed entries

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

### Requirement: Reclamation follows durable outcome without starving recovery
A gateway PubAck or a remote resolved prefix SHALL NOT by itself reclaim local
spool bytes; reclamation SHALL follow the agent durably recording the terminal
outcome for the affected sequences, subject to the coverage proof above.

Recovery SHALL NOT deadlock against that rule. The reserve described above is
excluded from producer admission. When only recovery-critical work remains, the
spool SHALL admit recovery's own freeze/journal/copy writes against the reserve,
and SHALL refuse further producer appends rather than reclaim evidence that no
coverage proof yet accounts for.

#### Scenario: PubAck alone does not free bytes
- **WHEN** the gateway acknowledges a published prefix
- **THEN** the spool SHALL retain those bytes
- **UNTIL** the agent durably records the terminal outcome

#### Scenario: Recovery proceeds on a full spool
- **WHEN** the spool is at capacity and a corrupt segment requires a manifest
- **THEN** recovery SHALL proceed against the reserve
- **AND** producer appends SHALL be refused rather than recovery blocked

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

### Requirement: Output contract bundles have a governed deployment lifecycle
The deployment SHALL govern output-contract bundles through a signed lifecycle, and SHALL NOT let a partially deployed or stale epoch receive production.

The RECORD-SIDE reference -- contract ID/version, bundle digest, registry epoch,
registry-snapshot digest, effective-grant digest -- is frozen by the
edge record v1 wire ABI change. This requirement owns the registry and its
operation.

The deployment SHALL maintain a versioned output-contract registry shared by
assignment compilation, the agent sink, gateway readiness/routing, and
EventWriter. An immutable contract bundle SHALL bind contract ID/version,
encoding and schema canonicalization, unknown-field policy, bounded validator,
authoritative-field rules, deterministic domain identity and revision/merge
semantics, platform partition rule, cost model, projector engine/configuration,
retention/data classification, and error policy. Its exact digest and registry
epoch SHALL be bound into every accepted record and retained through the maximum
producer-retry, agent-offline, spool, JetStream replay, DLQ, and redrive horizon.

Package metadata MAY request approved outputs and declarative processor
contributions, but SHALL NOT choose subjects, streams, consumers, traffic class,
database tables/DDL, executable Core processors, or arbitrary subject filters.
A producer grant SHALL become ready only when agent, gateway, route map, and
required projector have compatible registry state.

Each bundle SHALL transition through signed `candidate`, `ready`, `active`,
`draining`, and `retired` states or the terminal `security-revoked` state. A
candidate SHALL become ready only after the target agent cohort, every
authoritative gateway route/map generation, and every required EventWriter
validator, cost engine, and projector attest the exact bundle digest. Assignment
compilation SHALL issue grants only for one atomically selected active epoch; a
partially deployed or stale epoch SHALL NOT receive new production. Planned
retirement SHALL stop new grants and permit only exact historical backlog to
drain to declared spool, JetStream, DLQ, redrive, and producer-receipt
watermarks. Security revocation SHALL stop both new production and backlog
delivery fail-closed until an approved safe replacement, redrive, or explicit
waiver exists. Registry history SHALL be garbage-collected only after all of its
declared horizons and correctness holds close.

#### Scenario: Package requests an unapproved output
- **WHEN** a package requests or submits a contract absent from its effective
  assignment grant
- **THEN** the agent SHALL reject it before local spool acceptance
- **AND** no fallback generic JSON, subject, or dynamic database projection
  SHALL be created

#### Scenario: Deployment components disagree on registry epoch
- **GIVEN** the agent can encode a contract but the gateway route or EventWriter
  projector is not ready for its exact bundle
- **WHEN** the scheduler evaluates a new producer assignment
- **THEN** the assignment SHALL remain not ready or paused
- **AND** the mismatch SHALL NOT be converted into a fleet-wide poison stream

#### Scenario: Candidate activation is only partially ready
- **GIVEN** an agent and gateway route report a candidate bundle ready
- **AND** one required EventWriter projector or route-map generation is not ready
- **WHEN** the control plane evaluates activation
- **THEN** the active registry epoch SHALL remain unchanged
- **AND** no assignment SHALL receive a grant for the candidate bundle

#### Scenario: A contract is retired normally
- **WHEN** a newer contract version replaces an old version without a security
  incident
- **THEN** new grants SHALL use the new bundle while immutable old backlog MAY
  drain through the pinned historical bundle
- **AND** the historical bundle SHALL remain resolvable until all supported
  retry/replay/redrive horizons close

#### Scenario: A contract is revoked for compromise
- **WHEN** a contract, package, validator, or projector is security-revoked
- **THEN** new production and delivery of matching records SHALL stop fail-closed
- **AND** matching backlog SHALL be held or quarantined until an operator
  authorizes a fixed safe bundle, redrive, or explicit waiver

#### Scenario: A stale component resumes after activation
- **WHEN** a gateway, agent, or EventWriter instance resumes with an epoch older
  than the active or explicitly draining set
- **THEN** it SHALL be fenced from new production and authoritative projection
- **AND** it SHALL NOT roll the deployment backward or reinterpret records under
  its local latest-known bundle

### Requirement: Producer provenance is host-attested and enforced at runtime
The trusted agent sink and EventWriter SHALL enforce the authoritative provenance fields the wire contract defines.

The field set, its authority, and the rule that caller-selected identifiers create
no namespace are frozen by the edge record v1 wire ABI change. This requirement
owns the ENFORCEMENT: the trusted agent sink SHALL derive or verify those fields
from host-issued handles, the effective grant, and control-plane-signed
capabilities, and EventWriter SHALL compare or replace body-level agent, package,
source, network scope, assignment/run, target/range, and traffic-class claims
using the trusted envelope/grant BEFORE side effects.

#### Scenario: A plugin claims another network scope and lower cost
- **WHEN** a plugin body or submission metadata claims another scope, route,
  traffic class, partition, or artificially low projected cost
- **THEN** the agent SHALL ignore/replace non-authoritative metadata or reject
  the record before spool acceptance
- **AND** EventWriter SHALL independently recompute the approved cost and
  validate decoded authoritative fields before projection

#### Scenario: A scanner output lacks scan authority
- **GIVEN** a package has permission to emit a scan-result contract but no valid
  target/range collection capability
- **WHEN** it attempts to report or initiate a scan
- **THEN** output permission SHALL NOT authorize the probe or make the target
  claims authoritative
- **AND** the record SHALL be rejected or retained as non-authoritative audit
  according to the approved contract

### Requirement: Governed service ingress is operated by the service publisher
The governed service publisher, not the gateway or EventWriter, SHALL own publication-slot durability, and the control plane SHALL isolate publisher credentials per service.

The `service_slot` tuple, its validity rules, the fresh-only scope, and the three
service transport transcripts are frozen by the edge record v1 wire ABI change.
This requirement owns their operation.

The publisher SHALL ALLOCATE `publication_lane_id` ONCE, durably, before the lane's
first publication, and SHALL keep it stable for that lane's life. A retry, timeout,
or restart of a not-yet-acknowledged publication SHALL REUSE the same
`(publication_lane_id, publication_sequence)`, so a lost-ACK redelivery presents the
exact same `service_slot` and `record_sha256`. The shape and validity of those two
fields are frozen upstream; this requirement owns WHEN they are allocated, reused,
and journaled.

The governed service publisher (or its transactional journal/outbox) -- NOT the gateway or
EventWriter -- SHALL OWN publication-slot durability. For EACH record it SHALL, BEFORE publishing,
ATOMICALLY ALLOCATE the NEXT `publication_sequence` and JOURNAL LOCALLY the `service_slot`, the
exact pending record bytes, and the immutable route/header state. Sequence allocation is NOT gated
on acknowledgement: the publisher MAY have multiple outstanding un-acknowledged sequences
(pipelined), and a validated JetStream PubAck only RESOLVES/RECLAIMS its journaled slot -- it is
never a precondition for allocating the next sequence. A retry/timeout/restart of an
un-acknowledged publication SHALL republish the SAME journaled bytes on the SAME
`(publication_lane_id, publication_sequence)`, so a lost-ACK redelivery deduplicates.
`publication_sequence` SHALL NEVER wrap: on approaching its maximum the publisher SHALL SEAL the
current lane and DRAIN its outstanding journaled work while allocating NEW work on a fresh UUIDv7
`publication_lane_id` starting `publication_sequence` at 1.

Provenance trust for both the agent path and the service-ingress path SHALL be
per-class publisher-subject isolation, NOT a global "only the gateway" rule: ONLY
the authenticated gateway MAY publish to the durable edge-record subject, and ONLY
an authorized governed service MAY publish to its own service-ingress subject, each
over its own isolated publisher credential. A governed service publishes its own
service-stamped provenance to its service-ingress subject; the agent path publishes
gateway-stamped provenance to the edge-record subject.

The control plane SHALL maintain an immutable governed mapping from each
`authenticated_service_id` to exactly one service-ingress subject and publisher
credential. A governed service MAY publish ONLY to its mapped subject over its mapped
credential, and EventWriter SHALL derive the `authenticated_service_id` from the
publish subject and authenticated publisher credential, NEVER from caller-supplied
body or header text. A publish outside a service's mapped subject/credential SHALL be
rejected before projection.

The service-ingress path SHALL STAMP the service variants of the three transport
transcripts -- the `Nats-Msg-Id`, `Sr-Edge-Delivery-Id`, and
`Sr-Edge-Transport-Provenance` service grammars frozen in Appendix A of the edge
record v1 wire ABI change -- computing them over this publication's `service_slot`
rather than agent spool coordinates. Their domain tags, field order, slot-kind
discriminant, and delivery-proof presence rule are NOT restated here. Because
governed publishers emit FRESH records only, the publisher SHALL stamp no
`delivery_proof_digest`, and a receiver SHALL NOT treat its absence as poison.

Service-ingress DELIVERY grants -- renewal, rollover, or late-drain of a service
record -- are OUT OF SCOPE for v1. Governed service publishers SHALL emit FRESH
records only, and their transport provenance SHALL carry no `delivery_proof_digest`.
Late-delivery or recovery of a service-ingress record SHALL require a future version.

A transactional outbox MAY be used only when
the record's system of record is the same operational transaction; metrics and
telemetry SHALL remain JetStream-first.

#### Scenario: Cluster-local telemetry producer publishes a metric
- **WHEN** a cluster service emits persistent telemetry
- **THEN** its service-attested publisher SHALL place the authoritative record in
  JetStream before EventWriter projection
- **AND** it SHALL NOT use an operational database outbox as a database-first
  telemetry path or impersonate an edge agent

#### Scenario: A governed service claims another service identity
- **GIVEN** the control plane maps an `authenticated_service_id` to exactly one
  service-ingress subject and publisher credential
- **WHEN** a caller presents body or header text claiming a different
  `authenticated_service_id` than its authenticated publisher subject/credential
  resolves to
- **THEN** EventWriter SHALL compare, BYTE-FOR-BYTE, the authenticated publisher
  subject/credential identity, the `Sr-Edge-Transport-Provenance` principal, the
  publication-ID principal committed in `Nats-Msg-Id` / `Sr-Edge-Delivery-Id`, and the
  record principal (`producer_context.origin_principal_id`), and SHALL fail closed on ANY
  disagreement -- it MUST NOT silently derive from, override, or ignore a mismatched claim
- **AND** a publish outside the service's mapped subject/credential SHALL be rejected
  before projection

#### Scenario: A service-ingress producer attempts a late delivery
- **GIVEN** service-ingress delivery grants are out of scope for v1 and governed
  services emit fresh records only
- **WHEN** a governed service publisher attempts a renewal, rollover, or late-drain of
  a service record carrying a `delivery_proof_digest`
- **THEN** the deployment SHALL reject it because service-ingress late-delivery
  requires a future version
- **AND** a fresh service record whose provenance carries no `delivery_proof_digest`
  SHALL remain valid

### Requirement: The record's exact bytes are preserved end to end
Every component on the delivery path SHALL preserve a record's EXACT bytes, so that `record_sha256` remains verifiable at every hop.

The four identities and their digests are frozen by the
edge record v1 wire ABI change. This requirement owns the obligation that makes
`record_sha256` useful in operation: the spool, sender, gateway, JetStream, and
record DLQ SHALL preserve those exact bytes, and the gateway and EventWriter SHALL
decode and hash them rather than re-encoding.

The binding record SHALL be stored corruption-independently of `record_bytes`:
independently checksummed, separately addressable, and readable when the record
segment is unreadable. Dictionary or RLE encoding per segment is permitted
provided the checksum covers the encoded form and decoding does not depend on any
record payload.

#### Scenario: A hop re-encodes a record
- **WHEN** any component re-encodes a record rather than forwarding its exact bytes
- **THEN** `record_sha256` SHALL no longer verify and the record SHALL be rejected
- **AND** the re-encoding component SHALL NOT substitute its own digest

#### Scenario: Attribution survives a corrupt record segment
- **WHEN** a record segment is corrupt or unreadable
- **THEN** its attribution binding SHALL remain readable and checksum-verifiable
- **AND** decoding that binding SHALL NOT depend on any record payload

### Requirement: Finite routing survives contract and credit pressure
The deployment SHALL keep the route map finite and the lanes independently pooled under pressure, so that neither contract count nor a blocked lane degrades the others.

The finite route-profile and traffic-class enums are frozen by the edge record v1
wire ABI. This requirement owns their operational consequences: lane, subject,
physical stream, connection, consumer, process, and RAFT-group cardinality SHALL
NOT grow with payload kind, package, plugin, integration, or output-contract count.
V1 SHALL begin with disjoint bulk/interactive physical streams; another profile
requires an explicit benchmarked platform change.

#### Scenario: A package defines many output contracts
- **WHEN** thousands of approved contracts share the durable record plane
- **THEN** the trusted binary contract envelope SHALL dispatch them over the
  finite route map
- **AND** the deployment SHALL NOT create thousands of lanes, subjects, streams,
  consumers, connections, processes, or RAFT groups

#### Scenario: Bulk transport is blocked
- **WHEN** a bulk lane exhausts its HTTP/2, publisher, stream, or database credits
- **THEN** separately pooled interactive and recovery lanes SHALL continue
- **AND** no unresolved bulk sequence SHALL be skipped or promoted

### Requirement: Authorization decisions are evaluated, cached, and routed at runtime
The runtime SHALL evaluate the four authorization decisions in a fixed order, cache capability grants under a fence, and route each typed outcome to its destination.

The four DIMENSIONS are frozen by the edge record v1 wire ABI, and so are the
values actually carried on the wire: the generated `EdgeSourceAuthorizationKind`
members, the generated `EdgeRecordDispositionKind` members, and the `DeliveryMode`
constants. It also freezes the invariant that projection is a decision separate
from publication and that a publication accept does not imply an authoritative
projection.

Everything else in the four dimensions is owned HERE, with its meaning:

- the PROJECTION outcome set -- `authoritative_apply`, `ledger_only`,
  `conflict_quarantine`;
- the HISTORICAL-PROOF outcomes -- `valid`, `invalid`, `historically_revoked`,
  `unavailable` -- which are key/trust RESOLVER verdicts computed at evaluation
  time, not wire members;
- the INTERNAL publication subtypes and which generated disposition member each
  maps onto.

This requirement is complete on its own and owns everything about applying all
four.

ORDER IS FIXED, AND SO IS OWNERSHIP. The four decisions SHALL be evaluated
COLLECTIVELY in the order the authorization matrix defines, and SHALL NOT be
reordered -- but each stage is evaluated by the component that owns it, and neither
component SHALL be required to evaluate a decision it cannot own. The GATEWAY stage
runs first and ends at PubAck: envelope-level checks only, with no decoded body.
EVENTWRITER owns everything after PubAck: the authoritative body checks and the
projection decision. The two per-component matrices in this change's design fix the
behaviour of each. EventWriter
SHALL RECOMPUTE and verify `semantic_envelope_sha256` before that digest is ever
used as a ledger replay key; it SHALL immutably bind the `edge_slot`/`service_slot`
to `record_sha256` before any terminal projection-fence decision; and it SHALL
resolve the historical collection proof to exactly one of `valid`, `invalid`,
`historically_revoked`, or `unavailable` for EVERY record -- so a
compromise-revoked signing key resolves to `historically_revoked` and is REACHABLE,
never silently downgraded to `authoritative_apply`.

EVALUATION IS TWO-STAGE for the historical proof. The GATEWAY stage is
ENVELOPE-level only and SHALL NOT require decoded body fields: the signed
capability SHALL be valid -- not-before and expiry plus attested-clock tolerance --
over the record's UUIDv7 identity-time interval, which is present on the envelope
before any payload decode. The EVENTWRITER stage validates the authoritative BODY:
the record body's observation/event time(s) SHALL lie within the signed collection
interval, and the UUIDv7 identity time SHALL be validated to lie within that same
interval as an integrity and ordering check, and SHALL NOT substitute for the body
observation window.

GRANT CACHING IS LIMITED TO THE RECORD-INDEPENDENT PART. Only the
signature/key/trust-chain validation -- the capability validly signed by a trusted,
non-revoked key at the trust-policy epoch -- is a reusable grant, and it MAY be
cached by capability digest plus trust-policy epoch. A cached grant SHALL NOT be
served once its fence has advanced; any cache key SHALL cover the fence.

Every RECORD-DEPENDENT check SHALL be re-evaluated per record and SHALL NOT be
satisfied by a cached grant: the not-before/expiry window against THAT record's
identity time, the body observation window against the signed collection interval,
and the scope/context binding. A cache hit means "this capability was validly
signed", never "this record is authorized". Caching the composite decision would
authorize a record whose identity time falls outside the very capability that was
cached for an earlier one -- an expired capability that keeps admitting records for
as long as the entry lives.

ROUTING, PUBACK, AND SPOOL RESOLUTION per outcome are specified by the
authorization matrix in this change's design, which SHALL specify, per outcome, the
PubAck behaviour, the destination stream/DLQ, whether the agent may resolve its
spool entry, whether domain projection is permitted, and which component owns each
current-fence lookup.

#### Scenario: The gateway stage does not decode the body
- **WHEN** the gateway evaluates the historical proof
- **THEN** it SHALL use only envelope-level fields
- **AND** SHALL NOT require a decoded body

#### Scenario: A cached grant is not served past its fence
- **WHEN** a cached capability grant's fence has advanced
- **THEN** it SHALL NOT be served from cache
- **AND** any cache key SHALL cover the fence

#### Scenario: A cached grant does not authorize a record outside the capability window
- **GIVEN** a capability whose signature validated for an earlier record, leaving a
  cached grant
- **WHEN** a later record's identity time falls outside that capability's
  not-before/expiry window
- **THEN** the cache hit SHALL satisfy only the signature/key/trust-chain check
- **AND** the window check SHALL be re-evaluated against this record and reject it,
  rather than the cached grant standing in for the whole decision

#### Scenario: Stale-fence historical delivery under a valid delivery grant
- **GIVEN** a correctly signed record whose producer authority epoch is below the
  gateway's active fence
- **WHEN** it is delivered under an exact, currently-valid delivery capability
- **THEN** the gateway SHALL return `audit_publication` with delivery
  mode `late_fenced_delivery`, and EventWriter SHALL project it
  `ledger_only`
- **AND** it SHALL NOT be `permanent_rejection` merely for the stale epoch, nor
  `authoritative_apply`

#### Scenario: A normally rotated signing key validates historical records
- **GIVEN** a production capability signed by a key rotated out of active issuance
  but not revoked for compromise
- **WHEN** its historical collection proof is evaluated for a record signed within
  that key's validity window
- **THEN** the proof SHALL be `valid` using retained key history
- **AND** a key retired specifically for compromise SHALL instead yield
  `historically_revoked`

#### Scenario: A retryable rejection does not advance the resolved watermark
- **GIVEN** the gateway returns `retryable_rejection` for a delivery-frame lane
  sequence
- **WHEN** the agent records the disposition
- **THEN** the delivery-ACK wire enum SHALL carry a retryable outcome distinct from
  an accept or a permanent reject
- **AND** the resolved delivery sequence SHALL NOT advance and the agent SHALL
  retain the frame for retry
