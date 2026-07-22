# edge-producer-data-plane Delta

## ADDED Requirements

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

### Requirement: Output contracts are approved as complete immutable bundles
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

### Requirement: Producer provenance and authority are host-attested
Trusted producer provenance and authority SHALL be host-attested. Producer
instance, package digest, assignment, run, source/coverage scope,
network scope, agent identity, route profile, traffic class, and cost metadata
SHALL be derived or verified by the trusted agent sink from host-issued handles,
the effective grant, and control-plane-signed capabilities. Caller-selected
identifiers SHALL NOT create identity, capability, routing, or quota namespaces.
Output permission SHALL NOT grant network scanning, raw-socket, filesystem, HTTP,
credential, command, or target access; those capabilities SHALL be authorized
separately by the command/assignment plane.

Carrier provenance SHALL NOT make opaque payload claims authoritative.
EventWriter SHALL compare or replace body-level agent, package, source, network
scope, assignment/run, target/range, and traffic-class claims using the trusted
envelope/grant before side effects.

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

### Requirement: Edge record identity is physical, semantic, and domain
An edge record SHALL carry four deliberately-separate identities, and byte-for-byte
equality of two records SHALL NOT be a protocol invariant. These four identities
SHALL be PIPELINE-stage identities, NOT four fields of one `EdgeRecordV1`:
`submission_sha256` is journal-local (producer -> sink, never placed on the wire);
`record_sha256` belongs to the delivery frame/slot (`EdgeDeliveryFrameV1`); and
`semantic_envelope_sha256` together with `event_id` are carried on `EdgeRecordV1`.

- `submission_sha256` is the PRODUCER-RECEIPT identity: the SHA-256 of the
  producer's bounded UNCOMPRESSED contract-payload submission bytes, computed at
  submission BEFORE the sink compresses or constructs `EdgeRecordV1`. It is the
  producer idempotency / retry-lookup COMPARISON value (the journal keys on the 5-tuple, never on this digest) and SHALL NOT be a transport-slot key,
  the semantic digest (which carries sink-assigned fields), or `payload_sha256`
  (post-compression).
- `record_sha256` is the PHYSICAL artifact identity: the SHA-256 of the exact
  record bytes the trusted sink emitted in its single encode. It proves those exact
  bytes survived spool -> gRPC -> gateway -> JetStream -> DLQ unchanged, and binds
  the durable delivery slot and signed delivery grant via
  `edge_slot (network_scope_id, authenticated_agent_id, spool_id, sequence) -> record_sha256` (the authenticated agent owns the slot key; the producer is stored provenance, not a key). It SHALL
  NOT determine semantic idempotency or projection conflict. Two compliant encoders
  (e.g. Go and Elixir) or two protobuf-runtime versions MAY emit different bytes for
  the same semantics; no component SHALL require, assert, or enforce a unique byte
  encoding of a record.
- `semantic_envelope_sha256` is the runtime-neutral SEMANTIC identity: a SHA-256
  over an explicit, versioned, domain-separated, field-by-field signing-byte
  transcript covering every semantic/trust field and committing `payload_sha256`,
  excluding the digest field itself and all delivery state. Protobuf serialization
  output SHALL NOT appear in this preimage at any nesting depth. The transcript
  preimage SHALL begin with the `u64` grammar-version constant
  (`semanticDigestVersion = 3`, a committed constant fixed one-to-one by the
  immutable record-schema/proto ABI -- NOT a wire field, and the semantic-envelope
  digest carries NO string domain tag), then emit each semantic/trust field in a
  FIXED order (no per-field numeric tags): unsigned integers and enums as 8-byte
  big-endian; every bytes or string field length-prefixed by an 8-byte big-endian
  length; a 1-byte presence marker before each optional field; a `u64` (8-byte
  big-endian) discriminant equal to the set member field number before each oneof
  value; repeated fields in their defined order preceded by an 8-byte big-endian
  (`u64`) element count; and nested messages recursively framed field-by-field by
  these same rules.
- `event_id` (a UUIDv7 allocated once before durable spooling) participates in two
  distinct identities: with `network_scope_id` it forms the logical EVENT identity
  `(network_scope_id, event_id)` that keys the ingest ledger for idempotency and
  conflict, while the contract-defined DOMAIN keys are the SEPARATE merge/projection
  keys and SHALL NOT be folded into the event-ledger identity.

`payload_sha256` SHALL be the SHA-256 of the exact encoded/compressed payload
bytes. Because `semantic_envelope_sha256` commits the exact `payload_sha256`,
payload re-encoding necessarily changes the semantic digest; v1 therefore tolerates
re-encoding of the outer `EdgeRecordV1` but NOT of the payload. Payload-level
re-encode tolerance is OUT OF SCOPE for v1 and SHALL require a future record/digest
version; v1 SHALL NOT provide a contract-specific semantic payload digest escape
hatch.

The semantic-digest transcript version is a committed grammar CONSTANT
(`semanticDigestVersion = 3`), fixed one-to-one by the immutable record-schema/proto
ABI version -- it is NOT a wire field -- and is committed as the leading `u64` of the
hashed preimage (the semantic-envelope digest carries NO string domain tag). It SHALL
be validated fail-closed; an unknown ABI/grammar version SHALL be rejected WITHOUT
trial-hashing alternative grammars. Capability-signing and plan/recovery/completion
hash grammars SHALL each declare their OWN explicit version (not necessarily equal
numerics) and SHALL each commit that version, preceded by a per-grammar string
domain-separation tag, as the leading bytes of their preimage. Every grammar SHALL be
byte-frozen with a FIXED field order (no per-field numeric tags), 8-byte big-endian
integers and enums, 8-byte big-endian length prefixes on bytes/string fields, 1-byte
presence markers, `u64` (8-byte big-endian) oneof discriminants, `u64` element counts
for repeated fields, and recursive field-by-field nested framing; no protobuf
serialization output SHALL appear in any preimage.

A receiver SHALL NOT establish semantic identity, equivalence, authorization,
idempotency, conflict status, or wire validity by decoding protobuf and comparing
it against a re-encoding. Exact encoded record and payload bytes MAY be hashed as
explicitly-designated physical artifacts. The trusted sink SHALL serialize each
record exactly once; the spool, sender, gateway, JetStream, and record DLQ SHALL
preserve those exact bytes; the gateway and EventWriter SHALL decode and hash them
but SHALL NOT normalize, reorder, or re-encode them, and SHALL NOT perform a
decode -> re-encode -> byte-compare admission. `Deterministic` protobuf marshalling
MAY be a local reproducibility optimization at the sink but SHALL NOT be a protocol
invariant.

#### Scenario: The same record arrives with a different byte layout
- **WHEN** a record is re-encoded (e.g. by a different-language sink/encoder or a
  runtime upgrade) so its `record_sha256` differs but its
  `semantic_envelope_sha256` and `payload_sha256` are unchanged, and it arrives via
  a DIFFERENT valid physical delivery slot (a distinct spool) rather than by
  reusing the original slot
- **THEN** consumers SHALL treat it as the same record (a replay), never as poison
- **AND** no component SHALL reject it for failing a byte-uniqueness or
  decode-re-encode-compare check
- **AND** the same re-encoded bytes presented on the SAME slot with a different
  `record_sha256` SHALL instead be a transport-integrity violation, not a replay

#### Scenario: A delivery slot is reused with different bytes
- **WHEN** the same `edge_slot` (`network_scope_id`, `authenticated_agent_id`, `spool_id`, `sequence`) slot
  presents a different `record_sha256` than the one bound to it
- **THEN** it SHALL be rejected as a transport-integrity violation, independently of
  any domain-ledger replay/conflict decision
- **AND** because `Nats-Msg-Id` binds `record_sha256`, such a frame SHALL receive a
  distinct publication ID and SHALL NOT be removed by broker deduplication before
  this rejection can occur

#### Scenario: A record declares an unknown digest grammar version
- **WHEN** the record-schema/proto ABI version that fixes the semantic-digest grammar
  (or the version of any signing/hash grammar it carries) is not a known version
- **THEN** the receiver SHALL reject it fail-closed
- **AND** it SHALL NOT trial-hash the record under other grammar versions to find a
  match

### Requirement: Record authorization is four separate decisions
Record authorization SHALL be evaluated as four distinct decisions and SHALL NOT be
collapsed into a single boolean result. A signature-verification helper MAY exist,
but its boolean SHALL NOT be the only authorization result; publication and
projection SHALL return typed dispositions.

1. HISTORICAL COLLECTION/PROVENANCE PROOF -- whether the production/source
   capability was valid over the signed collection interval. This proof is
   evaluated in two stages by two components, and the GATEWAY stage SHALL NOT
   require decoded body fields. The gateway stage is ENVELOPE-level only: the
   signed capability SHALL be valid (not-before and expiry plus attested-clock
   tolerance) over the record's UUIDv7 identity-time interval, which is present on
   the envelope before any payload decode. The EVENTWRITER stage validates the
   authoritative BODY: the record body's observation/event time(s) SHALL lie within
   the signed collection interval, and the UUIDv7 identity time SHALL be validated
   to lie within that same interval as an integrity and ordering check and SHALL NOT
   substitute for the body observation window. Result
   SHALL be one of `valid`, `invalid`, `historically_revoked`, or `unavailable`. Normal key expiry/rotation SHALL be
   distinguished from compromise revocation: historical verification SHALL use
   retained key history so a normally-rotated key still validates records signed in
   its window, whereas compromise revocation MAY deliberately invalidate historical
   trust for the affected key. ONLY the signature/key/trust-chain validation (the
   capability validly signed by a trusted, non-revoked key at the trust-policy
   epoch) is a reusable grant and MAY be cached by capability digest plus
   trust-policy epoch. The record-specific checks -- the body observation/event
   time lying within the signed collection interval, UUIDv7 identity-time
   consistency, and the body-to-claim joins -- SHALL ALWAYS be evaluated per record
   and SHALL NOT be served from that cache (equivalently, any cache key covering
   them MUST include the normalized record interval plus semantic identity). A
   delivery-only renewal SHALL NOT change or relax it.
2. GATEWAY PUBLICATION / LATE-DELIVERY AUTHORITY -- whether these exact bytes are
   admitted onto the durable stream now (raw size, wire hygiene, envelope-to-grant
   match, present fence; late drain consumes the delivery capability). Result SHALL
   be one of `primary_publication`, `audit_publication` (valid historical, stale
   fence), `quarantine_publication` (admitted poison), `security_quarantine_publication`
   (a COMPROMISE-revoked signing key -- a distinct SECURITY variant of quarantine: the
   `ACCEPTED_QUARANTINE` disposition routed to the security-quarantine DLQ, reachable and
   grant-free, projected ledger_only), `retryable_rejection`, or
   `permanent_rejection`. An OVERSIZE frame or record (raw length exceeding its hard
   byte bound, rejected before decode) and an envelope-to-grant MISMATCH SHALL each
   be `permanent_rejection`, NOT `quarantine_publication`; `quarantine_publication`
   is reserved for admitted WIRE-HYGIENE poison at a trustworthy slot (a group /
   unknown-field / malformed-wire the gateway detects after bounded decode), whereas
   DECODED semantic or protocol invalidity (an invalid signature/structure, an
   envelope-to-grant mismatch, or a decoded-but-invalid value such as a negative or
   unknown enum), an unauthorized capability, or oversize input is permanently
   rejected. The delivery-ACK wire
   enum SHALL represent each of these DISPOSITION classes distinctly.
   `security_quarantine_publication` (a compromise-revoked key) is NOT a distinct wire
   enum value: it is a gateway-INTERNAL publication subtype that maps to the
   `ACCEPTED_QUARANTINE` wire disposition, distinguished only by its internal destination
   (the security-quarantine DLQ + ledger_only projection), so the wire enum stays the set
   of disposition classes. A retryable rejection SHALL leave the delivery sequence
   unresolved with no advancing disposition, and an `audit_publication` or
   `quarantine_publication` SHALL be neither an authoritative accept nor a
   permanent reject on the wire.
3. DELIVERY MODE/REASON -- `fresh`, `renewal`, `rollover`, or
   `late_fenced_delivery`. A producer epoch below the active fence, delivered under
   a valid delivery grant, is a `late_fenced_delivery` (a "stale-fence historical
   delivery"); it is only a replay if the event ledger independently finds an
   existing event.
4. EVENTWRITER PROJECTION FENCE -- `authoritative_apply`, `ledger_only`, or
   `conflict_quarantine`. A producer epoch below the active fence SHALL yield an
   explicit `ledger_only` disposition, not a rejection, and SHALL NOT
   authoritatively project. A post-PubAck compromise revocation of the signing key
   SHALL yield a `ledger_only` audit row plus a PubAck of the affected record to the
   security-quarantine DLQ, and only THEN a source ACK of the original delivery, so
   the record is durably captured, never authoritatively projected, and never left
   unresolved.

The authorization matrix (see design.md) SHALL specify, per outcome, the PubAck
behaviour, the destination stream/DLQ, whether the agent may resolve its spool
entry, whether domain projection is permitted, and which component owns each
current-fence lookup. EventWriter SHALL evaluate these decisions in the fixed order
defined by the ingestion Replay requirement: it SHALL RECOMPUTE and verify
`semantic_envelope_sha256` before that digest is ever used as a ledger replay key; it
SHALL immutably bind the `edge_slot`/`service_slot` to `record_sha256` before any
terminal projection-fence decision; and it SHALL resolve the historical collection
proof to exactly one of `valid`, `invalid`, `historically_revoked`, or `unavailable`
for EVERY record -- so a compromise-revoked signing key resolves to
`historically_revoked` and is REACHABLE, never silently downgraded to
`authoritative_apply`.

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

#### Scenario: One boolean cannot stand in for the four decisions
- **WHEN** a component needs an authorization outcome
- **THEN** it SHALL consume the typed historical-proof, publication, delivery-mode,
  and projection dispositions
- **AND** a single `ValidateRecordSigned`-style boolean SHALL NOT be the sole basis
  for publication or projection

#### Scenario: A retryable rejection does not advance the resolved watermark
- **GIVEN** the gateway returns `retryable_rejection` for a delivery-frame lane
  sequence
- **WHEN** the agent records the disposition
- **THEN** the delivery-ACK wire enum SHALL carry a retryable outcome distinct from
  an accept or a permanent reject
- **AND** the resolved delivery sequence SHALL NOT advance and the agent SHALL
  retain the frame for retry

#### Scenario: An audit or quarantine publication is not an authoritative accept
- **WHEN** the gateway returns `audit_publication` or `quarantine_publication`
- **THEN** the delivery-ACK wire enum SHALL distinguish it from both a
  `primary_publication` accept and a `permanent_rejection`
- **AND** the agent SHALL NOT treat it as an authoritative accept nor as a permanent
  reject when resolving its spool sequence

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

### Requirement: Delivery topology is finite and platform-owned
The platform SHALL own a finite set of route profiles and immutable traffic
classes. A delivery lane SHALL be one route-profile/traffic-class pair plus a
separately reserved recovery lane. Lane, subject, physical stream, connection,
consumer, process, and RAFT-group cardinality SHALL NOT grow with payload kind,
package, plugin, integration, or output-contract count. V1 SHALL begin with one
`durable-records-v1` route profile and disjoint bulk/interactive physical
streams; another profile requires an explicit benchmarked platform change.

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

### Requirement: Cluster-local producers use governed service ingress
Cluster-local producers SHALL use governed service ingress. A cluster-local
producer MAY use the same canonical contract/projector registry
without hairpinning through an agent/gateway, but it SHALL publish through an
attested service identity and contract-scoped governed JetStream publisher that
observes the same envelope, routing, cost, idempotency, and PubAck rules. Because
such a governed direct/cluster-local publisher has no agent spool coordinates,
it SHALL bind to a source-neutral durable service-ingress publication slot rather
than requiring agent spool coordinates. That slot SHALL be the frozen
domain-separated tuple `service_slot = (network_scope_id, authenticated_service_id,
publication_lane_id, publication_sequence)`, carrying its own domain-separation tag
and its own `record_sha256` binding as a compared value, and SHALL play the same
role in the delivery id, transport-provenance header, partition bucket, and SQL
uniqueness that the agent `edge_slot` tuple plays for agent-originated records.
Service-ingress v1 is FRESH-only, so a `service_slot` participates in NO delivery
grant (renewal/rollover); delivery grants apply to agent `edge_slot`s only. It SHALL
NOT claim agent provenance.

The `publication_lane_id` SHALL be a 16-byte UUIDv7 allocated ONCE, durably, before
the lane's first publication, and SHALL remain stable for the life of that lane. The
`publication_sequence` SHALL start at 1 and increase monotonically; a retry, timeout,
or process restart of a not-yet-acknowledged publication SHALL REUSE the same
`(publication_lane_id, publication_sequence)` (never a fresh one), so a lost-ACK
redelivery presents the exact same `service_slot` and `record_sha256` and is deduplicated
rather than double-projected. A `publication_sequence` of 0, or a `publication_lane_id`
that is not a 16-byte UUIDv7, SHALL be rejected fail-closed.

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

The service-ingress path SHALL define service variants of the three transport
transcripts over the `service_slot` tuple in place of agent spool coordinates: a
`Nats-Msg-Id` variant under domain tag `serviceradar.edge.msgid.service` framing the
attested service principal, `network_scope_id`, `publication_lane_id`,
`publication_sequence`, `semantic_envelope_sha256`, and `record_sha256`; a
`Sr-Edge-Delivery-Id` variant under domain tag `serviceradar.edge.delivery-id.service`
framing the `service_slot` tuple; and a `Sr-Edge-Transport-Provenance` envelope whose
slot-kind discriminant is `service-ingress` and which carries the `service_slot`
tuple. The `delivery_proof_digest` SHALL be OPTIONAL and absent for FRESH and
service-ingress records (present only for late-delivery, renewal, or rollover records
that carry a delivery capability), and the provenance presence byte SHALL mark its
absence. A missing delivery proof on a fresh or service-ingress record SHALL NOT be
poison.

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

#### Scenario: Service-ingress fresh record omits delivery proof
- **GIVEN** a governed cluster-local service publishes a fresh record to its own
  service-ingress subject over its isolated publisher credential
- **WHEN** its `Sr-Edge-Transport-Provenance` envelope carries slot-kind
  `service-ingress`, the `service_slot` tuple, and an absent `delivery_proof_digest`
  marked by the presence byte
- **THEN** EventWriter SHALL accept it as valid provenance and SHALL NOT treat the
  missing delivery proof as poison
- **AND** trust SHALL derive from the per-class service-ingress subject/credential
  isolation, not from a global "only the gateway" rule

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
