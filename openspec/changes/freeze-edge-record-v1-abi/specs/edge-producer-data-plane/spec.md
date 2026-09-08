## ADDED Requirements

### Requirement: Projected row cost is derived from enumerated synchronous mutations
Any component declaring a projected row cost or performing synchronous mutations for an admitted edge record SHALL account for those mutations using the shared projection row rule, and the count SHALL be the length of its enumerated row set.

The accounting scope is one admitted record and its single synchronous admission
transaction. It includes every ledger, domain, outbox, work and current-state row
mutated by that transaction. Asynchronous work and existing event_writer processors
using a different ingestion contract are outside this scope.

`projection.SweepProjectionRows` and `projection.MtrProjectionRows` enumerate the
currently defined domain rows; the count functions derive their totals from these
lists. `ServiceRadar.Edge.ProjectionRows` implements the same rule. Sweep rows
comprise host reachability, each open port, each port error and a present MTR summary;
MTR rows comprise each trace and each hop. Batch and child indices identify the
source of each enumerated mutation. They are projection coordinates, not wire IDs.

No production component currently declares a cost using this rule or persists an
admitted edge record. This absence SHALL NOT exempt future admission ledger, outbox,
work or current-state mutations: a component introducing them SHALL extend the row
rule and its shared fixtures before declaring or consuming that cost. The static
guard in `build/edge_projection_accounting_test.py` records its inspected source
scope and its limitations; it SHALL be extended when runtime integration adds an
ingress or persistence path outside that scope. A lexical guard alone SHALL NOT be
treated as proof of dynamic callback effects or of a future writer's actual count.

#### Scenario: Both runtimes count the same committed batch
- **GIVEN** a committed positive sweep or MTR batch in the projection corpus
- **WHEN** each runtime enumerates its domain rows
- **THEN** the row coordinates and list length SHALL equal the shared corpus, including an empty batch

#### Scenario: Admission adds an outbox mutation
- **GIVEN** a component adding a synchronous outbox row to edge-record admission
- **WHEN** it declares or checks the admitted record's projected cost
- **THEN** that row SHALL appear in the shared accounting rule and count; a domain-only count SHALL NOT suffice
### Requirement: Every record carries an exact output-contract reference
Every accepted record SHALL carry an `EdgeOutputContractRef` that identifies its output contract EXACTLY.

The reference SHALL bind contract ID and version, the IMMUTABLE bundle digest, the
registry epoch, the registry-snapshot digest, and the effective-grant digest. A
reference that names a contract without pinning the exact bundle digest and epoch
SHALL be rejected: two deployments can hold different bundles under one contract
version, so a name alone does not identify the semantics a record was produced
under.

The bundle those fields reference binds encoding and schema canonicalization,
unknown-field policy, bounded validator, authoritative-field rules, deterministic
domain identity and revision/merge semantics, platform partition rule, cost model,
projector engine/configuration, retention/data classification, and error policy.
This change freezes the REFERENCE; the registry that holds bundles, and its
deployment lifecycle -- candidate/ready/active/draining/retired, activation,
backlog drain, security revocation, stale-component fencing, and history
collection -- is downstream runtime behaviour with its own tasks.

#### Scenario: A record names a contract without pinning its bundle
- **WHEN** a record carries a contract ID and version but no exact bundle digest
  or registry epoch
- **THEN** it SHALL be rejected
- **AND** the receiver SHALL NOT resolve it against a locally latest-known bundle

#### Scenario: The reference is exact across replay horizons
- **WHEN** a record is replayed after its contract version has been superseded
- **THEN** its reference SHALL still identify the exact historical bundle it was
  produced under

### Requirement: Producer provenance fields are authoritative record facts
The record SHALL carry producer provenance and authority as AUTHORITATIVE FIELDS, and no other source SHALL override them.

Producer instance, package digest, assignment, run, source/coverage scope, network
scope, agent identity, route profile, traffic class, and cost metadata are fields
of `EdgeProducerContext` and the record's signed claims. They are the authoritative
statement of those facts.

Caller-selected identifiers SHALL NOT create identity, capability, routing, or
quota namespaces. A value a producer chose does not become a namespace by appearing
in the record.

Carrier provenance SHALL NOT make opaque payload claims authoritative: a claim
inside the payload body SHALL NOT be read as an authoritative field, whatever it
names.

Output permission SHALL NOT grant network scanning, raw-socket, filesystem, HTTP,
credential, command, or target access. Those are authorized separately by the
command/assignment plane, so an output capability in the record SHALL NOT be read
as conveying them.

WHO derives, verifies, compares, or replaces these fields at runtime -- the trusted
agent sink and EventWriter -- is downstream behaviour over this contract, not part
of it.

#### Scenario: A payload claim contradicts an authoritative field
- **WHEN** the payload body carries a claim that contradicts an authoritative
  field
- **THEN** the authoritative field SHALL govern
- **AND** the payload claim SHALL NOT be read as authoritative

#### Scenario: An output capability is read as scan authority
- **WHEN** a record carries an output capability for a scan-result contract
- **THEN** that capability alone SHALL NOT be read as authorizing the probe or as
  making the target claims authoritative

### Requirement: Edge record identity is physical, semantic, and domain
The edge pipeline SHALL use four deliberately-separate identities across its
stages, and byte-for-byte equality of two records SHALL NOT be a protocol
invariant. These are PIPELINE-STAGE identities, NOT four fields of one
`EdgeRecordV1`, and this requirement SHALL NOT be read as adding record fields:
`submission_sha256` is journal-local (producer -> sink, never placed on the wire);
`record_sha256` belongs to the delivery frame/slot (`EdgeDeliveryFrameV1`); and
`semantic_envelope_sha256` together with `event_id` are carried on `EdgeRecordV1`.

- `submission_sha256` is the PRODUCER-RECEIPT identity: the SHA-256 of the
  producer's bounded UNCOMPRESSED contract-payload submission bytes, computed at
  submission BEFORE the sink compresses or constructs `EdgeRecordV1`. It is the
  producer idempotency / retry-lookup COMPARISON value (the journal keys on the 5-tuple, never on this digest) and SHALL NOT be a transport-slot key,
  the semantic digest (which carries sink-assigned fields), or `payload_sha256`
  (post-compression).
- `record_sha256` is the PHYSICAL artifact identity: the SHA-256 of a record's
  exact encoded bytes. It is the value by which an unchanged artifact is
  RECOGNIZED: any hop that alters the bytes changes it, so a differing
  `record_sha256` within one slot is a transport-integrity violation. WHICH
  components carry, preserve, or re-hash those bytes, and over which path, is
  runtime and is owned downstream. It binds the durable delivery slot and signed
  delivery grant via
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
- `event_id` (a UUIDv7; WHEN it is allocated relative to spooling is runtime,
  owned downstream) participates in two distinct identities: with `network_scope_id` it forms the logical EVENT identity
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
numerics) and SHALL each commit that version as the leading bytes of their
preimage, preceded by a per-grammar string domain-separation tag WHERE ONE IS
DEFINED. A domain tag is not universal: the MTR leaf and root and the
recovery-operation scope grammars deliberately have none, using a `u64` body-kind
discriminant instead.

Fail-closed version handling has TWO forms, matching how the version reaches the
receiver:

- EXPLICIT-VERSION REJECTION, where the object DECODES a version from its input --
  reject an unsupported value.
- ALTERED-CONSTANT DIGEST MISMATCH, where the version is a compile-time constant in
  the preimage and the received value is a digest or opaque identifier -- there is
  no version input to reject, so the fail-closed property is that recomputing under
  a different constant yields a digest that does not match.

The semantic-envelope version is the SECOND form: it is not a wire input, so no
record can "declare" it. Neither form SHALL trial-hash alternative grammars. Every grammar SHALL be
byte-frozen with a FIXED field order (no per-field numeric tags), 8-byte big-endian
integers and enums, 8-byte big-endian length prefixes on bytes/string fields, 1-byte
presence markers, `u64` (8-byte big-endian) oneof discriminants, `u64` element counts
for repeated fields, and recursive field-by-field nested framing; no protobuf
serialization output SHALL appear in any preimage.

A receiver SHALL NOT establish semantic identity, equivalence, authorization,
idempotency, conflict status, or wire validity by decoding protobuf and comparing
it against a re-encoding. Exact encoded record and payload bytes MAY be hashed as
explicitly-designated physical artifacts. WHO serializes a record, how many times,
WHICH components must preserve those exact bytes end to end, and where they are
decoded and re-hashed are downstream runtime behaviour. `Deterministic` protobuf marshalling
MAY be a local reproducibility optimization at the sink but SHALL NOT be a protocol
invariant.

Admission SHALL NOT be established by decoding, re-encoding, and byte-comparing the
result, and no component SHALL require, assert, or enforce a unique byte encoding of
a record. Whether any particular hop normalizes, reorders, or re-encodes is
component behaviour and is owned downstream.
`Deterministic` protobuf marshalling MAY be a local reproducibility optimization at
the sink, but SHALL NOT be a protocol invariant: protobuf has no canonical wire
form, so two compliant encoders may emit different bytes for the same semantics and
a byte-compare admission would reject valid records.

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

#### Scenario: An input-carried grammar version is unknown
- **WHEN** an object that DECODES a version from its input carries an unsupported one
- **THEN** the receiver SHALL reject it fail-closed
- **AND** it SHALL NOT trial-hash the object under other grammar versions

#### Scenario: A constant-version grammar fails closed by mismatch
- **WHEN** an object's version is a compile-time preimage constant and the receiver
  computes under a different constant
- **THEN** the resulting digest SHALL NOT match and the object SHALL be rejected
- **AND** the receiver SHALL NOT trial-hash to find a matching version

### Requirement: Delivery topology is finite and platform-owned
The platform SHALL own a FINITE set of route profiles and immutable traffic classes, and a delivery lane SHALL be one route-profile/traffic-class pair plus a separately reserved recovery lane.

V1 SHALL begin with one `durable-records-v1` route profile; another profile
requires an explicit benchmarked platform change. The enum members and the lane
definition are wire facts. The physical cardinality those lanes map onto --
subjects, streams, connections, consumers, processes, RAFT groups -- is runtime and
is owned downstream.

#### Scenario: A route profile or traffic class outside the taxonomy
- **WHEN** a record declares a route profile or traffic class that is not a
  declared member of the platform taxonomy
- **THEN** it SHALL be rejected
- **AND** it SHALL NOT be aliased onto a nearby declared member

#### Scenario: Traffic class is immutable on the record
- **WHEN** any component other than the issuing control plane sets or changes a
  record's `traffic_class`
- **THEN** the record SHALL be rejected: the class is an immutable signed fact,
  not a routing hint

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
   `DeliveryModeRenewal = 2`, `DeliveryModeRollover = 3`, and
   `DeliveryModeLateFenced = 4`.
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


### Requirement: Broker publication identity is separate from the semantic envelope
Broker publication identity SHALL be a SEPARATE identity from the record identities
above. It is carried in TRANSPORT HEADERS, never as a field of `EdgeRecordV1`, and it
SHALL NOT be derived from, equal to, or substitutable for `semantic_envelope_sha256`.

Three transcripts are frozen for the agent `edge_slot` path. Each SHALL begin with its
OWN string domain tag followed by its OWN `u64` version constant, and SHALL frame every
field by the same primitives the semantic-envelope transcript uses: unsigned integers
as 8-byte big-endian, and every bytes or string field length-prefixed by an 8-byte
big-endian length. Each header value SHALL be the base64url (NO padding) encoding of
the SHA-256 of its transcript.

- `Nats-Msg-Id` SHALL frame, under domain `serviceradar.edge.msgid` with
  `msgid_version = 1`: the attested `authenticated_agent_id`, `network_scope_id`,
  `spool_id`, `sequence`, `semantic_envelope_sha256`, then `record_sha256`. It COMMITS
  the semantic-envelope digest as an INPUT. Committing a value does not make the two
  the same object, and no component SHALL accept one where the other is required.
- `Sr-Edge-Delivery-Id` SHALL frame, under domain `serviceradar.edge.delivery-id` with
  `delivery_id_version = 1`, ONLY the `edge_slot` tuple: `network_scope_id`,
  `authenticated_agent_id`, `spool_id`, `sequence`. It SHALL NOT commit a semantic,
  payload, or record digest. It names the SLOT, which is what makes it stable across a
  re-encode that changes `record_sha256`.
- `Sr-Edge-Transport-Provenance` SHALL frame, under domain
  `serviceradar.edge.transport-provenance` with `provenance_version = 1`: a slot-kind
  discriminant, the slot tuple, `record_sha256`, the delivery mode, a 1-byte presence
  marker for `delivery_proof_digest` with the digest when present, and the route-map
  version.

The service variants of all three are defined by the requirement below and SHALL carry
DISTINCT domain tags, so an edge value and a service value cannot collide even when
every remaining framed field agrees.

The semantic envelope carries NO string domain tag and its own version constant is
`semantic_digest_version = 3`, so no publication transcript shares its preimage shape.
A publication identity SHALL NOT appear in the semantic-envelope preimage at any
nesting depth.

#### Scenario: A re-encoded record changes its message id but not its delivery id
- **WHEN** a record occupying one `edge_slot` is re-encoded so that `record_sha256`
  changes
- **THEN** its `Nats-Msg-Id` SHALL change, so a broker cannot dedupe the two encodings
  as one message
- **AND** its `Sr-Edge-Delivery-Id` SHALL NOT change, because the delivery id names the
  slot and not the bytes

#### Scenario: The message id commits the semantic envelope without becoming it
- **WHEN** two records in the same `edge_slot` differ only in
  `semantic_envelope_sha256`
- **THEN** their `Nats-Msg-Id` values SHALL differ
- **AND** neither `Nats-Msg-Id` SHALL equal the record's `semantic_envelope_sha256`
  under any encoding of it

#### Scenario: Edge and service publication values cannot collide
- **WHEN** an `edge_slot` and a `service_slot` agree on every field their transcripts
  frame in common
- **THEN** their `Nats-Msg-Id` values SHALL differ, and their `Sr-Edge-Delivery-Id`
  values SHALL differ, because each variant carries its own domain tag

### Requirement: The service-ingress publication slot is a frozen wire identity
A service-originated record SHALL bind to the frozen `service_slot` tuple, which SHALL play the same wire role for service records that `edge_slot` plays for agent records.

`service_slot = (network_scope_id, authenticated_service_id, publication_lane_id,
publication_sequence)`, carrying its own domain-separation tag and its own
`record_sha256` binding as a compared value. It is source-neutral because a
cluster-local producer has no agent spool coordinates, and it SHALL NOT claim agent
provenance. It plays the same role in the delivery id, transport-provenance header,
partition bucket, and SQL uniqueness that `edge_slot` plays.

`publication_lane_id` SHALL be a 16-byte UUIDv7 and `publication_sequence` SHALL
start at 1 and increase monotonically. A `publication_sequence` of 0, or a
`publication_lane_id` that is not a 16-byte UUIDv7, SHALL be rejected fail-closed.

WHEN a lane id is allocated, how a sequence is journaled, and how a retry, timeout,
or restart reuses `(publication_lane_id, publication_sequence)` are DURABLE
ALLOCATION LIFECYCLE and are owned downstream. What is frozen here is the tuple's
shape and validity.

Service-ingress v1 is FRESH-ONLY: a `service_slot` participates in NO delivery grant,
renewal, or rollover; delivery grants apply to agent `edge_slot`s only. Late-delivery
or recovery of a service-ingress record SHALL require a FUTURE VERSION.

The path SHALL define service variants of the three transport transcripts over
`service_slot` in place of agent spool coordinates: a `Nats-Msg-Id` variant under
domain tag `serviceradar.edge.msgid.service` framing the attested service principal,
`network_scope_id`, `publication_lane_id`, `publication_sequence`,
`semantic_envelope_sha256`, and `record_sha256`; a `Sr-Edge-Delivery-Id` variant
under `serviceradar.edge.delivery-id.service` framing the `service_slot` tuple; and
a `Sr-Edge-Transport-Provenance` envelope whose slot-kind discriminant is
`service-ingress` and which carries the `service_slot` tuple.

`delivery_proof_digest` SHALL be OPTIONAL and ABSENT for FRESH and service-ingress
records -- present only for late-delivery, renewal, or rollover records carrying a
delivery capability -- and the provenance presence byte SHALL mark its absence. A
missing delivery proof on a fresh or service-ingress record SHALL NOT be poison.

WHO allocates, journals, publishes, acknowledges, seals, or drains these slots, and
which credential may publish where, is downstream runtime behaviour over this
contract.

#### Scenario: Service-ingress fresh record omits delivery proof
- **WHEN** an `Sr-Edge-Transport-Provenance` envelope carries slot-kind
  `service-ingress`, the `service_slot` tuple, and an absent `delivery_proof_digest`
  marked by the presence byte
- **THEN** the envelope SHALL decode as VALID provenance
- **AND** the missing delivery proof SHALL NOT be poison

#### Scenario: A malformed publication slot is refused
- **WHEN** a service record carries `publication_sequence` 0, or a
  `publication_lane_id` that is not a 16-byte UUIDv7
- **THEN** it SHALL be rejected fail-closed

#### Scenario: A service record claims a delivery grant
- **WHEN** a `service_slot` record carries a delivery capability, renewal, or
  rollover
- **THEN** it SHALL be rejected: service-ingress v1 is fresh-only and that
  capability requires a future version

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

- digest algorithm SHA-256, output width 32 bytes, consistent with every other
  identity in this design -- a transcript alone does not determine an artifact, so
  two implementations could follow the field order exactly and still emit different
  digests;
- domain literal `serviceradar.edge.recovery.local_binding.v1`;
- `binding_version` = 1 (u64), immediately after the domain; an UNSUPPORTED
  `binding_version` SHALL fail closed WITHOUT trial hashing -- a reader SHALL NOT
  attempt other versions to find one that matches -- and the affected slot SHALL be
  classified UNATTRIBUTABLE with the corresponding reason rather than discarded or
  silently retained;
- 8-byte big-endian integers, 8-byte big-endian length prefixes on every
  variable-length field, and 1-byte discriminants (`0x00`/`0x01`);
- field-by-field over declared fields only — never `proto.Marshal`, at any depth;
- ordered transcript, exactly:
  1. `str` domain literal
  2. `binding_version` (u64)
  3. `network_scope_id` (bytes)
  4. `authenticated_agent_id` (bytes)
  5. `lane_route_profile` (u64), `lane_traffic_class` (u64)
  6. `spool_generation_id` (bytes)
  7. `sequence` (u64)
  8. `event_id` (bytes)
  9. `record_sha256` (bytes)
  10. `attribution_kind` (1-byte discriminant: `0x00` PASSIVE, `0x01` ACTIVE)
  11. `contract_bundle_sha256` (bytes)
  12. `producer_assignment_id` (bytes)
  13. `run_id` (bytes)
  14. `run_shard` (u64)
  15. `authority_epoch` (u64)
  16. `production_scope_id` (bytes)
  17. `scope_sha256` (bytes) — the PRODUCTION scope digest
  18. `source_identity_present` (1-byte discriminant: `0x00` ABSENT, `0x01`
      PRESENT)
  19. `source_authorization_kind` (u64) — present ONLY when
      `source_identity_present` is `0x01`
  20. `source_context_id` (bytes) — present ONLY when `source_identity_present` is
      `0x01`
  21. `source_scope_id` (bytes) — present ONLY when `source_identity_present` is
      `0x01`
  22. `source_scope_sha256` (bytes) — present ONLY when `source_identity_present`
      is `0x01`; the SOURCE scope digest, distinct from step 17
  23. `range_sha256` (bytes) — present ONLY when `attribution_kind` is ACTIVE, and
      absent entirely for PASSIVE rather than encoded as empty, so a passive
      binding can never collide with an active one whose range digest is zero.

Steps 3-4 are the generation's TRUST NAMESPACE. A generation freezes its
`network_scope_id` and authenticated agent identity, and without them an intact
sidecar can be transplanted or mis-replayed under another agent or scope carrying
the same `spool_generation_id` without changing the digest -- the same
substitution class this binding exists to detect.

Both SCOPE IDS travel with their digests. The wire signs `scope_id` and
`scope_sha256` independently -- on production claims, on source claims, and on the
outer source authorization -- and validation compares them independently; nothing
derives a unique ID from a digest. Carrying only the digests would let two accepted
records differing in a signed logical scope ID share one recovery key, collide in
the assignment mapping, and leave the binding unable to prove which scope ID was
originally attached after record-byte loss.

Steps 18-22 are the SOURCE IDENTITY, and they are inside the corruption-independent
digest for the same reason the rest of the tuple is. If the source identity lived
only in the sidecar, then after record-byte corruption a sidecar context could be
changed without invalidating the digest that is supposed to prove the attribution
came from THAT record -- which is precisely the substitution this binding exists to
prevent.

Steps 16-17 are the PRODUCTION scope and steps 21-22 are the SOURCE scope; they
are different values in the canonical accepted record, so one pair cannot serve
both.

The KIND is carried with the context and is not optional decoration: the same UUID
can name a scheduled check, an ad-hoc scan, a command, or a sweep execution, and
after the record bytes are lost a consumer cannot choose the correlation variant
from the context alone. Kind and context SHALL be present together or absent
together; a partial combination SHALL be rejected.

Cross-language GOLDEN vectors SHALL cover an active binding, a passive binding, a
REBINDING vector proving the same `event_id`/`record_sha256` at the same sequence
in two different `spool_generation_id`s produces two different digests, a
source-identity-present and a source-identity-absent binding proving they digest
differently, a partial-combination REJECT vector (any one of kind, context, source scope id, or
source scope digest without the others), a SAME-CONTEXT/DIFFERENT-KIND vector
proving the two digests differ, an UNSUPPORTED-`binding_version` REJECT vector, a
SAME-BINDING/DIFFERENT-NAMESPACE vectors that mutate `network_scope_id` and the
authenticated agent SEPARATELY -- not one vector changing "either" -- so omitting
EITHER transcript field fails its own vector, and SAME-DIGEST/DIFFERENT-ID vectors
for BOTH the production and source scopes.

The APPEND-TIME SEMANTIC JOIN SHALL have its own substitution vectors, not only the
binding/span/mapping layers: one PRODUCTION-scope-ID mismatch and one
SOURCE-scope-ID mismatch, each holding the corresponding DIGEST FIXED, both
rejected. A digest-only comparison passes those cases, which is exactly the
substitution the ID was added to stop.

The four combinations of {ACTIVE, PASSIVE} x {source present, source absent} SHALL
EACH have a cross-language binding vector AND an append-join vector. Two diagonal
fixtures -- ACTIVE+present and PASSIVE+absent -- would satisfy the letter of the
list while leaving the independent-axis rule untested, which is the case that
motivated it. The same-context/different-kind and same-digest/different-ID
regressions SHALL also exist at the SPAN and ASSIGNMENT-MAPPING layers, not only in
the binding digest: a collision there is a mapping collision, not merely a digest
coincidence.

#### Scenario: Local binding digest cannot collide with a wire digest
- **WHEN** a local attribution binding is digested
- **THEN** its preimage SHALL lead with its own domain tag and version
- **AND** SHALL NOT equal any wire-grammar digest over the same values

#### Scenario: Same record in two spools binds differently
- **WHEN** the same record occupies sequence 1 in two different spool generations
- **THEN** their local binding digests SHALL differ
- **AND** a destination rebinding SHALL be distinguishable from its source

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

A page's EXTENT SHALL be DERIVED from its spans -- the first span's lower bound
through the last span's upper bound -- and SHALL NOT be declared in a separate
range. A declared extent would be a second schema for a fact the spans already
carry, admitting pages whose declaration and spans disagree; that is the same
dual-schema ambiguity this requirement removes by deleting `lost_ranges`, and
re-introducing it one field over would defeat the change.

It SHALL be called an EXTENT, never "coverage". Elsewhere in this design coverage
is PER-SEQUENCE evidence that can authorize reclamation; a page's extent is a
bounding interval that legally contains not-lost gaps. Naming it coverage would
invite a consumer to treat the bound as evidence and release sequences no span
ever described.

Every page SHALL carry AT LEAST ONE span. An empty page has no derivable extent,
so it can be neither validated nor chained.

Each span's interval SHALL be primitively valid on its own: `from_sequence >= 1`
and `through_sequence >= from_sequence`, with `MaxUint64` a legal bound. A single
span with a zero or inverted interval violates no ordering rule, so ordering alone
does not exclude it.

Ordering SHALL be total across the WHOLE page chain, not merely within a page:
spans SHALL be strictly ascending by sequence, non-overlapping, and non-duplicate,
and page N's last span SHALL end strictly below page N+1's first span's start. A
within-page-only rule lets two individually valid pages describe overlapping loss,
which would double-count the union.

GAPS ARE PERMITTED and carry meaning: a sequence covered by no span was NOT lost.
This holds identically within a page and at a page boundary -- adjacency is not
special. A gap DOES make the loss intervals mathematically disjoint; what it does
NOT do is require a separate page or a separate manifest. The union stays one
manifest's loss regardless of how many disjoint intervals compose it. The earlier "no gaps within coverage" rule existed only because
coverage was DECLARED, where a gap contradicted the declaration; with coverage
derived there is nothing to contradict, and forbidding gaps would force a
manifest to invent spans for sequences that were never lost.

Total loss for the manifest is exactly the union of its pages' spans; it SHALL
NOT be declared anywhere else.

That includes the TOMBSTONE. `SpoolLossTombstoneV1` SHALL NOT carry a loss
interval: `lost_from_sequence` and `lost_through_sequence` SHALL be removed, along
with their scope-digest entries, their Appendix A transcript entries, and the
validator equality that forces them to the manifest's global min/max. With gaps
legal, that min/max is not the loss -- for spans `[1,1]` and `[100,100]` the pages
say `2..99` were NOT lost while the tombstone would declare `[1,100]` lost, and
because the tombstone scope is SIGNED that second source of truth would be
authenticated. It is strictly worse than the page-level duplication this
requirement removes.

Removing the fields is part of the SAME atomic change, for the same reason the
page arrays are: retaining them as a "non-loss allocation envelope" would keep a
signed interval that every existing consumer already reads as loss.

Because task 1.7 has NOT yet frozen the transport ABI and no agent emits the
candidate recovery-v1 grammar, this replacement SHALL be made ATOMICALLY rather
than carried alongside the old arrays. Retaining compatibility machinery for an
unshipped format would preserve exactly the dual-schema ambiguity this removes.
The following SHALL be updated together, in one change: the page and manifest
messages, Appendix A's digest transcript, EVERY `recovery_grammar_version = 1`
reference, both runtimes' validators, and all fixtures.

The oneof member tags, `EdgeUnattributableReason` numbers, span fields, per-page and per-manifest bounds,
unknown-field and unknown-enum handling, and the recovery digest version SHALL be
FROZEN before any implementation depends on them.

THE FROZEN REPLACEMENT SCHEMA follows. It is normative here, not merely a task
note, because an archived capability spec that omits it would not preserve the tag
reservations or the transcript, and implementation would be free to reinvent them.

RETIRED TAGS ARE RESERVED BY NUMBER AND BY NAME, and no surviving tag is
renumbered:

- `EdgeLossManifestPageV1`: `reserved 7, 9, 10;` and
  `reserved "coarsened", "lost_ranges", "affected";`
- `SpoolLossTombstoneV1`: `reserved 3, 4, 8;` and
  `reserved "lost_from_sequence", "lost_through_sequence", "coarsened";`

Reserving stops stale candidate bytes being reinterpreted as a future field and
stops a retired name being reused for a different meaning.

THE PAGE `coarsened` BIT IS REMOVED TOO, and tag `7` plus the name are reserved. An
earlier revision kept it under a frozen set/clear rule -- SET iff a span resulted
from merging two or more raw lost intervals -- but that rule is NOT DETERMINISTIC,
because nothing defines the canonical PRE-COARSENING partition. One durable loss set
and key can enter as raw `[1,2]` or as `[1,1] + [2,2]`; both yield the final span
`[1,2]`, both satisfy the rule, and they set OPPOSITE bits. Since the bit is hashed,
that is identical spans with different page and root digests -- the exact divergence
the rule was introduced to prevent.

No page-derivable rule exists, because the precursor is producer-internal state the
page does not carry. Freezing an authoritative precursor and its segmentation would
introduce a whole new committed concept in order to make one provenance flag
verifiable, and a hashed field a validator cannot check is a divergence source by
construction. Because coarsening may merge only CONTIGUOUS LOST intervals, the loss
union is identical whether or not merging occurred, so the bit informs no consumer
decision and removing it loses nothing.

TOMBSTONE `coarsened` IS REMOVED for the same reason it is not compared: with its
loss interval gone the tombstone no longer describes loss at all, and with the page
bit also gone there is no manifest coarsening flag to derive. Coarsening is governed
by the RULES on the act -- merge only CONTIGUOUS LOST intervals whose COMPLETE
CLASSIFICATION BODIES are equal (the whole attributed identity including the source
identity or its joint absence and, on ACTIVE, `range_sha256`; for `UNATTRIBUTABLE`,
an identical `reason`), proven against durable per-sequence evidence at construction
-- never by a bit on the wire. "Same key" is NOT the rule: an `UNATTRIBUTABLE` body
has no assignment key at all, and two ACTIVE spans can share an identity while
differing in `range_sha256`.

THE SPAN IS A ONEOF, so that WHICH classification a span carries is STRUCTURAL
rather than validated: a flat enum plus optional identity fields would let one span
carry an `UNATTRIBUTABLE` discriminant together with a `range_sha256`, or two
classifications' fields at once. The oneof does NOT make every illegal state
unrepresentable -- proto3 still permits a set `attributed_active` body with a nil
`identity` -- so the structural rules below reject those explicitly. What the oneof
guarantees structurally is AT MOST ONE body; EXACTLY one is validator-enforced,
because a proto3 oneof can legitimately be unset -- which is why an unset
`classification` is an explicit rejection rule rather than an impossibility.

```proto
enum EdgeUnattributableReason {
  reserved 1, 5;
  reserved "EDGE_UNATTRIBUTABLE_REASON_SEGMENT_CORRUPT",
           "EDGE_UNATTRIBUTABLE_REASON_COARSENED";

  EDGE_UNATTRIBUTABLE_REASON_UNSPECIFIED                   = 0;  // rejected
  EDGE_UNATTRIBUTABLE_REASON_BINDING_MISSING               = 2;
  EDGE_UNATTRIBUTABLE_REASON_BINDING_CORRUPT               = 3;
  EDGE_UNATTRIBUTABLE_REASON_TORN_TAIL                     = 4;
  EDGE_UNATTRIBUTABLE_REASON_BINDING_VERSION_UNSUPPORTED   = 6;
  EDGE_UNATTRIBUTABLE_REASON_DISCRIMINATOR_UNREPRESENTABLE = 7;
}

// The record's SIGNED SOURCE IDENTITY. All four members travel together; a partial
// combination is rejected. Its ABSENCE is itself part of the span identity, so the
// transcript frames presence explicitly rather than defaulting to zeros.
message EdgeSourceSpanIdentityV1 {
  EdgeSourceAuthorizationKind kind = 1;  // UNSPECIFIED rejected
  bytes context_id                 = 2;  // canonical 16-byte UUID
  bytes source_scope_id            = 3;  // canonical 16-byte UUID
  bytes source_scope_sha256        = 4;  // exactly 32 bytes
}

message EdgeAttributedSpanIdentityV1 {
  bytes  producer_assignment_id  = 1;   // canonical 16-byte UUID
  bytes  run_id                  = 2;   // canonical 16-byte UUID
  uint32 run_shard               = 3;
  uint64 authority_epoch         = 4;   // plain u64, REQUIRED, no presence marker
  bytes  production_scope_id     = 5;   // canonical 16-byte UUID
  bytes  scope_sha256            = 6;   // exactly 32 bytes
  bytes  contract_bundle_sha256  = 7;   // exactly 32 bytes
  EdgeSourceSpanIdentityV1 source = 8;  // present iff the record carried a source
                                        // authorization; absence is significant
}

message EdgeAttributedActiveV1 {
  EdgeAttributedSpanIdentityV1 identity = 1;   // REQUIRED; an unset identity is rejected
  bytes range_sha256 = 2;                      // REQUIRED, exactly 32 bytes, ACTIVE only
}

message EdgeAttributedPassiveV1 {
  EdgeAttributedSpanIdentityV1 identity = 1;   // REQUIRED; an unset identity is rejected
}

message EdgeUnattributableV1 {
  EdgeUnattributableReason reason = 1;  // UNSPECIFIED rejected
}

message EdgeClassificationSpanV1 {
  uint64 from_sequence    = 1;
  uint64 through_sequence = 2;
  oneof classification {
    EdgeAttributedActiveV1  attributed_active  = 3;
    EdgeAttributedPassiveV1 attributed_passive = 4;
    EdgeUnattributableV1    unattributable     = 5;
  }
}

// on EdgeLossManifestPageV1, after reserved 7, 9, 10:
repeated EdgeClassificationSpanV1 classification_spans = 11;
```

An UNSET `classification` oneof SHALL be rejected: it is a span with an interval and
no classification, which no consumer can act on.

NUMERIC BOUNDS. `MaxSpansPerPage = 256`, replacing both `MaxRangesPerPage` and
`MaxAffectedScopesPerPage`; one span now carries what an interval and its scope
carried separately, so the meaningful count is the interval count. `MaxManifestPages
= 1024`, `MaxManifestBytes = 256 KiB`, and `MaxReasonBytes = 256` are UNCHANGED.
Because a span is larger than a bare interval, `MaxManifestBytes` is expected to
bind before `MaxSpansPerPage x MaxManifestPages`; both bounds are retained, and the
byte bound SHALL be measured over RECEIVED bytes, never over a re-encode of the
decoded page.

THE `ManifestPageDigest` TRANSCRIPT for the replacement shape, in exact order, under
the unchanged domain tag `serviceradar.edge.recovery.manifest_page.v1` and
`RecoveryDigestVersion = 1`:

```
str(domain) u64(digest_version) bytes(recovery_id) u64(page_index)
u64(page_count) bytes(prev_page_sha256) present(terminal)
u64(len(classification_spans))
  per span, in list order:
    u64(from_sequence) u64(through_sequence)
    u64(oneof member field number: 3 active | 4 passive | 5 unattributable)
    ACTIVE:         mark(1) identity_body bytes(range_sha256)
    PASSIVE:        mark(1) identity_body
    UNATTRIBUTABLE: u64(reason)

  where identity_body is:
    bytes(producer_assignment_id) bytes(run_id) u64(run_shard)
    u64(authority_epoch) bytes(production_scope_id) bytes(scope_sha256)
    bytes(contract_bundle_sha256)
    mark(source present ? 1 : 0)
    if present: u64(kind) bytes(context_id) bytes(source_scope_id)
                bytes(source_scope_sha256)
```

`mark(...)` is the Appendix A 1-byte nested-message presence marker
(`0x00`/`0x01`). TWO EXCEPTIONS TO THE BLANKET RULE ARE FROZEN HERE, because leaving
both rules in force would give two clean-room implementations different valid byte
streams: a REPEATED entry carries NO per-entry marker -- the preceding `u64` element
count already establishes how many follow, and a marker per entry would encode
presence twice -- and a ONEOF body carries NO marker, because the `u64` member-number
discriminant already names which body is set. Every OTHER nested message keeps its
marker. It is emitted for `identity` even though an unset identity is
REJECTED: the marker is what makes the framing recursive and self-describing, and
omitting it for a field that "cannot" be absent is how two runtimes end up
disagreeing about whether the byte is there. The SOURCE marker is load-bearing
rather than merely structural -- absence is part of the span identity, so
source-present and source-absent spans MUST produce different preimages, and
framing an absent source as zero-valued fields would collapse them.

`page_sha256` is excluded, as before. The `u64` discriminant is the Appendix A oneof
rule, so the transcript stays byte-identical across both runtimes.

STRUCTURAL VALIDITY IS FROZEN TOO, because proto3 leaves illegal states
representable that the oneof alone does not exclude -- a nil `identity`, empty
required bytes, or a wrong-width digest. The helper this task deletes performs these
checks today, so leaving them unstated would silently drop them. Every attributed
span SHALL be REJECTED unless:

- `identity` is PRESENT (a set `attributed_active` / `attributed_passive` body with
  an unset `identity` is rejected);
- `producer_assignment_id`, `run_id`, and `production_scope_id` are canonical
  16-byte UUIDs -- NOT merely non-empty: the accepted-record validators already
  require canonical UUIDs for the producer and source scope IDs, and a weaker
  manifest rule would admit attributed identities no valid record could have
  produced;
- `scope_sha256` and `contract_bundle_sha256` are exactly 32 bytes;
- on ACTIVE, `range_sha256` is present and exactly 32 bytes; on PASSIVE it is absent;
- `source` is either wholly absent or wholly present -- and when present, `kind` is
  in the FROZEN v1 ACCEPTED SET `1..7` below -- a member declared by a later proto
  revision is NOT admitted --
  `context_id` and `source_scope_id` are canonical 16-byte UUIDs, and
  `source_scope_sha256` is exactly 32 bytes.

ENUM VALIDITY IS A FROZEN ACCEPTED SET, NOT "ANY DECLARED MEMBER". The v1 accepted
sets are EXACTLY:

- `EdgeSourceAuthorizationKind`: `1..7`
- `EdgeUnattributableReason`: `2, 3, 4, 6, 7`

A value outside its set SHALL be rejected before it is hashed -- including a member
DECLARED BY A LATER PROTO REVISION. Descriptor-membership validation would silently
admit such a member and begin hashing it under an unchanged
`RecoveryDigestVersion = 1`, widening a frozen grammar by editing a `.proto`; this
change already prevents exactly that evolution bug for `MtrCompletionDisposition`.
Admitting a newly declared member REQUIRES a recovery-grammar version change.

Rejecting only `UNSPECIFIED` is likewise insufficient, since negative and
unknown-positive integers would satisfy it while still entering
`ManifestPageDigest`. Shared reject vectors SHALL cover, per enum: `0`, `-1`, the
next unknown positive above the highest accepted value, `999`, and each RESERVED
number where one exists (`1`, `5` for reasons).

An `UNATTRIBUTABLE` span SHALL carry no identity and a `reason` in the FROZEN v1
ACCEPTED SET `2, 3, 4, 6, 7` below. Every other value SHALL be rejected -- `0`, the
RESERVED numbers `1` and `5`, any negative, and any member declared by a later proto
revision.

Each rule SHALL have a shared Go/Elixir REJECT vector; a rule both runtimes merely
believe they enforce is the divergence this task exists to close.

CLASSIFICATION IS DECIDED BY WHETHER ATTRIBUTION CAN BE PROVEN, NEVER BY WHETHER
THE RECORD BYTES SURVIVED. The attribution binding is stored
corruption-independently of `record_bytes` precisely so that a slot with unreadable
record bytes, but a binding that VERIFIES FOR THIS SLOT under the relation defined
below AND a span that is REPRESENTABLE, is still an ATTRIBUTED loss. Classifying such
a slot `UNATTRIBUTABLE` would discard provable attribution at exactly the moment the
independent binding exists to preserve it, and it would contradict the runtime's
restart contract, under which intact commit evidence plus a verifying binding plus a
representable span plus missing record bytes IS attributed loss. BOTH predicates are
required here as well: a verifying binding whose span is not representable is reason
row 5, and stating the byte-loss case with verification alone would make that reason
unreachable on exactly this path. "Intact" or "checksum-valid" is NOT the test -- see the
relation below, which a transplanted sidecar satisfies on those weaker terms.

`EDGE_UNATTRIBUTABLE_REASON_SEGMENT_CORRUPT` is therefore RESERVED, not defined:
record-segment corruption is not a reason, because it does not by itself defeat
attribution.

`EDGE_UNATTRIBUTABLE_REASON_COARSENED` is RESERVED for the opposite reason -- it had
no legal condition. Coarsening is expressed ONLY by the truth-preserving
COMPLETE-BODY merge rule -- there is no coarsening flag on the wire; relabelling
known attribution as
`UNATTRIBUTABLE` because coarsening or sizing failed is forbidden downstream, so a
member for it would authorize prohibited behaviour or be unreachable.

A span SHALL be ATTRIBUTED only when BOTH of two SEPARATE predicates hold --
whatever state the record bytes are in. They are separate because one is about the
EVIDENCE and the other is about the WIRE SHAPE, and collapsing them makes the
"verified but unrepresentable" case impossible to express.

`binding_verifies_for_slot` -- the FULL LOCAL-BINDING RELATION, not merely an intact
sidecar:

- the binding is PRESENT, its `binding_version` is READABLE and supported, and it is
  STRUCTURALLY complete and digest-valid;
- every relational member of the frozen local-binding transcript MATCHES the
  surviving trusted evidence for the slot being recovered: the TRUST NAMESPACE
  (`network_scope_id`, authenticated `agent_id`), the LANE, the SPOOL GENERATION,
  the SEQUENCE, the event ID, and the record hash;
- it is CONSISTENT with the surviving commit / wrapper / receipt evidence for that
  slot, and where `record_bytes` are unavailable the append-time
  JOIN-BEFORE-BINDING invariant is what supplies the semantic provenance the bytes
  would otherwise have carried.

`span_is_representable` -- the verified evidence FITS the frozen wire identity: every
required member is present and expressible, and the evidence does not differ in a
discriminator the frozen identity cannot carry.

ATTRIBUTED requires `binding_verifies_for_slot` AND `span_is_representable`. A
binding that verifies but is NOT representable is reason row 5, not an attributed
span -- which is why representability is NOT folded into the verification predicate.

CHECKSUM VALIDITY ALONE IS NOT ATTRIBUTION. The transcript carries the namespace,
lane, generation, sequence, event ID, and record hash precisely to defeat
SUBSTITUTION, and a whole, internally intact binding TRANSPLANTED from another slot,
generation, or trust namespace satisfies "present, supported, checksum-valid,
representable" while describing different work. Attributing on that predicate would
manifest loss under the WRONG AUTHORITY -- a worse outcome than declaring it
unattributable, because the resulting evidence looks authoritative.

Vectors SHALL include, at minimum: an intact sidecar transplanted across slot,
generation, or namespace, which SHALL NOT become attributed; an existing binding
TRUNCATED before its version or required fields, which SHALL select exactly one
frozen reason; the positive control -- a correct binding, a REPRESENTABLE span, and
CORRUPT RECORD BYTES, which SHALL remain ATTRIBUTED; and a verifying binding whose
span is NOT representable, which SHALL be
`UNATTRIBUTABLE(DISCRIMINATOR_UNREPRESENTABLE)` rather than attributed.

REASON SELECTION IS TOTAL AND DISJOINT BY A FROZEN PRECEDENCE, evaluated in this
order, FIRST MATCH WINS. Several conditions can hold for one slot -- a torn tail also
has no binding, a corrupt binding may sit in an unreadable segment -- and `reason` is
hashed into `ManifestPageDigest`, so without a precedence Go and Elixir could hash
different members for identical evidence:

| # | Condition | Member |
| --- | --- | --- |
| 1 | the slot lies in the spool's TORN TAIL, so no binding was ever durably written | `EDGE_UNATTRIBUTABLE_REASON_TORN_TAIL` |
| 2 | no binding record exists for the slot, outside the torn tail | `EDGE_UNATTRIBUTABLE_REASON_BINDING_MISSING` |
| 3 | a binding exists and its `binding_version` is READABLE but unsupported (fail closed, no trial hashing) | `EDGE_UNATTRIBUTABLE_REASON_BINDING_VERSION_UNSUPPORTED` |
| 4 | a binding exists but does not VERIFY FOR THIS SLOT for any other reason -- unreadable, truncated before its version or required fields, structurally malformed, digest/checksum failure, or a failed relational match against the slot's namespace/lane/generation/sequence/event/record evidence (this is where a TRANSPLANTED sidecar lands) | `EDGE_UNATTRIBUTABLE_REASON_BINDING_CORRUPT` |
| 5 | `binding_verifies_for_slot` holds but `span_is_representable` does NOT -- the verified evidence differs in a discriminator the frozen identity cannot carry | `EDGE_UNATTRIBUTABLE_REASON_DISCRIMINATOR_UNREPRESENTABLE` |

Row 4 is deliberately the CATCH-ALL for a present binding that does not verify,
which is what makes the table TOTAL. An earlier revision scoped it to "fails its
checksum", leaving a binding that was unreadable, truncated, structurally malformed,
or relationally wrong matching NO row at all -- so a supposedly total table had a
hole exactly where substitution attacks land. Row 3 can only be reached once the
version is READABLE; a binding truncated before its version is row 4, not row 3,
because an unread version cannot be known to be unsupported.

The order is not arbitrary. TORN_TAIL precedes BINDING_MISSING because a torn tail
EXPLAINS the absent binding, and reporting BINDING_MISSING would charge a normal
crash boundary as data loss. BINDING_VERSION_UNSUPPORTED precedes BINDING_CORRUPT
because an unsupported version cannot be checksum-validated by this reader at all;
calling it corrupt would assert a defect in bytes that may be perfectly valid under
a version this reader does not implement.

ONE VECTOR PER ROW PROVES MEMBERSHIP, NOT PRECEDENCE. Shared PRECEDENCE CONTROLS
SHALL also exist:

- a torn-tail slot that ALSO has no binding, which SHALL select `TORN_TAIL` rather
  than `BINDING_MISSING`. Both conditions genuinely hold, and the frozen order
  decides.
- a binding whose version is READABLE and UNSUPPORTED, followed by an arbitrary or
  truncated remainder that would be INVALID as v1, which SHALL select
  `BINDING_VERSION_UNSUPPORTED` WITHOUT any deeper parsing or checksum validation.
  This vector tests the DISPATCH, not a two-condition overlap: under fail-closed
  no-trial-hashing, "the checksum fails" is not a defined predicate for a grammar
  this reader does not implement, so a vector asserting both an unsupported version
  and a failing checksum would be asserting a condition that cannot be established.
  What is being proven is that the reader stops at the version.

THE REPLACEMENT TOMBSTONE-SCOPE TRANSCRIPT, under the unchanged
`RecoveryScopeDigestVersion = 1` and body kind `0`, is:

```
u64(version) u64(0) bytes(recovery_id) bytes(prior_spool_id) bytes(new_spool_id)
bytes(manifest_root_sha256) u64(manifest_page_count)
```

It EXCLUDES `reason`, `detected_at_unix_nano`, and `digest_version`, which are
validated separately and are not part of the authorized scope -- unchanged from the
retired grammar -- and it no longer covers `lost_from_sequence`,
`lost_through_sequence`, or `coarsened`, all removed by this task. Because the
version stays `1`, both runtimes MUST regenerate the same golden from this exact
order.

`RecoveryDigestVersion` and `RecoveryScopeDigestVersion` BOTH STAY `1`. The grammar
is an unshipped candidate rewritten atomically; bumping a version would preserve a
compatibility story for bytes no agent has ever emitted.

`RecoveryResolvedV1.applied_through_sequence` KEEPS tag `3` and is FROZEN as the
consumer's DURABLY APPLIED CONTIGUOUS PREFIX over the ALLOCATED sequence space: the
highest S such that every allocated sequence at or below S is either durably applied
by the consumer transaction, or ABSENT FROM a validated COMPLETE span union. The
union is the LOST set, so only absence from a complete union establishes not-lost.
This is the frozen meaning; if it proves unimplementable that is a SPEC AMENDMENT,
not an implementation-time choice between alternatives.

#### Scenario: Spans are the only loss declaration
- **WHEN** a manifest page declares loss
- **THEN** it SHALL do so ONLY through `classification_spans`
- **AND** a page carrying a separate lost-range or affected array SHALL be
  rejected

#### Scenario: Span list is well-formed
- **WHEN** a page's classification spans are validated
- **THEN** an overlap, a duplicate, or an out-of-order span SHALL be rejected
- **AND** a page carrying no spans SHALL be rejected

#### Scenario: Ordering is total across the chain
- **WHEN** page N's last span ends at or above page N+1's first span's start
- **THEN** the manifest SHALL be rejected

#### Scenario: A gap means not lost
- **WHEN** a sequence falls between two spans, within a page or across a boundary
- **THEN** it SHALL be read as NOT lost
- **AND** the manifest SHALL NOT be rejected for the gap

#### Scenario: Extent is derived, never declared
- **WHEN** a page declares its extent in a field separate from its spans
- **THEN** the page SHALL be rejected
- **AND** a page's extent SHALL be read as its first span's lower bound through
  its last span's upper bound

#### Scenario: A span interval is primitively valid
- **WHEN** a span carries `from_sequence == 0` or `through_sequence < from_sequence`
- **THEN** it SHALL be rejected regardless of its position in the ordering

#### Scenario: Passive carries its delivery interval
- **WHEN** a lost sequence held a passive record
- **THEN** its span SHALL carry that physical interval
- **AND** SHALL assert no produced target range

#### Scenario: Grammar is frozen before use
- **WHEN** an implementation consumes the classification spans
- **THEN** enum numbers, fields, bounds, unknown handling, digest version, and
  the Appendix A transcript SHALL already be frozen

### Requirement: The authoritative assignment record owns the MTR expectation
An append-only, SCHEDULER-authored `SweepAssignmentRecordV1` SHALL be the authority
for what an assignment attempt was authorized to cover. Every record SHALL carry a
REQUIRED `SweepMtrExpectationV1` submessage holding BOTH `ordinal_count` AND
`ordinal_range_commitment`.

An ABSENT expectation SHALL be rejected and SHALL NOT be read as zero. Zero is an
assignment that admits no MTR and still owes the canonical zero-leaf completion
proof; absent is a record that never stated what it expected, and treating the two
alike turns a missing authority into an implicit waiver.

`ordinal_count == 0` and a 32-ZERO-byte `ordinal_range_commitment` SHALL be required
to agree in BOTH directions. This biconditional is what makes the zero-MTR rule
CHECKABLE: the commitment is an additive multiset hash and cannot be inverted to a
count, so without a carried count "32 zero bytes means no MTR admitted" is
unfalsifiable.

The count SHALL be CARRIED, never DERIVED. It SHALL NOT be taken from the producer's
`SweepExecutionEventV1` counters (producer-self-reported, the hole the mandatory
completion proof closes), from `ordinal_range_commitment` (not invertible), or from
`TargetRangeV1.mtr_admission_budget` (a CEILING, not an exact count).

A completion proof for an assignment attempt SHALL verify against THAT ASSIGNMENT's
expectation. `ScheduledPlanHeaderV1.mtr_ordinal_range_commitment` remains the
PLAN-WIDE commitment and SHALL NOT be used as the per-attempt authority: a plan may
be divided across assignments, so the two are equal only when one assignment covers
the whole plan.

An assignment SHALL cover EXACTLY ONE plan range in v1 and SHALL name it directly as
`target_range_id` + `target_range_sha256`, both REQUIRED. It SHALL NOT be a
self-reported field of the producer's lifecycle event, and it SHALL NOT be an opaque
set commitment: a non-invertible digest cannot say WHICH ranges were assigned, so it
would be verifiable only for length. The retired `range_root_sha256` (tag 20,
reserved by number and name) was exactly that defect on the lifecycle event.

FROZEN v1 ORDINAL MODEL. Each plan range SHALL own ONE CONTIGUOUS plan-global ordinal
window. `TargetRangeV1` SHALL carry the EXACT admitted MTR count with REQUIRED
PRESENCE (0 legal and distinct from absent); `mtr_admission_budget` remains a CEILING
only and the count SHALL NOT exceed it, nor SHALL the count ever be DERIVED from it.
`SweepMtrExpectationV1` SHALL carry `plan_ordinal_offset` with REQUIRED PRESENCE,
because offset 0 is the first range's legal window and MUST be distinguishable from
an unset field. Completion-leaf ordinals SHALL remain LOCAL `{1..ordinal_count}`; the
plan-global ordinal is `plan_ordinal_offset + local_ordinal`, and membership SHALL be
hashed as `(plan_ordinal_offset + local_ordinal, target_range_sha256)`. In v1 a retry
or supersession SHALL replay the SAME COMPLETE range window; sparse remainders and
fan-out splitting are NOT v1 and require a bounded subset representation with its own
frozen grammar.

BOTH the assignment's `ordinal_range_commitment` AND the plan header's plan-wide
`mtr_ordinal_range_commitment` SHALL be RECOMPUTED from committed plan data and
compared, never accepted as carried bytes. The count and the range digest DETERMINE
the assignment value, and the plan-wide value is the ADDITIVE SUM of every range's
window -- which is what makes a split plan verifiable without renumbering any
attempt. A carried value nothing derives is self-asserted authority.

The TOTAL admitted MTR ordinals across ONE plan SHALL NOT exceed
`MaxPlanMtrOrdinals = 1048576` (2^20), and every implementation SHALL enforce it.
This is a WORK ceiling distinct from `MaxMtrCompletionOrdinals` (2^31), which bounds
what the ordinal space can REPRESENT: recomputing a commitment costs one hash per
ordinal, so without this bound a compact plan could demand billions of SHA-256
operations inside a validator. The bound SHALL be decided BEFORE any hashing, so an
over-budget plan costs a walk rather than a fold. A ceiling enforced in only one
runtime is a DIVERGENCE, not a safeguard, so shared vectors SHALL cover exactly the
limit (accepted) and the limit plus one (rejected).

The relation SHALL reject: ordinal-space overflow; a plan total over
`MaxPlanMtrOrdinals`; an `ordinal_count` that is not the
selected range's admitted count; a count exceeding the range's admission budget; an
absent or wrong `plan_ordinal_offset`; a commitment that is not the recomputed window;
and a range identity whose digest is not the plan's.

The plan header SHALL NOT commit an assignment epoch. `assignment_epoch` (tag 9) is
RETIRED and reserved by number and name: the plan is IMMUTABLE while reassignment
ADVANCES the epoch without changing the plan, so committing it inside the plan's
content-addressed header made the two contradict each other. The monotonic authority
epoch lives on assignment records and capabilities.

#### Scenario: A second, non-prefix assignment is representable
- **WHEN** a plan's ranges are assigned separately and a later range's window does not
  start at ordinal 1
- **THEN** its assignment SHALL carry that window's `plan_ordinal_offset`
- **AND** its completion-leaf ordinals SHALL still be exactly `{1..ordinal_count}`

#### Scenario: The expectation is recomputed, not trusted
- **WHEN** an assignment carries an `ordinal_range_commitment` that is not the window
  recomputed from the selected plan range
- **THEN** the relation SHALL be rejected

#### Scenario: The plan work ceiling is enforced by every runtime
- **WHEN** a plan's total admitted MTR ordinals exceed `MaxPlanMtrOrdinals`
- **THEN** EVERY runtime SHALL reject it
- **AND** the verdict SHALL be reached without computing the commitment

#### Scenario: The budget is a ceiling, never a count
- **WHEN** a range's admitted MTR count exceeds its `mtr_admission_budget`
- **THEN** the plan SHALL be rejected
- **AND** the count SHALL NOT be derived from the budget

#### Scenario: An absent ordinal offset is not offset zero
- **WHEN** an expectation omits `plan_ordinal_offset`
- **THEN** it SHALL be rejected rather than read as the first range's window

#### Scenario: The plan header commits no assignment epoch
- **WHEN** reassignment advances the authority epoch
- **THEN** the immutable plan's identity SHALL NOT change

`record_sequence` SHALL start at 1 and strictly increase per
`producer_assignment_id`; a state change SHALL be a NEW record, never an edit.
`superseded_by_assignment_id` SHALL be present EXACTLY when the state is
`SUPERSEDED`, and SHALL NOT name the record itself.

#### Scenario: An absent expectation is not zero
- **WHEN** an assignment record carries no `mtr_expectation`
- **THEN** it SHALL be rejected
- **AND** it SHALL NOT be treated as admitting zero MTR ordinals

#### Scenario: Count and commitment agree in both directions
- **WHEN** `ordinal_count` is 0 and the commitment is not 32 zero bytes, or the
  commitment is 32 zero bytes and `ordinal_count` is not 0
- **THEN** the record SHALL be rejected

#### Scenario: The per-attempt authority is the assignment, not the plan
- **WHEN** a completion proof is verified for an assignment attempt
- **THEN** the expected count and commitment SHALL come from that assignment's
  expectation
- **AND** the plan header's commitment SHALL NOT be substituted for it

#### Scenario: An append-only record is never edited
- **WHEN** an assignment changes state
- **THEN** a NEW record with a higher `record_sequence` SHALL be appended
- **AND** `record_sequence` 0 SHALL be rejected

#### Scenario: A supersede link is exact
- **WHEN** a record's state is not `SUPERSEDED` but it names a successor, or its
  state is `SUPERSEDED` and it names none or names itself
- **THEN** it SHALL be rejected

### Requirement: A zero-MTR completion is a mandatory canonical proof, not an absence
Every `SWEEP_EXECUTION_EVENT_KIND_COMPLETED` event SHALL carry a completion proof --
`mtr_completion_digest_version`, `mtr_completion_digest`, and `plan_root_sha256` --
INCLUDING when the plan admits no MTR targets. It SHALL NOT carry a range root:
`range_root_sha256` (tag 20) is RETIRED and reserved by number and name, because a
range binding the PRODUCER asserts about its own attempt is not evidence. The
authoritative range binding is the assignment record's `target_range_id` +
`target_range_sha256`, which resolve against the committed plan. A plan admitting
no MTR targets SHALL carry the CANONICAL ZERO-LEAF proof: `MtrCompletionDigestVersion
= 2`, `expected = 0`, no leaves, all three accumulators the 32-byte zero value, and the
ordinary root framing `SHA-256(version || expected || plan_root_sha256 ||
mtr_ordinal_range_commitment || leaf_accumulator)` still bound to `plan_root_sha256`.

`ScheduledPlanHeaderV1.mtr_ordinal_range_commitment` SHALL ALWAYS be exactly 32 bytes.
A plan admitting no MTR targets SHALL carry the empty-set multiset hash -- 32 ZERO
bytes -- and SHALL NOT carry empty bytes. Empty bytes would be a second spelling of
"no MTR" that no comparison can distinguish from an omitted commitment, and the
zero-leaf proof verifies its (zero) member accumulator against exactly this field.

The expected ordinal count and the commitment SHALL be taken from the ASSIGNMENT
RECORD's required `SweepMtrExpectationV1` (see "The authoritative assignment record
owns the MTR expectation"), never from the event's own `expected_mtr_*` /
`emitted_mtr_*` counters. Those counters are producer-reported: allowing them to establish "expected
0" would let a producer waive its own evidence, which is precisely what this
requirement exists to prevent. Field-shape validation alone SHALL NOT be treated as
verification -- it cannot distinguish a correct proof from a well-formed wrong one.

The following SHALL be rejected: any leaf presented at `expected = 0`; an omitted or
non-32-byte completion digest on a COMPLETED event; an empty, non-32-byte, or
non-matching `mtr_ordinal_range_commitment`; a digest version other than the frozen
one; and a digest that does not equal the plan-derived root, including one that is a
valid completion of a DIFFERENT plan root.

This is candidate (B) of the previously open zero-MTR decision. Candidate (A) -- no
proof required when no MTR is admitted -- is REJECTED: it would have permitted both an
absent and a present proof for one state, and would have rested the choice between
them on a self-reported counter.

#### Scenario: A zero-MTR completion still carries a proof
- **WHEN** a COMPLETED event's plan admits no MTR targets
- **THEN** it SHALL carry the canonical zero-leaf proof
- **AND** an omitted completion digest SHALL be rejected

#### Scenario: The empty-set commitment is 32 zero bytes
- **WHEN** a plan admits no MTR targets
- **THEN** `mtr_ordinal_range_commitment` SHALL be 32 zero bytes
- **AND** empty bytes SHALL be rejected

#### Scenario: A leaf cannot appear at expected zero
- **WHEN** a completion with `expected = 0` presents any leaf
- **THEN** it SHALL be rejected

#### Scenario: Producer counters cannot waive evidence
- **WHEN** an event reports zero expected MTR but validated plan state expects more
- **THEN** the zero-leaf proof SHALL be rejected

#### Scenario: A zero-MTR proof is bound to its plan
- **WHEN** a zero-leaf proof is presented against a different `plan_root_sha256`
- **THEN** it SHALL be rejected

### Requirement: MTR completion disposition is one generated enum
The MTR completion leaf's terminal disposition SHALL be declared ONCE, as a
generated protobuf enum `MtrCompletionDisposition`, with these exact
Buf-compatible symbols and frozen numbers:

- `MTR_COMPLETION_DISPOSITION_UNSPECIFIED = 0`
- `MTR_COMPLETION_DISPOSITION_TRACE_ALLOCATED = 1`
- `MTR_COMPLETION_DISPOSITION_NOT_ADMITTED = 2`
- `MTR_COMPLETION_DISPOSITION_PROBE_FAILED = 3`
- `MTR_COMPLETION_DISPOSITION_QUARANTINED = 4`
- `MTR_COMPLETION_DISPOSITION_SCHEDULER_LOST = 5`

The proto enum SHALL be the SOLE declaration. Go and Elixir are CONSUMERS: the Go
`MtrTerminalDisposition` constants and the Elixir integer guards SHALL be replaced
by references to the generated enum, and no document SHALL describe the values as
pinned in `domain.go`.

This is not tidiness. The disposition number is hashed INTO the frozen completion
leaf preimage, so the numbering is part of the digest grammar. It was previously
written twice and generated from nothing -- as a Go `iota` block
(`MtrTerminalDisposition`) and as literal integers in Elixir guards -- which is
exactly the hand-maintained numeric parity that can silently diverge. Two
implementations that disagree by one produce two different completion roots for
the same completion, and the disagreement surfaces as an unexplained proof
mismatch rather than as a compile error. The generated enum now exists and both
runtimes consume it (task 1.4's disposition sub-target); the rule above is what
keeps a future runtime from reintroducing a local copy.

`MtrCompletionDisposition` SHALL be distinct from the per-hop `MtrOutcome` and
SHALL NOT reuse its numbering. They describe different things -- what happened to
a planned MTR ordinal versus what a probe observed at a hop -- and collapsing them
would make the leaf grammar depend on an enum that evolves for unrelated reasons.
"SHALL NOT reuse its numbering" governs the MAPPING, not the number space: both
enums allocate small integers and MAY coincide at a number (`PROBE_FAILED` is 3
in both), and the frozen members above are themselves the authority on which
number carries which meaning. What is forbidden is adopting `MtrOutcome`'s
symbol-to-number assignment or reading one enum's value through the other --
`NOT_ADMITTED` is 2 here and 5 there, so a consumer that conflates them
mis-hashes the leaf.

No new leaf message SHALL be introduced: the disposition is a field of the
existing completion leaf grammar. `MTR_COMPLETION_DISPOSITION_TRACE_ALLOCATED`
SHALL be the ONLY value carrying a `trace_id`.

The disposition SHALL be a CLOSED SET at the leaf. Zero, negative, and
unknown-positive values SHALL be rejected BEFORE the value is widened to `u64` and
hashed -- otherwise an unrecognised number silently enters the frozen preimage and
produces a root no other implementation can reproduce. A value declared in a LATER
proto revision SHALL remain rejected by this grammar until the completion grammar
version itself changes; the leaf grammar is frozen, so widening the accepted set
is a version bump, not a regeneration. Shared vectors SHALL cover `0`, `-1`, `6`,
and `999` as rejects alongside each valid member.

#### Scenario: One declaration, two runtimes
- **WHEN** either runtime evaluates a completion leaf disposition
- **THEN** it SHALL use the generated enum
- **AND** a runtime restating the numbering locally SHALL be rejected in review

#### Scenario: Disposition numbering is independent of MtrOutcome
- **WHEN** `MtrOutcome` gains or renumbers a value
- **THEN** `MtrCompletionDisposition` SHALL be unaffected

#### Scenario: Only allocated carries a trace id
- **WHEN** a completion leaf carries a disposition other than
  `MTR_COMPLETION_DISPOSITION_TRACE_ALLOCATED`
- **THEN** it SHALL carry no `trace_id`

#### Scenario: The leaf disposition is a closed set
- **WHEN** a leaf carries `0`, a negative value, or an unknown positive value
- **THEN** it SHALL be rejected BEFORE the value is hashed

#### Scenario: A later declared value does not widen a frozen grammar
- **WHEN** a value declared in a later proto revision reaches this leaf grammar
- **THEN** it SHALL be rejected until the completion grammar version changes

### Requirement: Physical byte ceilings are measured on exact received bytes
Every physical byte ceiling on a paged contract SHALL be measured against the
EXACT bytes received, never against a re-encode of the decoded message.

A ceiling checked after `proto.Marshal` of a decoded page measures what the
receiver would have written, not what the sender sent. Duplicate singular fields
collapse to the last one, and non-minimal varints for known fields re-encode
minimally, so a sender can present a page far larger than the ceiling and have it
pass. (Unknown fields are NOT an example: protobuf-Go retains and re-emits them,
so they survive the round trip.) The ceiling exists to bound what the receiver
must hold and forward, which is the received size.

This applies to every paged contract that declares a ceiling, including the
recovery manifest page and the scheduler plan page.

The scheduler plan page's ceiling is `MaxPlanPageBytes` = 128 KiB, frozen in the
bounds table alongside the record/frame bounds.

A validator that accepts DECODED messages cannot enforce this: the received bytes are
already gone by the time it runs. Every such contract SHALL therefore be enforced at a
boundary that sees the RECEIVED BYTES and bounds them BEFORE decoding, and that
boundary SHALL be the authoritative one. A size check computed from a decoded message
SHALL NOT be presented as enforcing the physical ceiling; it is at best a coarse guard
for callers that legitimately hold decoded structs.

WHICH function each runtime exposes for that boundary, and at which hop it runs, is
RUNTIME -- this requirement freezes the VALUE and the RULE, not API names. (The
current implementations are noted in the task list, not here.)

#### Scenario: Bloated page is refused
- **WHEN** a page's received bytes exceed its ceiling but its re-encode does not
- **THEN** the page SHALL be rejected

#### Scenario: The authoritative boundary takes raw bytes
- **WHEN** a runtime enforces a paged contract's physical ceiling
- **THEN** it SHALL do so on the received bytes, before decoding
- **AND** a decoded-struct size check SHALL NOT be presented as that enforcement

### Requirement: An attributed span carries one frozen assignment identity
An `ATTRIBUTED_ACTIVE` or `ATTRIBUTED_PASSIVE` span SHALL carry exactly ONE
assignment identity, frozen as `producer_assignment_id`, `run_id`, `run_shard`,
`authority_epoch`, `production_scope_id`, `scope_sha256`, and
`contract_bundle_sha256`, plus `range_sha256` on ACTIVE only. IDs and digests
travel together: the wire signs and validates each independently, and no invariant
derives one from the other.

These are the PRODUCER's names for the identity, because the manifest is authored
by the producer from what it actually wrote -- not from what a scheduler intended,
and not every producer has a scheduler.

`run_id` is INDEPENDENT of any execution identity and SHALL NOT be required to
equal one; resolving a span to an execution is a lookup against the durable
assignment mapping. The only producer/scheduler correspondences that hold are
`run_shard == execution_shard` and `authority_epoch == assignment_epoch`, and even
those are QUALIFIED BY CONTRACT AND CORRELATION VARIANT rather than universal:
`SweepObservationBatchV1` carries both fields, and among the MTR variants only
`MtrSweepContextV1` does -- `MtrScheduledCheckContextV1`, `MtrAdHocContextV1`, and
`MtrCommandContextV1` carry neither, and the existing join checks them only for the
sweep variant. A span SHALL NOT be rejected for the absence of a correspondence its
originating contract cannot express.

A span SHALL NOT embed `execution_plan_id`, because plan identity is NOT
UNIVERSAL: ad-hoc, integration, and recovery producers have no compiled plan, so a
span field for it would be absent for whole producer classes and could not be part
of one frozen identity. A scheduled producer CAN know its plan identity -- the
sweep batch carries it -- so the reason is universality, not ignorance.
Binding an assignment to the plan it was compiled from is the authoritative
assignment record's job (task 1.3), which SHALL guarantee a durable unique
assignment-to-plan binding; omitting the field here is only defensible because
that binding exists.

The correspondences that hold between the producer and scheduler namings are
`run_shard == execution_shard` and `authority_epoch == assignment_epoch`, enforced
at the append-time join for the contracts that carry them -- unconditionally for
`SweepObservationBatchV1`, and for MTR only on the sweep variant. `run_id` is NOT one of them: it is the
host-issued producer-run identity, and a signed source claim legitimately carries
a different `context_id`. A span therefore freezes the PRODUCER-side identity and
nothing more; resolving it to a scheduler execution is a lookup against the durable
assignment record (task 1.3), not a field equality.

Task 1.6a freezes the span shape and validates it STRUCTURALLY only.

`authority_epoch` SHALL be a plain `u64`, REQUIRED on every attributed span, with
no presence marker. It is ONE authority fence value -- control-plane/scheduler
issued and host-attested into `EdgeProducerContext` -- required for every accepted
producer: a record whose epoch is absent is rejected before any manifest can
attribute it. Where the work is scheduled, `assignment_epoch` IS that same fence
value, not a second epoch.

A presence-sensitive epoch SHALL NOT be introduced for spans alone. Absence IS
representable on the wire and in the semantic preimage -- `EdgeProducerContext`
declares the field optional and the preimage frames it with a presence bit -- but
it is REJECTED there, and it is representable in neither the SIGNED CLAIMS nor the
LOCAL BINDING: both claims-signing grammars and the local-binding transcript frame
a plain `u64`, and proto3 `uint64 authority_epoch` on the signed claims cannot
distinguish absent from zero. So an optional span field would carry a distinction
that cannot be authenticated and cannot survive corruption-independent local
binding. Making
it optional is a change to producer context, both signed claims, both framing
grammars, local binding, the semantic joins, fence policy, both validators, and
absent-versus-zero vectors TOGETHER, or not at all.

`ATTRIBUTED_PASSIVE` SHALL carry the identity but SHALL NOT carry `range_sha256`:
it asserts no produced target range, and a range digest would be a claim about
output it declares does not exist.

An attributed span SHALL ALSO carry the record's SIGNED SOURCE IDENTITY -- the
source authorization KIND, its `context_id`, its `source_scope_id`, and its
`source_scope_sha256` -- when the record carried a source authorization, and its
ABSENCE SHALL be part of the identity. All four are present together or absent
together; a partial combination
SHALL be rejected. The kind is required because the same UUID can name a scheduled check,
an ad-hoc scan, a command, or a sweep execution, and after record loss the
consumer cannot otherwise choose the correlation variant. Without it the tuple is not one-to-one with an
execution: two accepted records can share every other member -- including ACTIVE
`range_sha256` -- while carrying DIFFERENT signed source contexts, and a PASSIVE
record has no range discriminator at all. Merging those into one span would erase
which execution was lost, and no later lookup can recreate information the span
already merged away. The assignment mapping resolves an identity; it cannot
un-merge one.

`UNATTRIBUTABLE` SHALL carry NO assignment identity and SHALL carry its reason. A
partial identity is worse than none, because a consumer cannot distinguish a
recovered fact from a guess.

Where records are known to differ in a discriminator the frozen tuple does not
carry, the manifest SHALL NOT emit them as ATTRIBUTED evidence. Either the
discriminator belongs in the frozen identity -- if the difference affects authority
or partialization, add it -- or the evidence SHALL be classified UNATTRIBUTABLE
with the corresponding reason.

COARSENING SHALL NOT be used as permission to emit attributed evidence after
dropping a required identity member. Neither separate spans nor a page-level boolean
would preserve the missing fact -- two spans with an identical key resolve to the
same single mapping value, and a boolean cannot recreate a discriminator, which is
one reason no such boolean exists on the wire. Only TRUTH-PRESERVING COMPLETE-BODY
coarsening is permitted -- contiguous lost intervals whose classification bodies are
equal in EVERY member -- consistent with the coarsening rule elsewhere in this
specification. Same-key equality is NOT sufficient here either: it is exactly the
weaker test that would let a dropped discriminator survive as a merge. Evidence that cannot be carried is `UNATTRIBUTABLE` with
`DISCRIMINATOR_UNREPRESENTABLE`, never attributed with a member dropped.

Spans SHALL NOT be merged across differing CLASSIFICATION BODIES -- which is
stricter than differing assignment identities, because an `UNATTRIBUTABLE` body has
no assignment identity to differ in and two ACTIVE spans can share an identity while
differing in `range_sha256`. Nor SHALL they be merged when their identities differ, even when their
sequence intervals are adjacent and their classification matches.

#### Scenario: Shard and epoch agree where the contract carries them
- **WHEN** an attributed span originates from a contract that carries
  `execution_shard` and `assignment_epoch`
- **THEN** its `run_shard` and `authority_epoch` SHALL equal them
- **AND** a span from a contract carrying neither SHALL NOT be rejected for their
  absence
- **AND** its `run_id` SHALL NOT be required to equal any execution identity

#### Scenario: A span freezes producer identity only
- **WHEN** an attributed span is resolved to a scheduler execution
- **THEN** the resolution SHALL use the durable assignment record
- **AND** SHALL NOT be derived from equality between `run_id` and any execution
  identity

#### Scenario: Passive asserts no produced range
- **WHEN** a span is `ATTRIBUTED_PASSIVE`
- **THEN** it SHALL carry the assignment identity
- **AND** SHALL NOT carry `range_sha256`

#### Scenario: Unattributable carries no identity
- **WHEN** a span is `UNATTRIBUTABLE`
- **THEN** it SHALL carry a reason and NO assignment identity
- **AND** a span carrying a partial identity SHALL be rejected

#### Scenario: Different source contexts do not merge
- **WHEN** two records share every other identity member but differ in signed
  source `context_id`, or in whether one is present
- **THEN** they SHALL NOT share a span

#### Scenario: Adjacent spans of different assignments stay separate
- **WHEN** two adjacent spans share a classification but differ in assignment
  identity
- **THEN** they SHALL remain separate spans

#### Scenario: Every attributed span carries a fence
- **WHEN** an attributed span is validated
- **THEN** it SHALL carry an `authority_epoch`
- **AND** the value SHALL be the control-plane/scheduler-issued, host-attested
  fence the attributed records carried

### Requirement: The assignment mapping's key is the frozen span identity
The durable assignment mapping's KEY SHALL be the ordered pair `(trust_namespace, span_identity)`, frozen here because the attributed span omits execution and plan identity on the strength of it.

This ABI change freezes the KEY ONLY. Whether such a mapping EXISTS, and everything
it then does, is downstream runtime work with its own task -- this requirement SHALL
NOT be read as asserting the mapping's existence, which would make an ABI change
depend on runtime it does not own.

The tagged VALUE is explicitly NOT frozen here, and ownership of it moves DOWNSTREAM.
An earlier revision claimed both, which contradicted the proposal and task list and,
more importantly, was not backed by anything: no message in this change represents a
POSITIVE / EXPLICIT_NEGATIVE body or a durable negative reason, so "frozen" described
prose rather than a contract. The paragraph below therefore states what such a value
must eventually distinguish, as GUIDANCE for the downstream task that owns it, not as
a frozen shape.

The key SHALL be the ordered pair `(trust_namespace, span_identity)`:

- `trust_namespace` = (`network_scope_id`, authenticated `agent_id`) -- the same
  two members the local-binding grammar calls the trust namespace.
- `span_identity` = the attributed span's frozen identity, IN THE SAME ORDER the
  span transcript frames it, so the two cannot drift:
  `producer_assignment_id`, `run_id`, `run_shard`, `authority_epoch`,
  `production_scope_id`, `scope_sha256`, `contract_bundle_sha256`, the SOURCE
  IDENTITY (kind, `context_id`, `source_scope_id`, `source_scope_sha256`, or their
  joint absence), and, for ACTIVE, `range_sha256`.

The key is a STRUCTURED TUPLE. An earlier revision also permitted "a digest over
exactly that ordered pair, with its grammar frozen alongside", but no domain,
version, or transcript for such a digest exists, which left the option not
independently implementable -- and its field order disagreed with the span
transcript's, so the two forms would not have described the same key. If a digest
form is wanted, task 1.3 freezes it alongside the authoritative assignment record
that owns this mapping; until then the tuple is the key.
`producer_assignment_id` SHALL NOT be assumed globally unique -- which is why the
trust namespace is a named member of the key rather than assumed context.

`run_shard` and `authority_epoch` have exactly ONE wire representation on the
scheduler-authored assignment record: `execution_shard` and `assignment_epoch`. A
comparison against those key members SHALL cross that naming rather than expect
duplicate producer-named copies on the record.

The AUTHORITY-RESOLVED scheduler record is the positive authority -- PRESENTED bytes are
not self-authenticating and carry no authority until they match it -- so restating the same
two facts under producer names would create disagreement states with no adjudication
rule -- a record could carry `execution_shard` = 3 and a producer copy = 4, and nothing
would say which the mapping used. A payload variant that lacks these members lacks only
SECONDARY CORROBORATION; the mapping still compares the FULL key.

Stating the key as "exactly the span identity" would be AMBIGUOUS: the span
identity as defined does NOT include the trust namespace, while the key must, so
that phrasing permits two incompatible implementations. The pair is explicit for
that reason.

GUIDANCE FOR THE DOWNSTREAM OWNER (not frozen here): the value will need to be a
TAGGED body -- POSITIVE (execution, plan, and range identities and digests, shard,
epoch, and the contract-specific correlation operand) or EXPLICIT NEGATIVE (durable
negative evidence and reason, no positive-only fields). A single untagged schema
cannot express both, because a durable negative means there is no execution.

Its DURABLE STORAGE, replay and repair state machine, conflict resolution,
retention, garbage collection, and lookup-outcome transitions are DOWNSTREAM and
are NOT frozen here. They are runtime behaviour over a frozen key, and freezing
them alongside the wire ABI is what made the predecessor change unreviewable.

#### Scenario: The key is the full ordered pair
- **WHEN** a span is resolved through the mapping
- **THEN** the lookup key SHALL be `(trust_namespace, span_identity)` in full --
  `network_scope_id` and authenticated `agent_id`, PLUS `producer_assignment_id`,
  `run_id`, `run_shard`, `authority_epoch`, `production_scope_id`, `scope_sha256`,
  `contract_bundle_sha256`, the source identity or its joint absence,
  and `range_sha256` on ACTIVE
- **AND** a key built from the span identity ALONE SHALL be rejected: the span
  identity does not include the trust namespace

#### Scenario: Shard and epoch are compared across their two names
- **WHEN** a record's assignment identity is compared against the key's `run_shard`
  and `authority_epoch`
- **THEN** the comparison SHALL use `execution_shard` and `assignment_epoch`
- **AND** a duplicate producer-named copy on the record SHALL NOT be required

#### Scenario: The value shape is not frozen by this change
- **WHEN** a reader asks what this ABI change froze about the mapping
- **THEN** it SHALL be the KEY only
- **AND** the tagged value's shape SHALL be owned downstream

### Requirement: A compiled sweep assignment is an immutable carrier with two digests
A compiled sweep assignment SHALL be ONE immutable carrier, `CompiledSweepAssignmentV1`,
which the append-only assignment record REFERENCES rather than restates. It SHALL hold the
facts a scheduler decides when it COMPILES an assignment: config generation, typed result
format, check-set identity, traffic class, and validity window.

Restating them on every state record would need a reconciliation rule per fact. The
carrier gives each fact exactly one home.

The carrier SHALL carry TWO digests under `CompiledAssignmentDigestVersion`, with
SEPARATE frozen domain tags so neither can be presented where the other is required:

- `compiled_assignment_body_sha256` -- the canonical digest over every BODY field,
  excluding BOTH digests and the capability. This is what the capability SIGNS. A
  signature cannot cover itself.
- `compiled_assignment_sha256` -- the ARTIFACT CONTENT ADDRESS, over the body digest
  PLUS the attached capability.

A referencing record SHALL pin the ARTIFACT digest, not the body digest. A body digest
is not a content address for an artifact that also carries an authority: two carriers
with identical bodies and different capabilities -- one valid, one signed by a revoked
key -- share a body digest, so a reference pinning only the body would not say WHICH
authority it accepted.

The carrier SHALL declare a physical received-byte ceiling of 64 KiB. It is reachable
as a STANDALONE artifact, fetched by digest, so it does not inherit a containing
message's bound.

#### Scenario: The reference pins the artifact, not the body
- **WHEN** an assignment record references a carrier
- **THEN** it SHALL carry the carrier id AND the ARTIFACT digest
- **AND** two carriers differing only in their attached capability SHALL NOT satisfy
  the same reference

#### Scenario: The signed digest excludes the signature over it
- **WHEN** the body digest is computed
- **THEN** it SHALL exclude both digest fields and the capability

### Requirement: Scheduler attestation and host execution permission are separate
Scheduler attestation and host execution permission SHALL be two different capability
purposes, and neither SHALL be inferable from the other: they are two DIFFERENT decisions
by two DIFFERENT principals.

- `EDGE_CAPABILITY_PURPOSE_COLLECTION` is the SCHEDULER's ATTESTATION of what it
  compiled. It ATTESTS the scope and agent an assignment was COMPILED FOR. It SHALL
  NOT be read as permission for anyone to run that assignment.
- `EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION` is a HOST authority's PERMISSION to
  execute one compiled assignment. It SHALL be signed by an authority over the
  executing host, NEVER by the scheduler key family that signs carriers.

Collapsing them would let the scheduler grant itself host permission.

The execution grant SHALL bind ONE EXACT CARRIER, by id AND artifact digest, and is
therefore NOT reusable across carrier revisions. A grant that floated free would
authorize a recompiled carrier's config generation, result format and check set --
precisely the facts the carrier exists to pin. Recompiling requires a new grant.

The execution grant's claim SHALL be interpretable IN FULL against the assignment
record and its carrier. It SHALL NOT reuse the record-plane PRODUCTION or SOURCE
claim contracts: their full semantics -- contract id and version, registry epoch,
package digest, cost model, projected row and write bounds, origin and instance
identity -- can only be interpreted against an `EdgeRecordV1`, which an assignment
record is not. A grant reusing them could interpret only a SUBSET, leaving every
unchecked member free.

The grant's inner collection window SHALL be CONTAINED IN the envelope window that
carries it. A grant cannot be wider than the capability carrying it, and an inner
window reaching outside would authorize instants the envelope never covered. Both
bounds SHALL be positive; zero is the proto default and SHALL NOT pose as an
open-ended grant.

The grant SHALL declare a physical received-byte ceiling of 16 KiB; it travels
standalone.

#### Scenario: A scheduler key cannot mint execution permission
- **WHEN** an execution grant is presented that was issued by the scheduler key family
- **THEN** it SHALL be refused as unauthorized, a permanent rejection

#### Scenario: A grant does not carry over to a recompiled carrier
- **WHEN** a carrier is recompiled and its artifact digest changes
- **THEN** a grant naming the previous artifact digest SHALL be refused

#### Scenario: The inner window cannot exceed the envelope
- **WHEN** a grant's collection window starts before, or ends after, its envelope
- **THEN** the grant SHALL be refused, not silently intersected

### Requirement: Permitting collection now is one composed decision
Permitting an agent to collect for an assignment AT AN INSTANT SHALL require ALL of the
following to hold together, and a runtime SHALL expose it as ONE decision. It SHALL NOT
expose a constituent check in a form a caller could mistake for the whole.

1. The record/carrier relation, and the carrier's own validity, from the carrier's
   RECEIVED BYTES.
2. The scheduler's attestation over the carrier, verified against a resolved issuer
   key, with status EXACTLY valid. A compromise-revoked key verifies -- the signature
   WAS valid when made -- but SHALL NOT permit new work.
3. The host execution grant, validated in full and FRESH at the instant, against BOTH
   its envelope window and its inner collection window.
4. The CALLER's identity, obtained from the authority that performed the transport
   authentication, which SHALL affirm that the authenticated peer is EXACTLY the
   record's (`network_scope_id`, `authenticated_agent_id`) pair. An answer that is
   merely "some peer is authenticated" SHALL NOT satisfy this. Every identity on the
   record or in a capability is one the scheduler NAMED; none is evidence about who
   presented the bytes.
5. The AUTHORITATIVE record's state SHALL be exactly OPEN. Every other state --
   COMPLETED, ABORTED, LOST, EXPIRED, SUPERSEDED -- describes work that must not
   continue, and the lease and window fields say nothing about that.
6. The AUTHORITATIVE record and its COMMITTED PLAN, resolved by a key DERIVED from
   the record, not supplied by the caller.
7. The COMMITTED PLAN SHALL validate from its RAW bytes AND the authoritative record
   SHALL satisfy the assignment/plan relation against it. Without this the record, the
   carrier and the grant can all agree on a range that no committed plan contains.
8. The carrier, capability and lease windows containing the instant.

Each of these has been observed to be insufficient alone. In particular a check of
structure and time only -- with no signature verification, no state, no authoritative
position -- admits a forged signature behind a resealed digest, a compromise-revoked
key, a terminal assignment, and a superseded record that is still nominally open.

The authoritative-record lookup key SHALL be the structured tuple
(`network_scope_id`, `authenticated_agent_id`, `producer_assignment_id`), DERIVED
from the record inside the decision. An opaque caller-chosen namespace is not
checkable, so a caller could name any namespace whose authority answered
conveniently.

The resolved authority SHALL carry the COMPLETE authoritative record and the
committed plan, and the presented record SHALL equal the authoritative one IN FULL.
A projection of selected fields leaves every field it omits unconstrained --
including fields added later -- so a record differing only in an unlisted field
would pass.

The resolver SHALL ECHO the requested key, and the echo SHALL be checked BEFORE the
resolution's status is interpreted. A response carrying a different key is no
evidence about the assignment that was asked for; reading its status first would let
an answer to another question become a permanent "this assignment does not exist".
A cross-key response is unauthoritative and therefore RETRYABLE.

An unresolvable lookup (retryable) and a genuinely unknown assignment (permanent)
SHALL remain distinct outcomes.

Values a decision depends on SHALL NOT be supplied by its caller where they can be
derived or resolved instead, and every callback SHALL receive COPIES: a protobuf
bytes field aliases its backing storage, so a callback handed a slice from the
message under evaluation can rewrite fields whose signatures were already checked.

#### Scenario: A revoked key does not permit new work
- **WHEN** the attestation or the grant resolves to a compromise-revoked key
- **THEN** collection SHALL NOT be permitted
- **AND** the signature SHALL still be verifiable for audit

#### Scenario: A superseded record does not permit collection
- **WHEN** the presented record differs from the authoritative record in ANY field
- **THEN** collection SHALL NOT be permitted

#### Scenario: A terminal assignment does not permit collection
- **WHEN** the authoritative record's state is anything other than OPEN
- **THEN** collection SHALL NOT be permitted
- **AND** this SHALL hold even when the presented record is IDENTICAL to the
  authoritative one, since agreement about a terminal state is still terminal

#### Scenario: The transport must affirm the exact identity
- **WHEN** the authenticated peer is not exactly the record's network scope and agent
- **THEN** collection SHALL NOT be permitted

#### Scenario: A range absent from the committed plan does not permit collection
- **WHEN** the authoritative record does not satisfy the assignment/plan relation
  against the committed plan
- **THEN** collection SHALL NOT be permitted

#### Scenario: A cross-key resolver response is retryable
- **WHEN** the authority's response does not echo the requested key
- **THEN** the outcome SHALL be retryable, never a permanent "unknown assignment"

### Requirement: Current permission and historical verification are separate questions
A runtime SHALL distinguish "was this signature validly issued" from "may this work happen
now", and SHALL provide both.

A signature remains checkable over the bytes it covers FOR AS LONG AS THE ISSUING KEY'S
EVIDENCE IS RETAINED, which is what lets an ARCHIVED record be re-verified. Permission to
act expires on its own schedule. Conflating them yields either an archive that cannot be
re-checked once a window closes, or a lapsed grant that still permits work.

("Forever" appeared here in an earlier revision and is WITHDRAWN: it contradicted the
retention condition stated below, and a spec that carries both readings lets an
implementer pick either.)

The instant supplied to trust resolution SHALL be the CURRENT instant, and it decides
CURRENT rotation and compromise state -- NOT "was this key trusted back then". A key
used validly inside its window and compromise-revoked afterwards SHALL resolve as
historically revoked when asked at a later instant. That is what makes a revocation
discovered after the fact actionable. The SIGNED EVIDENCE INTERVAL is a separate
input and comes from the capability itself.

An API whose contract is "permission" SHALL return an error for EVERY non-valid key
status, so a caller inspecting only the error cannot fail open. An API whose contract is
VERIFICATION returns a non-valid status without an error ONLY for the statuses the frozen
matrix below permits -- HISTORICALLY_REVOKED -- and SHALL error on the rest. An earlier
revision said such an API "MAY return a non-valid status without an error" generically,
which is WITHDRAWN: it admitted INVALID and UNAVAILABLE as silent successes, contradicting
the matrix.

Historical verification remains possible ONLY while the KEY EVIDENCE is retained. A
runtime SHALL NOT claim a signature is re-verifiable after its issuing key's history has
been discarded; retention of that history is what makes the claim true, and it is a
deployment property, not a wire one.

The status matrix is FROZEN. Exactly TWO resolutions may return a VERIFIED SIGNATURE
without an error:

- VALID -- the key was validly issued and is not compromised.
- HISTORICALLY_REVOKED -- the signature verifies (it was valid when made) but trust is
  deliberately withdrawn. Reachable as audit/quarantine evidence; NEVER a permanent
  reject, and NEVER permission for new work.

The other two SHALL remain errors, and SHALL NOT be merged:

- INVALID -- unknown, never-issued, or not authorized for the requested role. PERMANENT.
- UNAVAILABLE -- the lookup could not answer. RETRYABLE.

Collapsing INVALID into UNAVAILABLE turns a rejection into a retry loop; the reverse
turns an outage into a permanent refusal.

The TRUST-POLICY EPOCH pins one immutable policy snapshot for a whole decision. The
request's epoch SHALL be NONZERO -- a zero epoch is a configuration error and SHALL fail
closed BEFORE the resolver is consulted, never as a retryable lookup failure. The
response SHALL echo it EXACTLY, and that echo SHALL be checked BEFORE the resolution's
status is interpreted: a zero or mismatched echo is a stale or cross-snapshot reply from
a revocation race, so it is UNAVAILABLE regardless of what status it carries.

#### Scenario: Only two resolutions verify without error
- **WHEN** a resolution is INVALID or UNAVAILABLE
- **THEN** it SHALL be an error, permanent and retryable respectively
- **AND** VALID and HISTORICALLY_REVOKED SHALL both return a verified signature

#### Scenario: The epoch echo is checked before the status
- **WHEN** a resolution's epoch echo is zero or does not match the request
- **THEN** the outcome SHALL be unavailable, whatever status it carried

#### Scenario: A compromise after expiry is visible
- **WHEN** a grant has expired and its key is compromise-revoked afterwards
- **THEN** historical verification at the current instant SHALL report the revocation

### Requirement: Capability trust resolution is purpose-scoped and response-bound
A trust resolver SHALL be told the ROLE a capability is being resolved for, and SHALL ECHO
it in its response. The echo is RESPONSE CORRELATION: it proves the answer belongs to the
question asked, exactly as the trust-policy epoch echo does. An unset or mismatched
echo SHALL be treated as unavailable.

The echo SHALL NOT be read as establishing that a key is authorized for that role.
AUTHORIZING (issuer, key, purpose) is a CONTRACT OBLIGATION on the resolver: it SHALL
resolve a key that is not authorized to issue the requested role as invalid, a
permanent rejection. Only the resolver holds that knowledge, so no verifier can check
it, and an implementation that skips it lets one role's key validate another.

#### Scenario: An unechoed purpose is not an answer
- **WHEN** a resolution does not echo the requested purpose
- **THEN** it SHALL be treated as unavailable, never as authorizing

### Requirement: Compression admission is frozen by value, stage, and frame shape
A ZSTD-compressed `EdgeRecordV1` payload SHALL be admitted only under the frozen
EXTRACTED-BODY BOUNDS, enforced BEFORE any decompression, and only when the payload is
exactly ONE standard Zstd frame.

THE THREE VALUES ARE FROZEN HERE, and this is their normative source. Until now they existed
only in runtime source, so every consumer asserting them -- including the Elixir sweep body
decoder -- pinned a number with nothing behind it:

- `MaxUncompressedBytes` = **33_554_432** bytes (32 MiB). The EXTRACTED-BODY output ceiling.
- `MaxCompressionRatio` = **100**. The maximum ratio of extracted output to encoded input.
- `MaxZstdWindowBytes` = **33_554_432** bytes (32 MiB). The maximum Zstd WINDOW a frame may
  advertise.

THE WINDOW CEILING IS A THIRD, INDEPENDENT LIMIT, and v1 assigning it the same value as the
output ceiling is a COINCIDENCE OF VALUE, not a rule. They bound different things: output
size is what the body costs to hold, window size is what the DECODER must retain as history
while producing it. A frame advertising a 64 MiB window while emitting 1 MiB of output
passes both the output ceiling and the ratio, and SHALL still be rejected. Without this
frozen, a runtime that admitted such a frame would diverge from one that did not, on a
record both agree is otherwise valid.

THESE ARE WORK CEILINGS ON THE EXTRACTED BODY, not physical bounds on the record. The record
and its encoded payload remain bounded by `MaxRecordBytes` (512 KiB) on RECEIVED BYTES. A
compressed payload under that physical bound may legitimately EXPAND past it -- that is the
entire point of the ratio -- so a physical bound applied to the extracted body would
permanently reject valid records.

THE STAGE IS PART OF THE FREEZE. The DECLARED-OUTPUT and RATIO bounds SHALL be evaluated on
the DECLARED sizes BEFORE the payload is decompressed, so a decompression bomb is refused without ever being expanded.
A ratio checked after expansion has already paid the cost it exists to avoid.

THE RATIO IS MEANINGLESS UNLESS `encoded_size` IS BOUND TO THE RECEIVED BYTES FIRST. It is
the denominator, so an unbound `encoded_size` buys arbitrary ratio headroom: declare a large
encoded size, pass the ratio trivially, and only the absolute ceiling still applies. The
implementation SHALL therefore reject a record whose `encoded_size` differs from the actual
payload length before evaluating the ratio.

THE DECLARATION SHALL NOT BE TRUSTED AS THE OUTCOME. `uncompressed_size` is what the bounds
are evaluated against, so the ACTUAL decoded output SHALL be required to equal it exactly. A
validator that bounds the declaration and never checks the real output has bounded a claim,
not a body.

RATIO ARITHMETIC SHALL BE OVERFLOW-SAFE. A wrapped product admits exactly the bombs the
ratio excludes, so the comparison SHALL NOT be evaluated in a width the product can exceed.
This is a property, not an accumulator width: once `encoded_size` is bound to a payload
already under the 512 KiB physical ceiling, the denominator is at most 524_288 and the
product at most 52_428_800, which any 32-bit or wider accumulator holds. The freeze is that
the binding happens FIRST -- an unbound `uint32` denominator times 100 exceeds 32 bits, so a
runtime evaluating the ratio before the binding would need a wider accumulator to stay
correct, and one that did neither would wrap.

VALIDATION SHALL NOT RESERVE THE FULL OUTPUT. The frame is validated by streaming through a
fixed scratch buffer, so refusing a 32 MiB body does not first allocate 32 MiB. That buffer
bounds the CALLER'S OUTPUT BUFFERING ONLY. It is not a bound on decoder memory, which retains
up to O(window) of history regardless -- and `MaxZstdWindowBytes` bounds that HISTORY/WINDOW
REQUIREMENT, not total decoder memory: a decoder holds tables and buffers beyond the window,
and neither runtime guarantees a ceiling on the whole of it.

EXACTLY ONE COMPRESSION LAYER IS ADMITTED. Once decoded, the extracted bytes are a CONTRACT
MESSAGE and SHALL NOT be interpreted as another compressed envelope, so there is no
RECURSIVE COMPRESSION to bound and no runtime may introduce one. This is a rule about LAYERS,
not about passes: a runtime MAY validate the frame and materialize the body in separate
decode passes, which is implementation topology rather than an ABI property. (Protobuf
MESSAGE recursion is a different limit entirely and is owned by 1.5-a.)

Decoding SHALL use no dictionary.

#### Scenario: The extracted-body bounds are refused before expansion
- **WHEN** a record declares an `uncompressed_size` of zero, above 33_554_432, or above
  `encoded_size` times 100
- **THEN** it SHALL be rejected WITHOUT decompressing the payload
- **AND** the same rejection SHALL apply whether or not the frame would have decoded

#### Scenario: A declared size that the frame does not produce is refused
- **WHEN** a payload decodes to a byte count different from `uncompressed_size`
- **THEN** it SHALL be rejected
- **AND** this SHALL hold in both directions -- fewer bytes and more bytes

#### Scenario: The payload is exactly one Zstd frame
- **WHEN** a payload carries trailing bytes after a valid frame, a second concatenated frame,
  an empty concatenated frame, or a skippable frame
- **THEN** it SHALL be rejected as trailing data
- **AND** the check SHALL parse the FRAME STRUCTURE and require the frame to end at exactly
  the payload length, because a decode-side output-size check cannot see these: a conforming
  decoder consumes no-output trailing frames transparently, producing the declared byte count
  from a payload that carries more than one frame

#### Scenario: An oversized advertised window is refused on its own
- **WHEN** a frame advertises a required window ABOVE 33_554_432 bytes
- **THEN** it SHALL be rejected BEFORE expansion
- **AND** this SHALL hold even when the decoded output size and the compression ratio are
  both within their ceilings, since the window bounds decoder history rather than output
- **AND** a frame advertising exactly 33_554_432 bytes SHALL be accepted, so the boundary is
  inclusive and the two vectors sit either side of it

#### Scenario: The ratio denominator is bound to received bytes
- **WHEN** `encoded_size` differs from the actual payload length
- **THEN** the record SHALL be rejected before the ratio is evaluated

### Requirement: Only a raw-byte plan boundary may claim physical enforcement
A plan's PHYSICAL ceilings and wire hygiene SHALL be claimed ONLY by a boundary that sees
the RECEIVED BYTES and bounds them BEFORE decoding. The plan header's ceiling SHALL be
512 KiB, alongside the page ceiling of 128 KiB, both on received bytes.

This freezes a BEHAVIOURAL rule, not API topology. Decoded relational helpers -- validators
that take an already-decoded header and pages and check the plan's internal relations --
MAY exist and are useful; both current runtimes expose them. What such a helper SHALL NOT
do is CLAIM to enforce a physical ceiling or wire hygiene, because it cannot: a
duplicate-field header over the bound collapses on decode and reaches it looking compliant.
An earlier revision of this requirement demanded exactly one entry point and forbade
decoded-header APIs outright, which froze a shape neither signed-off runtime has.

A caller that needs the physical guarantee SHALL obtain it from the raw boundary. A
runtime SHALL make clear, at each such helper, which guarantee it does NOT provide.

WHAT IS FROZEN IS PER-ARTIFACT: each artifact's raw size SHALL be checked BEFORE THAT
ARTIFACT is decoded. Decoding an artifact and bounding it afterwards performs exactly the
work its bound exists to prevent.

WHAT IS NOT FROZEN is the cross-artifact ORCHESTRATION: whether every size in a plan is
preflighted before any decode, whether the header's failure takes precedence over a page's,
and what a raw entry point returns. Those are RUNTIME choices, and the two runtimes make
them differently today -- Go preflights the whole plan and validates the header before
decoding pages; Elixir decodes the header, then the pages, and validates the plan relation
afterwards, so an unsupported header with a malformed page reports the page. Both satisfy
the byte rule.

An earlier revision froze the Go orchestration as normative, which made the signed-off
Elixir non-conforming for a difference that changes no wire artifact and no accept/reject
outcome -- only which of two rejections is reported first. Freezing an implementation's
call order because it is the one that happened to be written first is the failure this
requirement now avoids.

Preferring the header's failure IS better diagnostics, and Go's tests pin it; it is stated
here as GUIDANCE, not a SHALL.

#### Scenario: A decoded helper does not claim the physical ceiling
- **WHEN** a decoded-input plan validator accepts a header whose RECEIVED bytes exceeded
  the ceiling but whose decode collapsed below it
- **THEN** that is NOT a defect in the helper
- **AND** the helper SHALL NOT be presented as enforcing the physical ceiling

#### Scenario: An artifact is bounded before it is decoded
- **WHEN** an artifact's received bytes exceed its ceiling
- **THEN** it SHALL be rejected without being decoded

#### Scenario: Report-order differences are conformant
- **WHEN** two runtimes reject the same plan for different reasons because one preflights
  the whole plan and the other decodes page-by-page
- **THEN** both SHALL be conformant, provided each bounded every artifact before decoding it
- **AND** the plan SHALL be rejected by both

### Requirement: A sweep batch's execution source selects its authority kind and context operand
A record whose payload is a `SweepObservationBatchV1` SHALL carry SIGNED SOURCE AUTHORITY in
its ENCLOSING `EdgeRecordV1.source_authorization`, and the BODY's `source` SHALL select both
the `EdgeSourceAuthorizationKind` that authority must carry and WHICH body field the signed
context operand is compared against.

THE BATCH CANNOT CARRY AUTHORITY. `SweepObservationBatchV1` has no authorization field and no
signature; authority lives one level up, on the record that encloses it. An earlier revision
said the batch "SHALL carry signed source authority", which named a field that does not exist.
The correlation is precisely a join ACROSS that boundary -- body fields against the enclosing
record's signed claims -- and collapsing the two messages into one obscures the only thing the
rule does.

Source authority is OPTIONAL at the record level, and that optionality SHALL NOT be read
as making it optional here: a sweep body without it has no signed statement of what was
authorized, so there is nothing for the correlation to compare against. A sweep record
lacking source authority SHALL be rejected.

The mapping is FROZEN and EXHAUSTIVE over the declared non-zero sources:

| `SweepExecutionSource` | `EdgeSourceAuthorizationKind` | signed context operand | `source_run_id` |
| --- | --- | --- | --- |
| `SCHEDULED_SWEEP` (1) | `SCHEDULED_SWEEP` (1) | `execution_id` | FORBIDDEN |
| `SWEEP_PROFILE` (2) | `SWEEP_PROFILE` (2) | `execution_id` | FORBIDDEN |
| `AD_HOC` (3) | `AD_HOC` (4) | `source_run_id` (scan_run_id) | REQUIRED |
| `ON_DEMAND` (4) | `ON_DEMAND` (5) | `source_run_id` (command_id) | REQUIRED |
| `SCHEDULED_CHECK` (5) | `SCHEDULED_CHECK` (3) | `source_run_id` (check_id) | REQUIRED |

`source_run_id` is REQUIRED exactly where the signed `context_id` names a source-side run
rather than the execution, and FORBIDDEN otherwise. Permitting it in the forbidden
positions would leave a second, unchecked correlation candidate on the wire: a consumer
could bind on it while the validator bound on `execution_id`, and nothing would say which
was authoritative. Where it is required it SHALL be a canonical UUID.

The KIND NUMBERS deliberately do not line up. Only TWO ordinals coincide --
`SCHEDULED_SWEEP` and `SWEEP_PROFILE`; `AD_HOC`, `ON_DEMAND` and `SCHEDULED_CHECK` all
differ. An implementation correlating by NUMBER rather than by this table would accept an
ad-hoc body under scheduled-check authority. The table is the contract.

`SWEEP_EXECUTION_SOURCE_UNSPECIFIED` (0) has NO authorized kind and SHALL be rejected
before any other correlation runs. It is the proto default, so accepting it would let an
unset field select a mapping.

`EDGE_SOURCE_AUTHORIZATION_KIND_INTEGRATION_RUN` and `..._RECOVERY_CONTROL` are NOT in the
range of this mapping. A sweep record presenting either SHALL be rejected, and this
requirement SHALL NOT be read as reserving them for later sweep use.

BOTH RUNTIMES SHALL PIN THE MAPPING'S EXACT MEMBERSHIP as an inventory, in addition to any
behavioural vectors. Vectors sample; only an exhaustive inventory shows that the mapping is
TOTAL over the declared sources, that it is INJECTIVE, and that the two unreachable kinds
are absent from its range. A vector set cannot establish absence.

The inventory has TWO parts, and only one of them is descriptor-derived. The SOURCE and KIND
columns SHALL be checked against the generated enum descriptors, so a renumbering or a new
member fails. The CONTEXT OPERAND and `source_run_id` DISPOSITION columns are NOT enum
domains and no descriptor knows them: they SHALL be pinned as LITERAL table entries, exactly
as the frozen field inventories elsewhere in this change are literals a human wrote. A
descriptor check over the operand column would assert nothing.

#### Scenario: A body's source must match the signed kind
- **WHEN** a sweep record's body `source` maps to a kind other than the one its signed
  source authority carries
- **THEN** the record SHALL be rejected

#### Scenario: A sweep batch without source authority is rejected
- **WHEN** a sweep record carries no source authorization
- **THEN** it SHALL be rejected, whatever its body says

#### Scenario: source_run_id is required or forbidden, never optional
- **WHEN** a body carries `source_run_id` under `SCHEDULED_SWEEP` or `SWEEP_PROFILE`
- **THEN** the record SHALL be rejected
- **AND WHEN** it omits `source_run_id` under `AD_HOC`, `ON_DEMAND` or `SCHEDULED_CHECK`
- **THEN** the record SHALL be rejected
- **AND** both SHALL be decided by BODY VALIDATION, without consulting signed authority

#### Scenario: The source selects which body field the signed context is compared against
- **WHEN** a `source_run_id` row's body has `execution_id != source_run_id` and the signed
  `context_id` equals the NON-SELECTED `execution_id`
- **THEN** the record SHALL be rejected, even though the context matches a field the body
  carries
- **AND WHEN** an `execution_id` row's body omits `source_run_id`, as that row requires, and
  its `execution_id` differs from the signed `context_id`
- **THEN** the record SHALL be rejected
- **AND** the mismatch SHALL NOT be shown by adding `source_run_id` to an `execution_id` row,
  which would breach the disposition rule instead

#### Scenario: An unspecified source is rejected before correlation
- **WHEN** a sweep body carries `SWEEP_EXECUTION_SOURCE_UNSPECIFIED`
- **THEN** the record SHALL be rejected, and no other correlation SHALL be consulted

#### Scenario: An unreachable kind is refused, not merely unmapped
- **WHEN** a sweep record's source authority carries `INTEGRATION_RUN` alongside an
  otherwise-valid body
- **THEN** the record SHALL be rejected at CORRELATION, not only absent from the inventory
- **AND WHEN** it carries `RECOVERY_CONTROL` instead
- **THEN** the record SHALL be rejected by the RESERVED RECOVERY LANE, which runs first, and
  the vector SHALL assert that rejection rather than a correlation one

### Requirement: The sweep correlation is proven by gate-owned vectors, labelled where frozen
Every sweep correlation rule SHALL be proven by SHARED cross-language vectors. Each
CORRELATION-OWNED negative SHALL differ from a committed POSITIVE control in EXACTLY ONE
CORRELATION COMPARISON, and SHALL be carried by a SIGNATURE-VALID enclosing record.

THE ONE-COMPARISON RULE IS SCOPED, in two ways that the gate table and its scenarios detail
and that this opening SHALL NOT overrule:

- vectors owned by an EARLIER gate change one INPUT and are refused there; the correlation
  comparisons downstream of them are UNDEFINED, not required to hold;
- `source_authority_absent` is the exception WITHIN correlation. It reaches correlation and
  fails the PRESENCE check, which leaves EVERY claim relation undefined at once -- there are
  no claims to compare against. It is one comparison in the only sense available, and a rule
  demanding it differ in exactly one claim relation would be unsatisfiable.

A negative that breaks two things at once proves whichever rule runs first, which is not the
rule it is named after.

"RE-SIGNED RECORD" IS NOT A THING THAT EXISTS, and an earlier revision requiring one was
demanding the impossible. `EdgeRecordV1` carries NO signature field; signatures live on
`EdgeSignedCapabilityV1.signature`, over that capability's own canonical signing bytes. What
a negative SHALL do is:

REBUILD THE RECORD IN THIS EXACT ORDER. The order is itself frozen, because two of these
steps consume the output of others and a plausible-looking rearrangement silently produces an
invalid record:

1. APPLY every mutation the vector intends -- to the body, to record fields, to wrapper
   fields, and to capabilities;
2. IF THE BODY CHANGED: re-encode it to the exact bytes the vector carries, re-compress if
   the record's `compression` is not NONE, update `encoded_size` to the payload length and
   `uncompressed_size` to the decoded length (equal when compression is NONE), and recompute
   `payload_sha256` over the exact encoded payload;
3. RE-SIGN every capability whose COMPLETE SIGNING PREIMAGE changed -- not only those whose
   claims changed;
4. RECOMPUTE `semantic_envelope_sha256` LAST;
5. REBUILD downstream authority that binds record bytes the vector changed.

STEP 4 IS LAST BECAUSE THE SEMANTIC PREIMAGE CONTAINS CAPABILITY SIGNATURES. It frames each
capability field-by-field INCLUDING its `signature` bytes, and frames the source authorization
with a PRESENCE marker. Two consequences an earlier revision got wrong by recomputing the
digest before re-signing:

- computing the semantic digest and THEN re-signing leaves the digest stale, so the record
  fails its own envelope check and the vector never reaches the gate it is named for;
- REMOVING SOURCE AUTHORITY CHANGES THE SEMANTIC PREIMAGE WITH NO BODY CHANGE AT ALL, via that
  presence marker. A rebuild conditioned only on "did the body change" would skip step 4 and
  produce a stale digest for exactly the `source_authority_absent` vector.

STEP 3 IS THE COMPLETE PREIMAGE, NOT THE CLAIMS. A capability's signing bytes cover its
version, issuer id, issuer key id, algorithm, purpose, BOTH window endpoints and its claims. A
vector that shifts a capability's validity window changes no claim and still invalidates the
signature, so "re-sign when claims change" would leave it unsigned-for-its-content.

STEP 2's SIZE FIELDS ARE NOT AN AFTERTHOUGHT: `encoded_size` MUST equal the payload length and
`uncompressed_size` the decoded length, so a body mutation that changes length -- which nearly
every one here does, since adding or removing `source_run_id` changes it -- otherwise leaves a
record that fails WHOLE-RECORD VALIDATION.

Sealing matters for the same reason re-signing was thought to: an unsealed mutation is refused
by the payload or envelope digest check before any correlation is consulted.

EVERY NEGATIVE SHALL DECLARE ITS OWNING GATE, and the last-gate obligation applies to the
CORRELATION vectors only. "Every negative reaches correlation" would be UNSATISFIABLE: some
of the vectors this requirement demands are refused, correctly and by design, by an EARLIER
gate, and no re-signing can carry them further.

| owning gate | vectors it owns | why it cannot reach correlation |
| --- | --- | --- |
| ENUM ADMISSION | `SWEEP_EXECUTION_SOURCE_UNSPECIFIED` | the value is outside the field's admitted domain, so it is refused as an ENUM before any field is interpreted |
| BODY VALIDATION | every `source_run_id` DISPOSITION vector (forbidden-presence, required-absence, malformed) | decidable from the batch ALONE -- `source` and `source_run_id` are fields of the SAME message and no signed authority is consulted to compare them |
| RECOVERY LANE | source authority carrying `RECOVERY_CONTROL` | the reserved-lane rule refuses recovery authority on a non-recovery route, ahead of correlation |
| CORRELATION | ABSENT source authority; kind mismatch; selected-context mismatch; `INTEGRATION_RUN`; every PER RELATION and endpoint vector | each compares a body field against a SIGNED claim, so nothing earlier can decide them |

ABSENT SOURCE AUTHORITY IS CORRELATION-OWNED, not a structural omission caught earlier. The
field is OPTIONAL at the record level, so no structural gate can require it; the sweep
correlation is the first thing that asks for it, and it carries the full last-gate
obligation.

THE DISPOSITION IS BODY-OWNED BECAUSE IT IS BODY-DECIDABLE, and an implementation SHALL NOT
defer it to correlation. Deferring a body-decidable rule past the body validator means a
malformed batch is carried into authority comparison, where the reason it is refused depends
on which mismatch is noticed first. The line is drawn by what the rule READS, not by which
requirement introduced it: `source` and `source_run_id` are fields 14 and 15 of
`SweepObservationBatchV1`, and the whole disposition column is a function of those two.

UNSPECIFIED IS OWNED BY ENUM ADMISSION, not by body validation, and the distinction is not
cosmetic. Its admitted domain is the five non-zero members; a zero value is outside that
domain and is refused as an ENUM DOMAIN violation, which is a different claim from "the body
is malformed". The two runtimes reach that conclusion in different places -- Go's sweep body
validator refuses an unknown source inline, Elixir's enum-admission policy excludes the member
before the body is interpreted -- and BOTH conform, because the semantic owner is the enum
domain either way. A requirement naming body validation as the owner would make Elixir's
placement non-conforming for no reason.

The UNSPECIFIED rejection and the recovery-lane rejection are PRE-EXISTING behaviour that this
requirement merely locates. The disposition rejections are NEW: `source_run_id` is currently
not read by any validator at all, so the body validator SHALL be extended to enforce presence,
absence and canonical form.

A vector filed under the wrong gate is a false coverage claim: it would be refused whether or
not the rule it is named after exists. `INTEGRATION_RUN` and `RECOVERY_CONTROL` are BOTH
outside the mapping's range but are NOT owned by the same gate, and a design that treated them
as one pair would mis-file one of them.

FOR THE CORRELATION VECTORS, "OTHERWISE VALID" IS A CHECKABLE CLAIM, NOT A DESCRIPTION. Each
SHALL be shown to pass EVERY gate that precedes correlation, IMMEDIATELY BEFORE the
correlation call that refuses it. The composed sweep validator's gates, in the order it runs
them, are:

1. WHOLE-RECORD VALIDATION, including signature verification;
2. CONTRACT DISPATCH -- the record's `EdgeOutputContractRef` must equal the expected one in
   all four members: contract id, contract version, bundle digest, registry epoch;
3. FRAMING FAMILY -- the record's `payload_family` must be the one family this typed ingress
   frames. It runs BEFORE extraction and decode, so a wrongly framed record is never read as a
   contract message;
4. BOUNDED PAYLOAD EXTRACTION -- the inner payload is unwrapped and decompressed under its
   size bounds;
5. BOUNDED DECODE of the extracted bytes into the batch message;
6. BODY VALIDATION, which is where the sweep `source` enum is admitted;
7. correlation.

RAW WIRE HYGIENE IS NOT IN THIS LIST because it is EXTERNAL to the composed validator -- it
runs on received bytes before this entry point, and a vector reaches step 1 having already
passed it. ENUM ADMISSION IS NOT A SEPARATE LEADING STEP either: for the sweep `source` it is
part of step 6 in Go, while Elixir admits it before interpreting the body. The gate table above
records enum admission as UNSPECIFIED's semantic owner precisely because the two runtimes place
it differently; this list is about ORDER within the Go composed path, and asserting a global
enum-first order would contradict it.

CONTRACT DISPATCH DOES NOT CHECK PAYLOAD FAMILY, and deliberately does not. An earlier
revision of this list said it checked "payload family and output-contract reference"; it checks
only the contract reference. THE TWO ANSWER DIFFERENT QUESTIONS: the contract selects the
semantic validator and the projector, while the family selects which typed ingress a record may
enter. That is why the family is step 3 above rather than part of step 2, and why no
registry-wide contract-to-family table exists.

An earlier revision of this paragraph called the binding a REAL GAP and offered task 1.5 two
outcomes -- freeze a contract relation, or record that v1 needs none. BOTH ARE WITHDRAWN: the
resolution is neither. See "The payload family is a framing discriminator bound to the typed
entry point".

STEPS 2, 4 AND 5 ARE EASY TO OMIT AND WERE OMITTED by an earlier revision, which jumped from
record validation to body validation. They are not bookkeeping: a vector that mutates a sweep
body changes its length and its digest, so a nominally correct correlation vector can die at
contract dispatch, at a payload bound, or in the decoder while passing every control the list
named -- and would then be recorded as proving a correlation rule it never reached.

The REBUILD obligations are stated ONCE, as the numbered sequence in this requirement's
opening, and are deliberately NOT paraphrased here. A paraphrase is how the withdrawn
claims-only rule kept coming back: this paragraph previously restated it, one requirement after
the sequence that replaced it. Follow the numbered steps.

VECTORS OWNED BY AN EARLIER GATE SHALL ASSERT THAT GATE'S OWN REJECTION rather than a
correlation label they never reach. Where that gate has a FROZEN PORTABLE LABEL -- the whole
`source_run_id` disposition column does -- the vector SHALL assert it exactly.

WHERE IT DOES NOT, THE VECTOR SHALL ASSERT ONLY THAT THE OWNING GATE REFUSED, and the manifest
SHALL record it as an UNLABELLED rejection. This is an explicit permission, not an oversight:
enum admission and the recovery lane are PRE-EXISTING gates whose reasons are typed
per-runtime -- Go returns sentinel errors, Elixir a tagged tuple -- and no portable label is
frozen for either. Demanding an exact label for them would be unsatisfiable against the very
contract that excludes them.

A manifest SHALL NOT present an unlabelled rejection as exact-reason parity, and SHALL mark
which vectors are unlabelled, so the gap is visible rather than inferred from its absence.

REJECTION LABELS ARE PART OF THE CONTRACT. `ErrSweepJoin` with a formatted string suffix is
not comparable across runtimes -- Elixir has no access to Go's message text -- so each of the
FIFTEEN LABELLED RULES BELOW SHALL carry a PORTABLE SEMANTIC LABEL that both runtimes emit and
the shared manifest pins. This is deliberately NOT "each rule": the enum-admission and
recovery-lane rejections are excluded by name further down, and a universal SHALL here would
contradict that exclusion. The frozen list is exactly these fifteen:
`source_authority_absent`, `source_kind`, `source_run_id_disposition`, `context_id`,
`range_id`, `scope_digest`, `target_range_digest`, `plan_digest`, `execution_shard`,
`assignment_epoch`, `batch_time_window`, `host_time_window`, `host_time_overflow`,
`trace_time_window`, `trace_time_overflow`. Until both runtimes emit these labels, a vector
manifest SHALL NOT claim exact-reason parity -- it may pin only "rejected", and SHALL say so.

`source_run_id_disposition` is in this list but is emitted by the BODY VALIDATOR, per the gate
table: the list freezes the labels for the rejections this matrix INTRODUCES, and the gate
table says which gate emits each. The two are orthogonal, and a label does not imply a gate.

The rejections this matrix merely LOCATES keep their existing reasons and are not frozen here
-- the body validator's unknown-source rejection and the recovery-lane rejection.
`source_unspecified` is deliberately ABSENT from the list: enum admission already owns it with
a pre-existing typed reason, and its vector is an UNLABELLED rejection under the rule above.

PER SOURCE -- and these SHALL vary the CONTEXT OPERAND, not only the kind. A vector set
that varies kind alone is satisfied by an implementation that pins a correct static
inventory and still compares `context_id == execution_id` for every source while ignoring
`source_run_id` -- which is exactly what the current Go join does. For each of the five
permitted values:

- a POSITIVE vector. On the three `source_run_id` sources it SHALL be built so that
  `execution_id != source_run_id` AND the signed `context_id` equals `source_run_id`. If
  the two ids coincide, the vector passes under either operand rule and proves nothing
  about which was selected;
- a SELECTED-CONTEXT MISMATCH vector, for EVERY source. Its construction DIFFERS BY ROW,
  because "point the signed context at the other body field" is not constructible on the
  forbidden rows -- the other field is `source_run_id`, which those sources forbid, so such
  a vector would break the disposition rule as well and prove whichever runs first:
  - on the `execution_id` rows, `source_run_id` stays ABSENT and `execution_id` is moved
    away from the signed `context_id`;
  - on the `source_run_id` rows, `execution_id != source_run_id` and the signed
    `context_id` is set to the NON-SELECTED `execution_id`.

  Either way the vector fails against an implementation reading the wrong operand, and it
  is per-source because the operand is per-source;
- a KIND-MISMATCH vector whose signed kind is the one mapped from a DIFFERENT source.

ONE WRONG-KIND SAMPLE PER SOURCE DOES NOT PIN THE MAPPING'S BEHAVIOUR. Five sources against
seven declared kinds is a 5x7 accept/reject matrix with exactly five accepting cells; a single
wrong-kind sample per source exercises five of the thirty rejecting cells and leaves an
implementation free to accept an extra pair nobody tested. The inventory pins the TABLE, and
these vectors pin five points -- neither pins the mapping's behaviour on the rest.

THE RUNTIME SHALL THEREFORE CONSUME THE PINNED MAPPING AS ITS SOLE KIND LOOKUP: one table, one
lookup, no second source-to-kind decision anywhere in the correlation. Under that construction
the inventory's coverage IS the behaviour's coverage, and the per-source vectors prove the
lookup is consulted rather than re-deriving what it returns.

THIS IS UNCONDITIONAL. An earlier revision offered "or exhaust the full source x kind reject
matrix" as an alternative for implementations computing the kind some other way. That
alternative was incoherent and is WITHDRAWN: five of the matrix's thirty-five cells pair a
sweep body with `RECOVERY_CONTROL` authority, and those are refused by the RESERVED RECOVERY
LANE before correlation is reached -- so they cannot demonstrate correlation behaviour at all.
An option whose cells are owned by a different gate, and whose count contradicts the one
recovery vector the ordinary inventory requires, is not a second path to the same proof. The
single pinned lookup is the requirement.

PER SOURCE_RUN_ID DISPOSITION -- the disposition is a rule in its own right, and it is
declared PER ROW, so presence and absence SHALL be covered PER ROW rather than sampled:

- FORBIDDEN-PRESENCE on BOTH forbidden rows -- two vectors;
- REQUIRED-ABSENCE on ALL THREE required rows -- three vectors.

All five are BODY-VALIDATION vectors, per the gate table. The disposition HAS a frozen
portable label, so all five -- and all THREE malformed vectors -- assert it exactly.

A single sampled row would leave the other rows' disposition unenforced, which is exactly
the state a per-row table exists to prevent.

MALFORMEDNESS IS FROZEN AS ONE SOURCE-INDEPENDENT PREDICATE: where `source_run_id` is
required it SHALL be a canonical UUID, by the SAME check on every row, with no per-source
variation.

THAT FREEZE STILL OWES ONE MALFORMED VECTOR PER REQUIRED ROW -- three, not one. The freeze
says the three rows share a predicate; it does not show that all three rows INVOKE it. A
single sampled row is satisfied by an implementation that checks canonical form on one source
and skips it on the other two, which is precisely the per-row gap the rest of this inventory
exists to close.

What the freeze DOES buy is that each row needs only ONE malformed vector rather than a
catalogue of malformed SHAPES -- wrong LENGTH, wrong VERSION nibble, wrong VARIANT bits.
Those belong to the shared canonical-UUID predicate's OWN test suite, which every caller
inherits, and restating them per row here would prove nothing about the sweep matrix.

TWO SHAPES AN EARLIER REVISION LISTED ARE NOT SHAPES. `source_run_id` is `bytes`, not a
string: "non-hex" names a textual encoding the field never has, and "empty" is
INDISTINGUISHABLE from absent for a non-optional proto3 `bytes` field, so it restates the
required-absence vector rather than adding a malformed one.

PER UNREACHABLE KIND -- a negative for `INTEGRATION_RUN` and one for `RECOVERY_CONTROL`: a
record whose signed authority carries that kind alongside an otherwise-valid sweep body.
Their absence from the mapping is a STATIC property of the inventory; that a runtime actually
REFUSES them is a behavioural one, and the inventory cannot establish it.

THE TWO ARE REFUSED BY DIFFERENT GATES and SHALL NOT be filed as a matching pair.
`INTEGRATION_RUN` reaches correlation and is refused there, so it carries the full last-gate
obligation. `RECOVERY_CONTROL` never gets that far: the reserved recovery lane refuses
recovery authority on a non-recovery route first, so its vector asserts the LANE rejection.
Both prove refusal; only one proves the correlation refuses.

Vectors for `SWEEP_EXECUTION_SOURCE_UNSPECIFIED` and for a sweep record with NO source
authority SHALL be inventoried explicitly rather than left implied by the prose above.

PER RELATION -- one negative for each rule below, on a single representative source, since
these are source-independent and crossing them with source would restate one rule five times.

WITH ONE EXCEPTION, which heads the list: the SELECTED OPERAND is source-DEPENDENT, is proven
per source above, and appears below only for inventory completeness. Every OTHER entry is
genuinely source-independent:

- THE SELECTED OPERAND against the signed `context_id` -- ALREADY DISCHARGED by the five
  per-source selected-context mismatch vectors above, and listed here only so the relation
  inventory is complete. It owes NO SIXTH vector. Unlike every other relation below it is
  NOT source-independent, which is exactly why it is proven per source rather than once on a
  representative one. There is exactly ONE selected operand per source and never two: the
  row's operand column names it, and the non-selected field is not a second thing to agree
  with. A relation phrased as "`execution_id`, and also `source_run_id` where present" would
  require both and contradict the table;
- `target_range_id` against the signed `scope_id`;
- `target_range_sha256` against the signed `scope_sha256` (label `scope_digest`);
- `target_range_sha256` against the signed `target_range_sha256` (label
  `target_range_digest`) -- a SEPARATE vector AND a SEPARATE LABEL, because the signed claim
  carries BOTH and the two predicates are independently removable: one label covering both
  would let either be deleted with the manifest still matching;
- `execution_plan_sha256` against the signed plan digest;
- `execution_shard` against the attested producer's `run_shard`;
- `assignment_epoch` against the attested `authority_epoch`;
- the batch `observed_at_unix_nano` outside the signed collection window -- TWO vectors, one
  BEFORE the start and one AFTER the expiry;
- a per-host absolute time outside it -- batch time plus `observed_at_delta_nano`, which is
  a SIGNED INTEGER (int64), not a cryptographic signature -- with a delta that does NOT
  overflow. TWO vectors, before-start and after-expiry; a negative delta is what reaches the
  before-start side. Label `host_time_window`;
- SEPARATELY, a per-host delta chosen so the sum OVERFLOWS int64 and the naively wrapped
  result lands INSIDE the window, which SHALL be rejected rather than accepted on the
  wrapped value. Label `host_time_overflow`. THE HOST PATH THEREFORE OWES THREE VECTORS --
  before-start, after-expiry, and overflow -- not one described several ways: the two labels
  are distinct, and a single vector satisfying both would let either predicate be deleted
  while the manifest still matched;
- an MTR trace identity time outside the window, on a host whose outcome allocated a trace
  id -- TWO vectors, before-start and after-expiry;
- an MTR trace id whose 48-bit UUIDv7 MILLISECOND timestamp overflows when converted to
  nanoseconds. A valid UUIDv7 can carry a timestamp up to 2^48-1 ms, and multiplying by
  1e6 exceeds int64 -- so an UNCHECKED conversion wraps a far-future identity into the
  signed window. This is a distinct vector from the in-range-but-outside-window case.

THE MILLISECOND-TO-NANOSECOND CONVERSION SHALL BE ONE CHECKED HELPER, used at EVERY call site
that converts a UUIDv7 timestamp for comparison against a signed window. The overflow is a
property of the CONVERSION, not of the sweep matrix, and it is currently unchecked at THREE
independent call sites -- the record's own event-identity check, the sweep summary's MTR trace
id, and the full-MTR trace and event ids. Fixing only the one this matrix happens to exercise
would leave two live wraps behind a vector set that looks complete.

EACH CALL SITE OWES ITS OWN VECTOR, because a shared helper proves nothing about a caller that
does not use it. Those vectors are assigned by OWNING TASK, not absorbed here: the sweep
summary's is task 1.3's and is the bullet above; the record event-identity site belongs to
task 1.1 and the full-MTR sites to task 1.4. 1.3 introduces the shared helper and its own call
site; it SHALL NOT be read as having proven the other two.

THE INNER COLLECTION PREDICATE IS INCLUSIVE AT BOTH ENDPOINTS: an observation exactly at
`EdgeSourceClaimsV1.collection_not_before_unix_nano`, or exactly at that message's
`collection_expires_unix_nano`, is INSIDE.

THAT MESSAGE QUALIFIER IS LOAD-BEARING, and this statement is scoped to that predicate
alone. `EdgeAssignmentExecutionClaimsV1` declares fields with THE SAME TWO NAMES and they
are HALF-OPEN -- an instant exactly at expiry is already outside. Two messages, identical
field names, deliberately opposite endpoint conventions.

Nor is "capability envelopes are half-open" true as a general claim: the record's
EVENT-IDENTITY envelope checks -- production window, source window, and the inline collection
window -- are INCLUSIVE at both ends; only the assignment-execution grant and the capability
envelopes on the compiled-assignment path are half-open. Each convention is pinned where it
applies and none generalises.

CLOCK TOLERANCE IS NOT PART OF ANY OF THIS. The event-identity envelope checks are inclusive
and take NO tolerance: they ask whether an identity time lies inside a signed window, which is
a question about the record, not about now. Tolerance widens a DIFFERENT decision -- whether an
authority is CURRENT at the validating instant -- and an earlier revision of this requirement
wrongly attached it to the envelope checks. Endpoint vectors SHALL therefore not be built or
explained in terms of tolerance; it does not reach them.

Endpoint controls SHALL use an envelope STRICTLY WIDER than the collection window, so the
envelope's own endpoint rule cannot be what decides them, and SHALL exercise all three time
paths -- batch, per-host absolute, and MTR trace identity -- at BOTH endpoints.

EVERY TIME WINDOW OWES A NEGATIVE ON BOTH SIDES, for all three paths. An ACCEPTED endpoint
control does NOT catch deletion of the opposite bound: an implementation that dropped its
expiry comparison entirely still accepts both endpoints and still rejects a before-start
value, so a one-sided negative set leaves the deleted half invisible. Six window negatives
result -- three paths, two sides -- plus the two overflow vectors, for EIGHT time negatives
in total: batch two, host three, trace three.

Each OVERFLOW vector SHALL be constructed so that the naively WRAPPED result lands INSIDE
the window. An overflow whose wrapped value falls outside is refused either way, so it
cannot distinguish a checked conversion from an unchecked one.

#### Scenario: A correlation-owned negative differs from its control in one comparison
- **WHEN** a CORRELATION-owned negative vector is compared with its committed positive control
- **THEN** they SHALL differ in exactly one correlation COMPARISON
- **AND** the record SHALL be REBUILT in the frozen order -- mutate, then re-encode/compress
  and update both sizes and `payload_sha256`, then re-sign every capability whose complete
  signing preimage changed, then recompute `semantic_envelope_sha256` LAST -- so neither a
  size, a signature, nor a digest check is what refuses it
- **AND** `EdgeRecordV1` carries no signature of its own, so "re-signing" always means
  re-signing capabilities, never the record

#### Scenario: Absent source authority leaves every claim relation undefined
- **WHEN** the `source_authority_absent` negative is compared with its control
- **THEN** it SHALL be exempt from differing in exactly one CLAIM relation, having no claims
- **AND** it SHALL still be refused at CORRELATION, by the presence check

#### Scenario: An earlier-gate negative is one input change refused at its own gate
- **WHEN** a negative owned by enum admission, body validation or the recovery lane is
  compared with its committed positive control
- **THEN** they SHALL differ in exactly one INPUT
- **AND** it SHALL be refused at its OWN gate, with later correlation relations left
  UNDEFINED rather than required to hold

#### Scenario: Every time window is refused on both sides
- **WHEN** an observation falls before a window's start, or after its expiry, on the batch,
  per-host absolute, or MTR trace identity path
- **THEN** it SHALL be rejected in all six cases
- **AND** an accepted-endpoint control alone SHALL NOT be treated as covering either bound

#### Scenario: Both source-claim collection endpoints are inside
- **WHEN** an observation falls exactly on either endpoint of the `EdgeSourceClaimsV1`
  collection window, inside a strictly wider envelope
- **THEN** it SHALL be accepted
- **AND** the identically named `EdgeAssignmentExecutionClaimsV1` window SHALL remain
  half-open, so the two conventions are pinned separately

#### Scenario: An overflowing time does not wrap into the window
- **WHEN** a host delta sum, or a UUIDv7 millisecond-to-nanosecond conversion, overflows
  int64
- **THEN** the record SHALL be rejected, not accepted on the wrapped value
- **AND** the conversion SHALL be performed by ONE checked helper shared by every call site
  that compares a UUIDv7 time against a signed window

### Requirement: An MTR hop's ASN is diagnostic enrichment, not an allocation claim
`MtrTraceHopV1.asn` SHALL be admitted for EVERY value the generated `uint32` can carry, and
its NUMERIC VALUE SHALL be preserved through decode. Implementations SHALL NOT apply
allocation-status filtering: admission SHALL NOT consult whether a value is allocated,
transitional, private-use, reserved, or unassigned. A **zero** value SHALL mean UNAVAILABLE
OR NOT SUPPLIED.

THE FIELD IS PRODUCER-SUPPLIED DIAGNOSTIC ENRICHMENT associated with a hop address. It is
frequently lookup-derived today, but this ABI fixes NO provenance: no invariant requires any
particular dataset, cache, or lookup path, and a producer may supply it from any source or
leave it zero.

ALLOCATION AND ROUTING POLICY DO NOT GOVERN ADMISSION OF DIAGNOSTIC ENRICHMENT. That is the
whole rule, and it is narrower than "these ASNs are special":

- Private-use status alone (RFC 6996) is not an admission error. Such ASNs are ordinary
  inside the operator networks this product is deployed in. Downstream analysis MAY still
  flag one contextually; that is a judgement about what was observed, not a reason to refuse
  the record carrying it.
- The Last ASNs (RFC 7300) are reserved, and RFC 7300 asks that they not be treated as BGP
  PROTOCOL ERRORS. Recording one as an observation is not a protocol action at all.

Rejecting a value on either ground would fail a whole record over one enrichment field,
discarding the sweep or trace observations that are the record's actual purpose.

WHAT IS FROZEN IS THE SEMANTICS -- zero means absent, every other value is carried through
unchanged -- and it is pinned by shared vectors rather than by a rejection path. The generated
`uint32` already supplies the wire domain: there is no value a conforming decoder can produce
that this rule would reject, so a filter could only NARROW the contract below what the type
admits.

`asn_org` IS ADMITTED INDEPENDENTLY, subject to the ordinary UTF-8, string-length, batch and
wire bounds that apply to any hop string. It is NOT a second source of truth for the number.
Disagreement between the two SHALL NOT affect admission of either, and neither SHALL be
altered on account of the other.

OMITTED AND EXPLICITLY-ENCODED ZERO ARE THE SAME OBSERVATION. `asn` is not `optional`, so a
field absent from the wire and a field encoded as `0` decode to the same value and mean the
same thing. The two encodings produce DIFFERENT PAYLOAD BYTES, and therefore a different
`payload_sha256` and semantic envelope. Each encoding SHALL be INDEPENDENTLY ADMISSIBLE. This
does not make them two logical records: carried under the same `(network_scope_id, event_id)`
they are conflicting encodings of one record, not a pair.

HOW THIS IS STORED IS NOT THIS TASK'S TO DECIDE. Projection -- how "unavailable" is
represented in SQL, and how wide the column must be to hold `uint32` -- is owned by
`unify-sweep-results-proto`'s "TimescaleDB Storage" requirement and its task 5.4. This
requirement constrains the ABI; it SHALL NOT be read as specifying DDL.

#### Scenario: Zero is admitted whether omitted or explicitly encoded
- **WHEN** one record omits `asn` entirely and a SEPARATELY IDENTIFIED record encodes it
  explicitly as `0`
- **THEN** each record is independently admitted
- **AND** both decode to `0`, meaning unavailable or not supplied

#### Scenario: Allocation status does not affect admission
- **WHEN** a hop carries `asn` = 23456, 64512, 65534, 65535, 4200000000, 4294967294, or
  4294967295
- **THEN** the record is admitted
- **AND** the numeric value survives decode with no substitution and no clamping

#### Scenario: asn_org is admitted independently of the number
- **WHEN** a hop carries any `asn` value together with an `asn_org` that is ordinarily valid
  under the UTF-8, string-length, batch and wire bounds
- **THEN** both fields are admitted on their own terms
- **AND** neither is altered or refused on account of the other's content

### Requirement: Nanosecond time is canonicalized to microseconds only at the projection boundary
Every wire timestamp SHALL remain UNMODIFIED NANOSECONDS through decode, through both contract
hashes, and through every PRE-PROJECTION comparison -- those that decide CONTRACT IDENTITY and
admission. Conversion to microseconds SHALL happen ONLY where a value crosses into the
projection domain, and SHALL yield the CONTAINING microsecond bucket, computed without forming
an unrepresentable intermediate for any `int64` input.

THE ORDER IS THE RULE, and it is the part an implementation gets wrong silently:

1. `payload_sha256` hashes the EXACT CARRIED PAYLOAD BYTES.
2. `semantic_envelope_sha256` hashes the frozen FIELD-FRAMED TRANSCRIPT, which commits
   `payload_sha256` and the RAW NANOSECOND values.
3. ONLY THEN may a value be canonicalized, and only for a database-derived key or ordering.

NEITHER HASH MAY EVER SEE A CANONICALIZED TIME. CONTRACT IDENTITY is defined over what was
received; a
digest taken over a normalized value would make identity depend on the normalization step, and
two implementations rounding differently would disagree about whether they hold the same
record while both believing they conform.

FLOOR, NOT TRUNCATION TOWARD ZERO -- and the reason is the CONTAINING-BUCKET INVARIANT, not
monotonicity. Both methods are monotonic, so monotonicity cannot distinguish them and is not
the argument.

The requirement is that the canonical value `u` names the microsecond bucket the instant falls
in: `u * 1000 <= ns < (u + 1) * 1000`. That inequality is MATHEMATICAL, stated in widened
arithmetic -- near the extremes of `int64` both bounds overflow the type, so an implementation
checks it by reasoning about the division, not by evaluating the products. Floor satisfies it
everywhere. Truncation toward zero
satisfies it only for non-negative inputs: `-1500ns` truncates to `-1us`, whose bucket spans
`[-1000, 0)` and does not contain `-1500`. Floor gives `-2us`, spanning `[-2000, -1000)`, which
does. A coordinate naming a bucket that does not contain its own instant places the row in the
WRONG PROJECTED BUCKET and compares equal to instants it did not share a microsecond with.

THE COMPUTATION SHALL NOT FORM AN UNREPRESENTABLE INTERMEDIATE. That is the language-neutral
requirement: an implementation SHALL NOT compute the positive magnitude of the operand, because
the minimum `int64` has no representable positive counterpart. Floor division applied directly
to the signed value never forms one.

CONCRETELY IN GO, where signed overflow is DEFINED as wrapping rather than undefined, a
negation-then-add implementation fails across `[MinInt64, MinInt64 + 999]` -- but for TWO
DIFFERENT REASONS, and conflating them hides one of the cases:

- At EXACTLY `MinInt64`, the unary negation itself wraps, because the value has no representable
  positive counterpart. The subsequent `+999` then does NOT overflow.
- For `MinInt64 + 1` through `MinInt64 + 999`, the negation IS representable -- it lands in
  `MaxInt64 - 998 .. MaxInt64` -- and it is the `+999` bias that wraps.

Either way the result is not a rounding error but a SIGN FLIP: the earliest representable
instants yield large POSITIVE microsecond values, so an ordering coordinate built on them sorts
those instants as the latest.

WHAT CONSUMES THIS IS ENUMERATED, and the list is exactly the projection-domain STORAGE AND
ORDERING coordinates -- not hashes, and not identity comparisons. No projection hash or identity
comparison consumes a canonicalized time, and none SHALL be added by inference; if one is ever
built, it joins this list in the same change.

- `mtr_traces.time` (`TIMESTAMPTZ`): the AUTHORITATIVE OBSERVATION TIME, floor-canonicalized
  for storage and ordering.
- `mtr_hops.time` (`TIMESTAMPTZ`): likewise.

`timestamptz` carries MICROSECOND resolution, so a nanosecond value cannot round-trip through
either column, which is why the conversion exists at all.

THESE ARE NOT THE PARTITION IDENTITY. `trace_identity_time` is, and it derives from the UUIDv7
MILLISECOND timestamp rather than from any wire nanosecond -- so it SHALL NEVER be routed
through this conversion. `mtr_hops` references the trace's physical identity rather than
re-deriving one. Conflating the two would send a millisecond-derived partition key through a
nanosecond canonicalizer and change what the row is, not merely where it sorts.

AGE GRAPH ORDERING STAYS IN RAW NANOSECONDS, deliberately. The `(observed_at, trace_id)`
comparison that decides whether a property update is newer than the stored order is NOT bounded
by `timestamptz`, so it has no reason to lose precision. Canonicalizing it would collapse
observations within one microsecond into ties broken arbitrarily by `trace_id`, turning a
determinate order into an arbitrary one. It is named here so its absence from the list above is
a decision rather than an oversight.

SUB-MICROSECOND FIDELITY IS NOT DISCARDED. Where it is part of the domain or audit contract,
the original signed nanosecond value SHALL be retained separately from the canonicalized key,
because the canonical value is a storage coordinate and not a replacement for the observation.

PROJECTOR INTEGRATION AND SCHEMA ARE NOT THIS TASK'S. Wiring the conversion into the consumers,
and any DDL it implies, belong to `unify-sweep-results-proto`. This requirement fixes the
mathematics, the ordering relative to the hashes, and the list of consumers.

#### Scenario: Two instants in one bucket share a projection-time coordinate, not an identity
THE TWO VALUES MUST ENCODE TO THE SAME WIDTH, or the vector proves less than it appears to.
`observed_at_unix_nano` is an `int64` and encodes as a base-128 varint, so 1 ns occupies one
byte while 999 ns occupies two. That difference propagates into `encoded_size` and
`uncompressed_size`, which the semantic transcript frames directly -- so the digests would
differ even if the transcript's dependency on `payload_sha256` were deleted, and the vector
would survive the very regression it exists to catch.

**128 ns and 999 ns are both two-byte varints.** With them, `payload_sha256` is the only
transcript member that moves.

- **WHEN** two valid payloads differ ONLY in `MtrTraceEventV1.observed_at_unix_nano`, carrying
  128 ns and 999 ns, with every enclosing transcript member -- `event_id`, `payload_family`,
  `compression`, `encoded_size`, `uncompressed_size`, the output contract, the producer context
  and the capability -- held IDENTICAL
- **THEN** their canonicalized PROJECTION-TIME COORDINATES are EQUAL, both naming bucket 0
  (equal time alone does not make the full projection keys equal -- the other key members are
  not constrained by this scenario)
- **AND** their carried payload bytes differ
- **AND** their `payload_sha256` values differ
- **AND** their `semantic_envelope_sha256` values differ, which -- since nothing else in the
  transcript moved -- is attributable to `payload_sha256` alone

#### Scenario: A framed capability nanosecond moves the semantic digest on its own
This is a DIGEST-ONLY construction and is NOT an admission scenario. Moving a signed timestamp
while retaining the original signature makes the record cryptographically invalid; the pair
exists solely to isolate the digest's dependence on a raw nanosecond value, and neither member
is expected to be admitted.

THE FIELD IS NAMED, because "a capability timestamp" could otherwise be implemented against
delivery authority, which the semantic envelope deliberately EXCLUDES -- and such an
implementation would show no digest movement at all. The transcript frames
`production_capability.not_before_unix_nano` directly.

- **WHEN** `production_capability.not_before_unix_nano` is 128 ns in one member and 999 ns in
  the other -- again equal-width varints -- with `expires_at_unix_nano`, the payload bytes,
  `payload_sha256`, the claims and a fixed dummy signature all held IDENTICAL
- **THEN** the `semantic_envelope_sha256` values differ
- **AND** the difference is attributable to the raw nanosecond value, since nothing else moved

#### Scenario: Canonicalization floors toward negative infinity
- **WHEN** a wire value of `-1500` nanoseconds is canonicalized
- **THEN** the result is `-2` microseconds
- **AND** a value of `1500` nanoseconds canonicalizes to `1` microsecond
- **AND** the mapping is monotonic: no two inputs in true order produce outputs in reverse

#### Scenario: The bottom of the int64 range canonicalizes to literal values
These are stated as LITERAL input/output pairs, not as a described neighbourhood, and they
straddle the exact bucket edge at `MinInt64 + 808`. An implementation SHALL produce exactly:

| nanoseconds | microseconds |
|---|---|
| `MinInt64` (-9223372036854775808) | -9223372036854776 |
| `MinInt64 + 807` | -9223372036854776 |
| `MinInt64 + 808` | -9223372036854775 |
| `MinInt64 + 999` | -9223372036854775 |
| `MinInt64 + 1000` | -9223372036854775 |

- **WHEN** any of the above nanosecond values is canonicalized
- **THEN** the result is exactly the paired microsecond value
- **AND** every result remains NEGATIVE, rather than the large POSITIVE value a wrapped
  negation or a wrapped `+999` bias produces

### Requirement: An unknown field is refused and an unknown enum is retained, and both runtimes reach the same verdict
A record carrying a RETAINED UNKNOWN FIELD SHALL be REFUSED, at EVERY message depth. An
UNKNOWN ENUM VALUE SHALL instead be RETAINED with its exact number through decode and refused
SEMANTICALLY, by the closed per-field member sets. Both runtimes SHALL reach the SAME
accept/reject verdict on the SAME BYTES.

"EVERY MESSAGE DEPTH" MEANS ONE GRAPH, AND THE BOUNDARY IS THE SCHEMA. The rule applies to
the message being validated and to every message reachable from it through SCHEMA-DECLARED
MESSAGE FIELDS -- at any depth, and including oneof members, repeated messages, and
message-valued map entries. Three exclusions make that a boundary rather than a slogan:

- A `bytes` FIELD IS OPAQUE, even when its content is itself protobuf. The record's `payload`
  carries a CONTRACT message, admitted by the rules of the contract that selects its validator --
  NOT by the payload family, which decides only which typed ingress the record may enter.
  Walking it here would apply the record's field inventory to a different schema and refuse
  valid contract bytes.
- EACH RECEIVED CARRIER IS ITS OWN GRAPH. The client message, the delivery frame, the record,
  the plan page and the compiled assignment are validated when each is received, on its own
  schema. This requirement does not merge them into a single walk, and satisfying it for one
  carrier does not satisfy it for another.
- A MESSAGE THE SCHEMA DOES NOT DECLARE IS NOT DESCENDED INTO. It is refused as an unknown
  field, which is the rule above, so there is no schema to walk it against.

THESE TWO RULES POINT IN OPPOSITE DIRECTIONS, DELIBERATELY. The edge ABI is frozen closed, so
an unknown field is a record a later reader might reinterpret and is refused. An unknown enum
is refused too, but only AFTER the effective value is resolved by a real decoder: a raw wire
walk cannot reproduce LAST-ONE-WINS, oneof resolution, or embedded-message merging, so a
first-occurrence verdict would refuse messages whose effective value is valid.

THE VERDICT IS FROZEN; THE LAYER IS NOT. The two runtimes refuse the same bytes through
different mechanisms, and requiring one mechanism would freeze an implementation detail:

- An out-of-range field number (above 2^29-1) and a 10-BYTE UINT64-OVERFLOW VARINT are refused
  by Go's WIRE PARSER, while the generated Elixir decoder ACCEPTS both -- masking a `2^64 + N`
  varint to its low 64 bits -- so a project-owned structural preflight is what refuses them
  there.
- An ordinary unknown field and a well-formed GROUP are PARSED AND RETAINED by Go and refused
  by its own unknown-field walk, while the Elixir decoder silently DISCARDS a group, so
  nothing downstream of the decoder could ever see it.

A CONFORMING IMPLEMENTATION MAY REFUSE AT EITHER LAYER. What it SHALL NOT do is admit.

THE RETAINED ENUM NUMBER IS PART OF THE CONTRACT, not an implementation artifact. An
implementation SHALL NOT clamp, substitute, or drop an unknown enum value on decode. This is
NOT implied by the refusal: the closed member sets refuse a clamped value exactly as they
refuse the original, so a decoder that silently rewrote 99 to 0 would pass every admission
check while corrupting what a reject audit reports.

A DECLARED-BUT-EXCLUDED MEMBER IS STILL REFUSED. `UNSPECIFIED` is declared by every edge enum
and permitted by none of the closed sets, so it is refused by the FIELD POLICY rather than by
unknown-value retention -- a distinction that matters because only the latter can be
recognised by "the field holds a raw integer".

WHAT IS NOT FROZEN HERE is anything about a refusal beyond the fact of it: the CLASSIFICATION
it carries -- whether the bytes are dead, the deployment is broken, or a schema is simply not
deployed yet -- the DISPOSITION it resolves to, and the stream or dead-letter queue it routes
to. Those decide RETRYABILITY rather than admissibility, they are stage- and slot-specific, and
they are owned separately (see task 1.5-l). This requirement is satisfied by refusing; it takes
no position on what the refusal is then called.

#### Scenario: An unknown field is refused at every depth
- **WHEN** a record carries a field number the schema does not declare, at the record's top
  level or nested inside a signed capability
- **THEN** the record is refused by both runtimes
- **AND** the refusal does not depend on the field's wire type, including a well-formed group

#### Scenario: The field-number bound is inclusive
- **WHEN** one record carries field number 2^29-1 and another carries 2^29
- **THEN** both are refused
- **AND** neither refusal depends on which layer produced it

#### Scenario: An unknown field two messages deep is refused
- **WHEN** a record carries an undeclared field number inside the claims of its production
  capability -- two schema-declared message fields below the record
- **THEN** the record is refused
- **AND** the refusal does not depend on the depth at which the field appears

#### Scenario: An unknown enum survives decode with its exact value and is then refused
- **WHEN** a record carries a `traffic_class` of 99 or -1, neither declared by the enum
- **THEN** the decoded value is exactly 99 or -1, with no clamping or substitution
- **AND** the record is refused by the closed member set for that field

#### Scenario: A declared member outside the permitted set is refused by the field policy
- **WHEN** a record carries `traffic_class` = 0 (`UNSPECIFIED`), which the enum declares
- **THEN** the value decodes as a DECLARED member rather than as a raw number
- **AND** the record is still refused, because the permitted set for that field excludes it

### Requirement: Every versioned object fails closed, by one of two proof classes
Every versioned object in this ABI SHALL REFUSE an artifact produced under a version it does
not support, and each object SHALL belong to EXACTLY ONE of two proof classes.

CLASS A -- the object DECODES a version from its input. It SHALL refuse an input carrying an
unsupported version.

CLASS B -- the version is a COMPILE-TIME CONSTANT inside a preimage and the received value is a
digest or an opaque identifier. There is no version input to corrupt, so the object SHALL
refuse an artifact RECOMPUTED under a different version constant, as a mismatch.

THE PARTITION IS PER OBJECT, NOT PER GRAMMAR OR PER VERSION FIELD. One grammar may contain
several objects, and one version field may govern two grammars: `CompiledSweepAssignmentV1`'s
`digest_version` governs both the body digest and the artifact address, and is therefore ONE
Class-A member rather than two. Conversely the three recovery-operation scope transcripts share
a version constant and are THREE Class-B members, because each is separately computed and
separately compared.

AN OBJECT LISTED IN BOTH CLASSES IS DOUBLE-COUNTED, and an object listed in neither is
unproven. Asking a Class-B object for an unsupported-INPUT vector is not merely redundant --
it cannot be satisfied, because no version reaches that object from the wire.

THE CLASS IS DECIDED BY WHERE THE VERSION ENTERS, not by what the object is used for. A digest
OVER a message that itself carries `digest_version` belongs to Class A, because the version the
digest commits is the field the message already exposes, and the Class-A vector exercises both.

EVIDENCE SHALL BE A COMMITTED ARTIFACT, NOT A REGENERATED ONE. The alternate-version artifact
SHALL be committed bytes read by both runtimes, and SHALL be driven through the SAME verifier
that trusts that value in production. A version check written for a test suite proves only that
the suite can refuse its own inputs, and an artifact regenerated at test time proves only that
the generator agrees with itself.

THE INVENTORY SHALL BE ASSERTED AGAINST AN INDEPENDENT STATEMENT of its membership, in both
directions, and its classes checked. A count derived from the same artifact that lists the
objects cannot detect an object's removal: the count and the list move together.

#### Scenario: A Class-A object refuses an unsupported input version
- **WHEN** an object that decodes a version from its input receives one outside the supported set
- **THEN** the object is refused
- **AND** an otherwise identical artifact carrying a supported version is accepted

#### Scenario: A Class-B object refuses an artifact built under another version constant
- **WHEN** a digest or identifier is recomputed with the grammar version altered, and every
  enclosing digest is rebuilt so it is the only unreconciled value
- **THEN** the object carrying it is refused as a mismatch
- **AND** the same object carrying the artifact built under the frozen constant is accepted

#### Scenario: The inventory is exhaustive
- **WHEN** the committed inventory is compared against an independently written list of every
  versioned object and its class
- **THEN** every object appears exactly once, in exactly one class, with the expected class
- **AND** no object appears that the independent list does not name

### Requirement: Optional-scalar presence is preserved, and its meaning is per field
An explicitly optional scalar SHALL preserve its PRESENCE through decode. An implementation
SHALL NOT coerce an absent field to zero, nor drop a present zero, in either direction.

THE TWO STATES ARE DISTINGUISHABLE ON THE WIRE: absent emits nothing, present-zero emits a tag
and a zero. Preserving that distinction is the rule; WHAT the distinction means is a property of
the individual field, and this ABI carries two kinds.

MEASUREMENTS -- the per-hop MTR timings, the ICMP and MTR summaries' loss and round-trip values,
the open port's response time, and the host observation's first/last-seen deltas. For these,
ABSENT MEANS NOT MEASURED and PRESENT-ZERO MEANS MEASURED, AND THE ANSWER WAS ZERO. A producer
that encodes the zero spends bytes to say so.

REQUIRED AUTHORITY AND WINDOW STATEMENTS -- `EdgeProducerContext.authority_epoch`,
`SweepMtrExpectationV1.plan_ordinal_offset`, and `TargetRangeV1.mtr_ordinal_count`. These are NOT
measurements and their absence is not "not measured": each is a value a consumer cannot proceed
without, so its consumer SHALL refuse the artifact when it is absent, while present-zero remains
a legitimate value. They are optional in the schema so that ABSENT is distinguishable from ZERO,
not so that they may be omitted.

A DECODE-SIDE COLLAPSE IS INVISIBLE TO EVERY DIGEST. Whether presence is committed depends on the
carrier -- `semantic_envelope_sha256` frames `authority_epoch`'s presence directly, and a
payload-carried field's presence changes the payload bytes and therefore `payload_sha256` -- so a
PRODUCER that drops the zero emits a different, self-consistent artifact. What no digest can see
is a READER that coerces after verifying: the bytes and every digest over them remain valid while
the decoded meaning is gone.

WHETHER PRESENCE IS REQUIRED IS PER FIELD, and is a property of the validator that consumes it,
not of the type. An implementation SHALL NOT generalise from one field to its siblings, and
evidence SHALL be per-field: a vector that toggles a carrier's optional fields TOGETHER cannot
distinguish a field that became required from siblings that stayed indifferent, and would record
a policy it cannot observe.

THE FIELD SET SHALL BE DERIVED FROM THE GENERATED DESCRIPTORS rather than maintained by hand. An
explicit proto3 `optional` scalar is exactly a field whose containing oneof is synthetic, so the
complete set is mechanically knowable; a hand-written list falls behind the schema silently, and
the count derived from it agrees with itself while doing so.

WHAT IS NOT REQUIRED is that both runtimes reach an admission verdict for every field. Where a
runtime has no production validator for a carrier, it SHALL claim only what it can observe --
that the encodings differ, that decoded presence differs, and that a present value is exactly
zero -- and SHALL NOT introduce a check written for the test suite in order to appear at parity.

#### Scenario: A present zero survives decode as present
- **WHEN** an optional scalar is encoded explicitly as zero
- **THEN** it decodes as PRESENT with the value zero
- **AND** an otherwise identical message omitting it decodes as ABSENT

#### Scenario: An absent measurement is not a measured zero
- **WHEN** a measurement field is omitted rather than encoded as zero
- **THEN** the artifact is admitted, and the field reads as NOT MEASURED
- **AND** it is not reported as a measurement whose value was zero

#### Scenario: A required authority or window value is refused when absent
- **WHEN** `authority_epoch`, `plan_ordinal_offset` or `mtr_ordinal_count` is omitted
- **THEN** the artifact is refused by the validator that consumes it
- **AND** the refusal comes from that validator, not from an inability to construct the input

#### Scenario: Presence policy is observed per field, not per carrier
- **WHEN** one optional field of a carrier is omitted while its siblings remain present-zero
- **THEN** the verdict reflects that field's own policy
- **AND** the artifacts differ in that field's presence and in nothing else

### Requirement: The payload family is a framing discriminator bound to the typed entry point
`payload_family` SHALL be an IMMUTABLE FRAMING AND LIFECYCLE DISCRIMINATOR. Each TYPED ingress
SHALL admit exactly one family and SHALL refuse every other declared family:

| typed ingress | admitted family |
|---|---|
| sweep, MTR | `EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1` |
| lifecycle | `EDGE_RECORD_PAYLOAD_FAMILY_RUN_EVENT_V1` |
| recovery | `EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1` |
| a future snapshot ingress | its named snapshot family |

THERE IS NO CONTRACT-SPECIFIC MAPPING, and no registry-wide contract-to-family table SHALL be
introduced. The EXACT OUTPUT CONTRACT selects the semantic validator and the projector; contract
dispatch compares the contract reference and nothing else. The family answers a different
question -- which typed ingress this record may enter -- and the two SHALL NOT be conflated.

THE OBLIGATION IS CONDITIONAL ON THE INGRESS, AND IT IS NOT WAIVABLE. A runtime that has no
typed ingress for a family has nothing to bind and owes no check for it; the moment it
introduces one, that ingress SHALL admit exactly one family under this requirement, as its first
act on the record. This is stated so that "runtime X does not implement this ingress" can never
be read as an exemption for an ingress that later exists.

THE FAMILY IS NOT AUTHORIZATION and NOT AN INFRASTRUCTURE ROUTING KEY. It does not widen or
narrow what a capability permits, and a component that routes on it without validating it is
trusting a value no boundary checked.

THE CHECK SHALL LIVE AT EACH TYPED BOUNDARY, before the TYPED CONTRACT BODY is decoded or
materialised. It is deliberately NOT stated as "before any extraction": whole-record validation
may already have streamed a bounded decompression to enforce physical ceilings, and that is a
size-bounded operation over opaque bytes, not an interpretation of them under a schema. What the
framing check precedes is the moment the payload is read AS a contract message.

Protobuf bytes are not intrinsically type-tagged: a body decodes under an unintended schema
without complaint, so a record declaring one family while entering another ingress would be
ADMITTED AND AUTHENTICATED carrying contradictory metadata, and every later reader that selected
a decoder from the family would be choosing from a value nothing validated. A record whose
family is wrong AND whose payload is malformed SHALL be refused at the framing boundary, which is
what demonstrates the typed decode was not entered.

THE GENERIC RECORD VALIDATOR SHALL REMAIN PERMISSIVE across the known non-recovery families. It
has no entry-point context and cannot choose among them; requiring it to would either freeze one
family for every record or force it to guess. Its permissiveness is part of this contract, not an
omission in it.

RECOVERY IS ALREADY CONSTRAINED ELSEWHERE, by the biconditional between the recovery family and
the recovery route profile, which preempts generic admission. That rule is not restated here, and
evidence for this requirement SHALL exclude the recovery family so a refusal produced by the lane
rule is never read as evidence for this one.

#### Scenario: A typed ingress refuses a declared family it does not frame
- **WHEN** a record carrying a valid body for a NON-RECOVERY typed ingress declares any other
  declared non-recovery family
- **THEN** the typed ingress refuses it
- **AND** the generic record validator still admits the same bytes
- **AND** this scenario is stated for non-recovery ingresses only: a recovery family on an
  ordinary route is refused by the LANE biconditional, so the generic validator does not admit
  it and the second clause above would be false

#### Scenario: The framing check precedes decoding
- **WHEN** a record declares a family the ingress does not frame AND carries a payload that
  cannot decode
- **THEN** the refusal is the framing decision, not the decode failure

#### Scenario: Each typed ingress enforces the invariant at its own call site
- **WHEN** the check is removed from one typed ingress whose family is not otherwise constrained
- **THEN** that ingress admits a wrongly framed record
- **AND** the other typed ingresses continue to refuse one
- **AND** the recovery ingress is EXEMPT from this scenario: the recovery family is already
  constrained by the lane biconditional before its typed check is reached, so removing that
  check alone changes no verdict and the scenario cannot be satisfied for it

### Requirement: Residual domain-semantic bounds are frozen by value, each as an attainable maximum or a pre-parse guard
Each bound below SHALL hold the stated value in every implementation.

FOR AN ATTAINABLE MAXIMUM the bound SHALL be INCLUSIVE: a value AT the bound SHALL be accepted
and a value ONE OVER SHALL be refused. The inclusivity half is normative on its own. A boundary
asserted only as "too big is refused" permits an implementation to tighten `>` into `>=` and
silently refuse conforming producers at the exact ceiling, which is a compatibility break no
refusal-only evidence can detect.

FOR A GUARD-CLASS BOUND the obligation is DIFFERENT, because no valid value reaches the
ceiling: the LARGEST VALID input SHALL be accepted, and an over-limit input SHALL be refused
BEFORE the parser the guard protects is entered. "Accepted at the ceiling" is not required of
these and SHALL NOT be demanded as evidence -- there is no such input to construct. The table
names which bounds are which.

| bound | value | applies to | lower bound | class |
| --- | --- | --- | --- | --- |
| `MaxPolicyIDBytes` | 128 | `availability_policy_id` on a plan HEADER and on a `SweepAssignmentRecordV1` | 1 (empty is refused) | attainable |
| `MaxRangeStrBytes` | 64 | `cidr`, `first_address`, `last_address` on a `TargetRangeV1` | none | **GUARD** |
| `MaxTransportProvenanceHeaderBytes` | 512 | one encoded `Sr-Edge-Transport-Provenance` header, on RECEIVED bytes before decode | none | **GUARD** |
| `MaxPrincipalBytes` | 128 | an authenticated component-id principal, at every site that carries one | 1 (empty is refused) | attainable |
| `MaxManifestPages` | 1024 | the supplied page LIST of a PLAN, matching the value already frozen for a recovery manifest | 1 (an empty list is refused) | attainable |
| `MaxRangesPerPage` | 256 | `TargetRangeV1` entries in one plan page | 1 (an empty page is refused) | attainable |
| `MaxSweepHostsPerBatch` | 2000 | host entries in one `SweepObservationBatchV1` | none | attainable |
| `MaxTraceStrBytes` | 256 | `abort_reason` on a `SweepExecutionEventV1`, **only when its kind is ABORTED** | 1 when ABORTED; **exactly 0 for every other kind** | attainable |

A RANGE's `availability_policy_id` is NOT an independent bound. It SHALL equal the plan header's,
and the header's is already bounded, so the range's length is DERIVED. An implementation MAY
check it defensively but SHALL NOT treat that check as the enforcement point, and no evidence
SHALL claim the range site as an independently provable one: no input can reach the length
comparison without failing the equality first.

TWO OF THESE ARE DEFENSIVE PRE-PARSE GUARDS rather than attainable maxima, and this requirement
does not pretend otherwise. No valid transport-provenance header approaches 512 bytes, and once
zones are forbidden no canonical range string approaches 64. Their obligation is that oversize
input is refused BEFORE the parser they protect is entered; the inclusivity rule above binds them
only in the sense that a conforming value SHALL NOT be refused for length.

#### Scenario: An ATTAINABLE maximum admits a value at the ceiling
- **WHEN** a field bounded by an attainable maximum carries exactly that value and is
  otherwise valid
- **THEN** the boundary accepts it

#### Scenario: An ATTAINABLE maximum refuses one over
- **WHEN** a field bounded by an attainable maximum carries exactly one more than it
- **THEN** the boundary refuses it

#### Scenario: A GUARD-class bound admits the largest valid input
- **WHEN** an input bounded by a pre-parse guard carries the largest value its own grammar
  permits
- **THEN** the boundary accepts it, and no at-ceiling input is required to exist

#### Scenario: A GUARD-class bound refuses before parsing
- **WHEN** an input exceeds a pre-parse guard
- **THEN** it is refused before the parser that guard protects is entered

#### Scenario: A derived length check cannot be reached on its own
- **WHEN** a plan range's `availability_policy_id` is longer than the frozen maximum
- **THEN** the refusal is the header-equality rule, because a header holding that value was
  already refused

### Requirement: A plan range address string SHALL NOT carry an IPv6 zone
A `cidr`, `first_address` or `last_address` containing `%` SHALL be REFUSED, and the check SHALL
run BEFORE the address parser is entered in every implementation.

A zone identifies an interface on the machine that WROTE the string. It has no meaning at any
other node, so a scheduler plan naming a scoped address describes a target the receiving agent
cannot resolve to the same thing the author meant -- if it can resolve it at all.

THE RUNTIMES DISAGREE WITHOUT THIS RULE, in a way neither reports as a zone problem. A permissive
address parser may accept a scoped address and round-trip it canonically, admitting it; a parser
that accepts the text but DISCARDS the zone will then refuse the same input as a non-canonical
SPELLING, because the re-encoded form no longer matches what arrived. One accepts, one refuses,
and neither says "zone".

THE ZONE SHALL NOT BE STRIPPED, NORMALISED, OR OTHERWISE REPAIRED. These strings are inputs to
the range, page, PLAN-ROOT, header and assignment digest chain, so rewriting one changes every
digest above it and silently forks a plan's identity from the bytes its author signed. The
only conforming handling is refusal. A plan carrying zoned addresses SHALL be REGENERATED by its
author, not rewritten by a consumer.

#### Scenario: A scoped address is refused before parsing
- **WHEN** any plan range address string contains `%`
- **THEN** it is refused, and the address parser is not entered


### Requirement: A spool-loss tombstone reason is bounded on BOTH sides
A tombstone's `reason` SHALL be at least 1 and at most `MaxReasonBytes` bytes. An EMPTY reason
SHALL be REFUSED.

The maximum was already frozen; the LOWER bound was not, and leaving it open let one runtime
refuse an empty reason permanently while another admitted it. A tombstone records that spooled
records were lost, and it is read by an operator reconstructing what happened. An empty reason
is a tombstone that says data was lost and declines to say why, which is the one thing this
message exists to carry.

THE BOUND LIVES ON THE SIGNED RECOVERY-CONTROL BODY PATH, not on a bare tombstone validator. A
peer that recomputes a tombstone digest without verifying the signature first is a DIFFERENT
boundary, and satisfying this requirement there would not satisfy it here.

#### Scenario: An empty reason is refused
- **WHEN** a tombstone carries a zero-length `reason`
- **THEN** the signed recovery-control boundary refuses it

### Requirement: A count ceiling SHALL be enforced before the traversal it bounds, and SHALL NOT require that traversal to enforce
A count ceiling on a collection THIS CHANGE OWNS SHALL be applied BEFORE any recursive walk
over that collection, and SHALL be obtained without traversing more than `ceiling + 1` elements.
The owned collections are a plan's page list and each page's range list, a recovery manifest's
page list and each page's classification-span list, and a sweep batch's host list.

SCOPED DELIBERATELY. Stating it of "every structural count ceiling" would reallocate bounds
other tasks own, and this requirement is not a licence to restructure them.

These are two rules because they fail independently, and both were violated while every
implementation returned the correct verdict.

ORDER. A ceiling checked after a recursive walk has already permitted the work it exists to
forbid. Rejecting unknown fields before hashing is a real obligation and is NOT weakened here:
what changes is that a COUNT -- available without interpreting anything -- SHALL precede the
walk. Where a per-element count bounds a nested collection, it SHALL precede descent into that
element's children.

WHAT THE COUNT DOES NOT OVERTAKE: rules that validate the CONTAINER the collection arrived
with. A plan header, or a tombstone's own identity and digest version, is validated before
that container's collection is counted, so a stale header digest is reported as a digest fault
rather than masked by a count mismatch. The ceilings move ahead of the WALK, not ahead of
everything.

WHAT THE COUNT DOES OVERTAKE: any RELATION over that collection's SIZE, including a count the
container declares for it. An over-ceiling collection is a BOUNDS fault whatever the container
declares, and reporting it as a mismatch describes the wrong problem -- the collection is not
merely the wrong size, it is a size no conforming producer may send. This is also the only
order every implementation can hold: obtaining a declared-count comparison first requires
knowing the actual count, and an implementation whose count is not O(1) cannot learn it
without the traversal the ceiling forbids. A declared count is therefore compared ONLY once
the collection is known to be within its ceiling.

#### Scenario: A ceiling outranks a declared count
- **WHEN** a collection exceeds its ceiling AND its container declares a different size
- **THEN** the refusal is the ceiling's, not the mismatch

COST. `length/1`-style measurement of an attacker-supplied list performs exactly the traversal
the ceiling forbids: the list is walked in full to discover it is too long. A conforming
implementation stops at `ceiling + 1` elements, which is the smallest walk that can distinguish
"at the ceiling" from "over" it. An implementation whose language makes the count O(1) satisfies
this trivially and SHALL NOT restructure to imitate the bounded walk.

NEITHER RULE IS OBSERVABLE FROM A VERDICT, which is why this requirement exists at all. A
correct implementation and a violating one refuse the same inputs and admit the same inputs;
they differ only in WHICH refusal arrives when two rules are violated at once, and in how much
work precedes it. Evidence SHALL therefore assert PRECEDENCE -- an input violating both a count
ceiling and the walk's rule, refused by the ceiling -- and SHALL assert bounded traversal by a
means that fails deterministically, not by timing.

A COUNT RUNNING AHEAD OF A STRUCTURAL WALK SEES UNVALIDATED SHAPES, and SHALL remain TOTAL over
them: a collection element that is not the expected shape has no count to take, which is a
refusal and never a crash.

#### Scenario: The ceiling wins when both rules are violated
- **WHEN** a supplied collection is over its count ceiling AND its elements would also fail the
  recursive walk
- **THEN** the refusal is the count ceiling's

#### Scenario: The walk still precedes semantics
- **WHEN** a collection is within every count ceiling and an element fails both the recursive
  walk and a semantic rule
- **THEN** the refusal is the walk's

#### Scenario: Counting does not walk the whole collection
- **WHEN** a supplied collection exceeds its ceiling
- **THEN** the refusal is produced without examining elements beyond `ceiling + 1`

### Requirement: A recovery manifest's page list SHALL be bounded BELOW as well as above
A recovery manifest's supplied page list SHALL admit exactly `1..MaxManifestPages` pages: an
EMPTY list SHALL be refused, and a list of exactly ONE page SHALL be admitted. This holds at the
RAW and at the DECODED representation alike, because each is an independently reachable
boundary.

NARROWLY SCOPED, AND THE OTHER MINIMA ARE NOT RESTATED. A plan's page list and each page's
range list already carry a minimum of 1 in the residual-bounds table, and every manifest page
already SHALL carry at least one span. `MaxSweepHostsPerBatch` deliberately carries NO minimum
and is untouched here. What was missing is only this one: the shared `MaxManifestPages` ceiling
is stated for a recovery manifest, but its minimum column speaks for the PLAN page list alone,
so an empty recovery manifest was refused by both implementations without any requirement
saying it must be.

BOTH CONTROLS ARE REQUIRED, and the second is not redundant. A refusal of the empty case alone
does not pin the minimum: an implementation tightened to demand two pages refuses the empty case
exactly as before, so a conforming and a non-conforming implementation are indistinguishable
without the ONE-page acceptance.

WHAT THIS DOES NOT CLAIM. Refusing an empty list is a property of the BOUNDARY, not evidence
that an implementation's local emptiness predicate is independently removable. At the raw
boundary in particular the check may be shadowed by the decoded one, which refuses the same
input for the same reason. Conformance is judged at the boundary.

#### Scenario: An empty recovery manifest page list is refused
- **WHEN** a supplied recovery manifest page list is empty, in either its raw or its decoded representation
- **THEN** the boundary refuses it

#### Scenario: A single-page recovery manifest is admitted
- **WHEN** a recovery manifest carries exactly one page and is otherwise conforming
- **THEN** the boundary admits it

### Requirement: A signed tombstone's declared manifest page count SHALL be bounded 1..MaxManifestPages
A `SpoolLossTombstoneV1` reaching the SIGNED recovery-control boundary SHALL declare a
`manifest_page_count` of `1..MaxManifestPages`: 0 SHALL be refused, 1 SHALL be admitted,
`MaxManifestPages` SHALL be admitted and one over SHALL be refused.

A DISTINCT RULE FROM THE PAGE-LIST BOUND, because it bounds a DECLARED SCALAR rather than a
supplied list. Where a tombstone is validated ALONGSIDE its pages, the declaration is reconciled
against the pages actually present and the list's own bound governs. On the signed path NO PAGE
LIST ACCOMPANIES IT: nothing reconciles the declaration, and the scope digest commits it exactly
as signed. A count bounded only from below therefore travels signed and unbounded, to be
questioned -- if ever -- only at assembly.

#### Scenario: A signed tombstone declaring zero pages is refused
- **WHEN** a signed recovery-control tombstone declares `manifest_page_count` of 0
- **THEN** the signed boundary refuses it

#### Scenario: A signed tombstone declaring more pages than the ceiling is refused
- **WHEN** a signed recovery-control tombstone declares a `manifest_page_count` above `MaxManifestPages`
- **THEN** the signed boundary refuses it

### Requirement: A record's declared projected cost SHALL NOT exceed the maxima its production capability carries
A record's `cost_model_version` SHALL equal the one in its production capability, and its
`projected_row_count` and `projected_write_bytes` SHALL each be less than or equal to the
corresponding maximum that capability declares. A record failing any of the three SHALL be
refused.

THIS IS A STRUCTURAL RULE, NOT AN AUTHORIZATION ONE, and the distinction is normative. The
comparison runs during whole-record validation, which performs NO cryptographic verification, so
the maxima being compared against are UNVERIFIED at that moment. It bounds a record's declared
self-description against the grant it claims to fit; it does not establish that the grant is
genuine. An implementation SHALL NOT present this check as evidence that a capability was
honoured.

THE RELATION IS INCLUSIVE on both quantities: a record declaring EXACTLY its maximum SHALL be
accepted. Each of the three conditions SHALL be independently refusable -- evidence moving two
at once cannot show which one a validator read.

WHETHER A DECLARED COST COVERS THE WORK A RECORD ACTUALLY CAUSES is a different question and is
NOT frozen here.

#### Scenario: A declared cost at the maximum is admitted
- **WHEN** a record declares exactly the row count and write bytes its capability permits
- **THEN** it is admitted

#### Scenario: Each operand refuses on its own
- **WHEN** a record exceeds exactly one of row count or write bytes, or disagrees on
  `cost_model_version`, with the others valid
- **THEN** it is refused

### Requirement: Both lane handshake halves enforce bounded credit negotiation

An `EdgeRecordLaneOpen` request SHALL carry a session nonce of 16 through 64 bytes
inclusive, request 1 through 1073741824 byte credits inclusive, and request 1
through 1048576 frame credits inclusive. Zero credits in either dimension SHALL
be refused. Its spool identifier SHALL be UUIDv7, sequence_base SHALL be 1, and
first_unresolved_sequence SHALL be at least 1. Route and traffic class SHALL be
members of their admitted platform sets. Unknown retained fields SHALL be refused.

The `EdgeRecordLaneOpenAck` validator SHALL validate the request it answers and
refuse retained unknown fields in the acknowledgement. Spool identifier, session
nonce, route and traffic class SHALL equal the request. For each credit dimension
independently, the grant SHALL satisfy `1 <= granted <= requested`. Equality and
strictly smaller positive grants SHALL both be accepted when all other rules hold.
The valid request establishes the hard caps; the return relation cannot widen them.
These are validator API requirements and do not assert live ingress attachment.

#### Scenario: Nonce endpoints and credit caps are inclusive
- **GIVEN** an otherwise valid request
- **WHEN** the nonce has 16 or 64 bytes and each credit is positive and no greater than its cap
- **THEN** the request is accepted
- **AND** nonce lengths 15 or 65, zero credits and one-over-cap credits are refused

#### Scenario: Grant bounds are independent of hard caps
- **GIVEN** a valid request whose byte and frame credits are well below their hard caps
- **WHEN** either granted dimension is zero or exceeds its requested value
- **THEN** the acknowledgement is refused even when the other dimension is legal
- **AND** equality or a strictly smaller positive grant in either dimension is accepted
