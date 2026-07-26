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
`EdgeProducerContext` values; that `authority_epoch` and the scope identity equal
those asserted by the record's production claims and source claims; and, for
ACTIVE attribution, that `range_sha256` equals either the signed source range the
record's authorization carries, or a range derivation that the output contract
explicitly owns and that is itself frozen. Only then SHALL it commit the physical
binding.

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

### Requirement: The local attribution-binding grammar is versioned and domain-separated
The on-disk attribution-binding grammar SHALL be versioned and domain-separated,
and SHALL be defined independently of any wire grammar.

It SHALL carry its own version constant and its own frozen domain tag, so a local
binding digest can never collide with a manifest-page, manifest-root, plan, or
semantic-envelope digest by field-structure coincidence. It SHALL be written
field-by-field over declared fields, never by re-marshalling a decoded message.

The transcript SHALL include LANE AND SPOOL/GENERATION IDENTITY alongside the
sequence, `event_id`, record hash, the active/passive discriminant, and the
COMPLETE attribution tuple. Without spool identity the same record at sequence 1
in two different spools digests identically, so a destination binding would be
indistinguishable from its source and REBINDING could not be represented at all —
which the rollover coverage proof depends on.

The grammar SHALL be frozen with CONCRETE values before the spool attribution work
begins, not described abstractly. It is:

- domain literal `serviceradar.edge.recovery.local_binding.v1`;
- `binding_version` = 1 (u64), immediately after the domain;
- 8-byte big-endian integers, 8-byte big-endian length prefixes on every
  variable-length field, and 1-byte discriminants (`0x00`/`0x01`);
- field-by-field over declared fields only — never `proto.Marshal`, at any depth;
- ordered transcript, exactly:
  1. `str` domain literal
  2. `binding_version` (u64)
  3. `lane_route_profile` (u64), `lane_traffic_class` (u64)
  4. `spool_generation_id` (bytes)
  5. `sequence` (u64)
  6. `event_id` (bytes)
  7. `record_sha256` (bytes)
  8. `attribution_kind` (1-byte discriminant: `0x00` PASSIVE, `0x01` ACTIVE)
  9. `contract_bundle_sha256` (bytes)
  10. `producer_assignment_id` (bytes)
  11. `run_id` (bytes)
  12. `run_shard` (u64)
  13. `authority_epoch` (u64)
  14. `scope_sha256` (bytes)
  15. `range_sha256` (bytes) — present ONLY when `attribution_kind` is ACTIVE, and
      absent entirely for PASSIVE rather than encoded as empty, so a passive
      binding can never collide with an active one whose range digest is zero.

Cross-language GOLDEN vectors SHALL cover an active binding, a passive binding,
and a REBINDING vector proving the same `event_id`/`record_sha256` at the same
sequence in two different `spool_generation_id`s produces two different digests.

The binding record SHALL be stored corruption-independently of `record_bytes`:
independently checksummed, separately addressable, and readable when the record
segment is unreadable. Dictionary or RLE encoding per segment is permitted
provided the checksum covers the encoded form and decoding does not depend on any
record payload.

#### Scenario: Local binding digest cannot collide with a wire digest
- **WHEN** a local attribution binding is digested
- **THEN** its preimage SHALL lead with its own domain tag and version
- **AND** SHALL NOT equal any wire-grammar digest over the same values

#### Scenario: Same record in two spools binds differently
- **WHEN** the same record occupies sequence 1 in two different spool generations
- **THEN** their local binding digests SHALL differ
- **AND** a destination rebinding SHALL be distinguishable from its source

#### Scenario: Binding store is readable without records
- **WHEN** a record segment is unreadable
- **THEN** the attribution bindings for its sequences SHALL still be readable and
  checksum-verifiable

### Requirement: Loss is described by one ordered classification-span list
The recovery page SHALL describe loss with ONE ordered `classification_spans`
list, which REPLACES both `lost_ranges` and `affected`. There SHALL NOT be a
separate lost-range array for the spans to agree with: a second array would make
two schemas describe the same fact and admit manifests where they disagree.

Each span SHALL carry a PHYSICAL sequence interval and exactly one classification
body:

- `ATTRIBUTED_ACTIVE` — attributed, asserting a produced target range;
- `ATTRIBUTED_PASSIVE` — attributed, asserting NO produced target range;
- `UNATTRIBUTABLE(reason)` — not attributable, carrying its reason.

Every variant SHALL carry a physical interval, including passive: a passive record
still occupies a lost DELIVERY sequence, and omitting its interval would leave a
hole no consumer could distinguish from undetected loss. Passive differs only in
asserting no produced target range.

The list SHALL be strictly ordered by sequence and SHALL be internally
well-formed: no gaps within the page's declared coverage, no overlaps, no
duplicates, and no interval outside the page's coverage. Total loss for the
manifest is exactly the union of its pages' spans; it SHALL NOT be declared
anywhere else.

Because task 1.7 has NOT yet frozen the transport ABI and no agent emits the
candidate recovery-v1 grammar, this replacement SHALL be made ATOMICALLY rather
than carried alongside the old arrays. Retaining compatibility machinery for an
unshipped format would preserve exactly the dual-schema ambiguity this removes.
The following SHALL be updated together, in one change: the page and manifest
messages, Appendix A's digest transcript, EVERY `recovery_grammar_version = 1`
reference, both runtimes' validators, and all fixtures.

The classification enum numbers, span fields, per-page and per-manifest bounds,
unknown-field and unknown-enum handling, and the recovery digest version SHALL be
FROZEN before any implementation depends on them.

#### Scenario: Spans are the only loss declaration
- **WHEN** a manifest page declares loss
- **THEN** it SHALL do so ONLY through `classification_spans`
- **AND** a page carrying a separate lost-range or affected array SHALL be
  rejected

#### Scenario: Span list is well-formed
- **WHEN** a page's classification spans are validated
- **THEN** a gap, overlap, duplicate, out-of-coverage, or out-of-order span SHALL
  be rejected

#### Scenario: Passive carries its delivery interval
- **WHEN** a lost sequence held a passive record
- **THEN** its span SHALL carry that physical interval
- **AND** SHALL assert no produced target range

#### Scenario: Grammar is frozen before use
- **WHEN** an implementation consumes the classification spans
- **THEN** enum numbers, fields, bounds, unknown handling, digest version, and
  the Appendix A transcript SHALL already be frozen

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
- commit evidence intact, bindings valid, record bytes MISSING OR CORRUPT ->
  ATTRIBUTED LOSS; manifested as an attributed lost span.
- commit evidence intact but ATTRIBUTION, WRAPPER, or RECEIPT BINDING missing or
  unverifiable -> AMBIGUOUS ALLOCATED SLOT (below).
- commit evidence MISSING OR CORRUPT for a slot whose append may have been
  ACKNOWLEDGED — including a sequence high-water allocated with no marker, and a
  COMPLETE prepared record with no marker -> AMBIGUOUS ALLOCATED SLOT.
- no commit evidence, no high-water allocation, and no complete record ->
  DISCARDABLE PREPARATION; the append never became durable.

An AMBIGUOUS ALLOCATED SLOT SHALL enter rollover coverage rather than being
discarded or silently retained. It SHALL be classified ATTRIBUTED when its
attribution binding verifies against the record, and UNATTRIBUTABLE with the
corresponding reason when it does not. A slot whose sequence was allocated cannot
simply vanish: the sequence is already reflected in the high-water, so an
unresolved slot permanently pins the cumulative prefix.

The sender SHALL expose COMMITTED entries only. The deciding scan SHALL be bounded
by the generation's segment count, and a quarantined or ambiguous sequence SHALL
NOT be reused.

#### Scenario: Committed slot with lost bytes is attributed loss
- **WHEN** restart finds intact commit evidence and valid bindings but missing or
  corrupt record bytes
- **THEN** the slot SHALL be manifested as an ATTRIBUTED lost span

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
- **AND** SHALL be attributed if its binding verifies, otherwise unattributable

#### Scenario: Complete prepared record without a marker is ambiguous
- **WHEN** restart finds a complete record whose commit evidence is absent
- **THEN** it SHALL be treated as an AMBIGUOUS ALLOCATED SLOT, not as preparation

#### Scenario: Committed marker with missing bindings is ambiguous
- **WHEN** commit evidence is intact but attribution, wrapper, or receipt binding
  is missing or unverifiable
- **THEN** the slot SHALL enter rollover coverage
- **AND** SHALL be unattributable unless its attribution binding verifies

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
- a FROZEN loss span whose required recovery pages have been PubAcked.

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
  is neither committed and sender-visible at the destination nor covered by a
  PubAcked frozen classification span
- **THEN** the source segment SHALL NOT be deleted

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
Coarsening MAY combine intervals belonging to the SAME attribution key, and SHALL
NOT collapse unrelated assignments or runs into a single fabricated affected
scope, nor widen a scope to cover sequences that key never produced.

Where a span cannot be coarsened without merging distinct keys, the manifest SHALL
retain the separate intervals or split the recovery, never invent coverage and
never relabel proven attribution as unattributable.

#### Scenario: Same-key intervals merge
- **WHEN** adjacent lost intervals share one attribution key
- **THEN** coarsening MAY emit a single interval for that key

#### Scenario: Distinct keys never merge
- **WHEN** adjacent lost intervals belong to different attribution keys
- **THEN** coarsening SHALL NOT emit one affected scope spanning both
- **AND** the manifest SHALL remain rejectable if it does

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
