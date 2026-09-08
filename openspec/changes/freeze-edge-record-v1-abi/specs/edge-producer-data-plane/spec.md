## ADDED Requirements
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
   is valid. A PRESENT `source_authorization` whose kind is
   `EDGE_SOURCE_AUTHORIZATION_KIND_UNSPECIFIED` SHALL be REJECTED: it asserts a
   source authorization while naming none.
   SOURCE PRESENCE IS INDEPENDENT OF ATTRIBUTION CLASSIFICATION. Absence SHALL NOT
   be read as, or equated with, PASSIVE -- PASSIVE asserts only that a record claims
   no produced target range, which is a different question from whether a source
   authorization is carried. All four combinations of
   {ACTIVE, PASSIVE} x {source present, source absent} are legal and SHALL each be
   representable; no component SHALL infer one axis from the other.
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
- **AND** an ABSENT `source_authorization` SHALL remain valid, being the only way to
  express no source authorization

#### Scenario: Source presence is not read as an attribution classification
- **GIVEN** a record whose `source_authorization` is absent
- **WHEN** its attribution classification is determined
- **THEN** the absence SHALL NOT make it PASSIVE, and an ACTIVE record with no
  source authorization SHALL remain legal
- **AND** neither axis SHALL be inferred from the other


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
leaf preimage, so the numbering is part of the digest grammar. It is currently
written twice and generated from nothing -- as a Go `iota` block
(`MtrTerminalDisposition`) and as literal integers in Elixir guards -- which is
exactly the hand-maintained numeric parity that can silently diverge. Two
implementations that disagree by one produce two different completion roots for
the same completion, and the disagreement surfaces as an unexplained proof
mismatch rather than as a compile error.

`MtrCompletionDisposition` SHALL be distinct from the per-hop `MtrOutcome` and
SHALL NOT reuse its numbering. They describe different things -- what happened to
a planned MTR ordinal versus what a probe observed at a hop -- and collapsing them
would make the leaf grammar depend on an enum that evolves for unrelated reasons.

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

#### Scenario: Bloated page is refused
- **WHEN** a page's received bytes exceed its ceiling but its re-encode does not
- **THEN** the page SHALL be rejected

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

This ABI change freezes the KEY and the tagged VALUE shape only. Whether such a
mapping EXISTS, and everything it then does, is downstream runtime work with its
own task -- this requirement SHALL NOT be read as asserting the mapping's
existence, which would make an ABI change depend on runtime it does not own.

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

Stating the key as "exactly the span identity" would be AMBIGUOUS: the span
identity as defined does NOT include the trust namespace, while the key must, so
that phrasing permits two incompatible implementations. The pair is explicit for
that reason.

The VALUE SHALL be a TAGGED body: POSITIVE (execution, plan, and range identities
and digests, shard, epoch, and the contract-specific correlation operand) or
EXPLICIT NEGATIVE (durable negative evidence and reason, no positive-only fields).
A single untagged schema cannot express both, because a durable negative means
there is no execution.

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

#### Scenario: A durable negative is representable
- **WHEN** an assignment has no scheduler execution
- **THEN** the mapping SHALL be able to record an explicit negative
- **AND** SHALL NOT require fabricating positive-only fields
