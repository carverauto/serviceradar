# edge-producer-data-plane Delta

## ADDED Requirements

> **BOUNDARY:** the wire-ABI requirements moved to the `freeze-edge-record-v1-abi`
> change, which owns the record/frame shapes, the identity and digest grammars, the
> classification-span freeze, the completion-disposition enum, the exact-received-byte
> rule, and the assignment-mapping KEY. The requirements below describe RUNTIME
> behaviour over that frozen contract. This change DEPENDS ON that one and MUST NOT
> restate or re-freeze anything it owns.

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
simultaneously as typed output, `MetricBatch`, OCSF,
`plugin_result` JSON, or a lossy copy unless one platform-owned idempotent
derivation is the sole owner of the secondary representation.

#### Scenario: selects a package subject and SQL table
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
- **GIVEN** no valid target/range collection capability
- **WHEN** it attempts to report or initiate a scan
- **THEN** output permission SHALL NOT authorize the probe or make the target
  claims authoritative
- **AND** the record SHALL be rejected or retained as non-authoritative audit
  according to the approved contract

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
