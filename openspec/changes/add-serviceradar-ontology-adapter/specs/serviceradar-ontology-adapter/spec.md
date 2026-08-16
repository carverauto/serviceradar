## ADDED Requirements

### Requirement: Non-normative replaceable host integration

The ServiceRadar adapter SHALL consume released portable core and runtime
contracts without changing their sources, features, binaries, corpora, or
profile semantics. OCSF, DIRE, AGE, SRQL, Ash, CNPG, NATS, Rustler, plugin, and
deployment-scope types MUST remain inside this adapter. Passing adapter tests MUST
NOT grant a portable profile or satisfy the independent durable-adapter
portability-GA gate.

#### Scenario: Build portable packages without the adapter

- **WHEN** core and runtime are built and tested outside ServiceRadar
- **THEN** all claimed portable vectors pass without a host dependency or feature

#### Scenario: Host type enters a portable contract

- **WHEN** a portable public API names a ServiceRadar system or type
- **THEN** the dependency and vocabulary gate fails before merge

### Requirement: Secret-free BindingManifest and append-only HostActivation

The adapter SHALL keep `BindingManifest` separate from `OntologyRelease`,
`MappingArtifact`, and `MappingDeployment`. An immutable manifest MUST contain
only non-secret credential-reference IDs, transport kind, source-instance
selector, trusted deployment-local scope, mapping-deployment digest, host ports,
and quotas. Bearer tokens, keys, passwords, and resolved secret material MUST stay
outside the manifest, its hash, logs, and portable artifacts and MUST be resolved
out of band after authorization.

Concrete append-only `HostActivation` MUST separately pin manifest digest,
`RuntimeConfigurationPin` digest, opaque `host_configuration_revision`, port-
capability digest, mode, admitted
surfaces, prior activation revision, actor, and time. Modes MUST be `disabled`,
`shadow`, `read_projection`, and `authoritative`; authority MUST apply only to
named object, property, link, or query surfaces. Activation-head promotion and
rollback MUST use compare-and-swap. The runtime MUST receive only the pin request.
With no activation, the adapter MUST be disabled. Unadmitted
surfaces MUST retain existing authority.

#### Scenario: Deploy with no enabled manifest

- **WHEN** adapter code and schemas are installed with default configuration
- **THEN** no consumer, projection substitution, or ontology query surface starts
  and existing behavior is unchanged

#### Scenario: Promote one link projection

- **WHEN** an administrator promotes one named link surface from shadow with the
  expected activation revision
- **THEN** only that surface uses the pinned runtime resolved links

#### Scenario: Credential reference is resolved

- **WHEN** an activated manifest names an authorized credential-reference ID
- **THEN** the secret resolver supplies material out of band without adding it to
  manifest, activation, hash, artifact, log, or runtime configuration

### Requirement: Pure bounded Rustler wrapper

The Rustler wrapper SHALL expose only bounded pure calls for portable artifact
verification, mapping compilation and evaluation, typed validation, identity-
response application, resolution, and semantic-query validation. A NIF MUST NOT
perform Ash, CNPG, AGE, DIRE, SRQL, NATS, filesystem, credential, network, or
plugin I/O. Calls MUST enforce portable limits, choose an appropriate scheduler,
support cancellation, contain panics, quota content-addressed handles, and avoid
creating atoms from untrusted strings.

#### Scenario: Mapping requests external identity

- **WHEN** pure evaluation emits a typed unresolved identity request
- **THEN** Elixir invokes DIRE outside the NIF and supplies a versioned response
  to a later bounded call

#### Scenario: Malformed artifact reaches Rustler

- **WHEN** input is malformed, oversized, corrupt, or uses an unknown required
  field
- **THEN** the call returns a bounded structured error without host I/O, panic,
  atom creation, handle leak, or blocked scheduler

### Requirement: Trusted scope, authorization, and host-store atomicity

The adapter SHALL construct opaque principal and scope only from an authenticated
actor and trusted deployment-local Ash scope. Caller-supplied deployment IDs MUST
NOT select data. CNPG search paths, AGE materialization, SRQL translation,
protected evidence, and audit MUST preserve that scope. Administration, evidence,
replay, mutation, projection substitution, and semantic query MUST have distinct
host authorization checks.

Ash/CNPG ports MUST atomically enforce ontology, mapping deployment, source
authority, resolution, identity, cursor, idempotency tuple, scope, and activation
pins while persisting bitemporal object/link observations, resolved state,
tombstones, protected evidence, and redacted audit. Logs, telemetry, APIs, and
ordinary audit MUST NOT expose protected payloads or identity claims.

#### Scenario: Cross-deployment evidence handle is presented

- **WHEN** an actor supplies a handle owned by another deployment-local scope
- **THEN** authorization fails before retrieval and only a redacted denial is
  audited

#### Scenario: Activation changes before commit

- **WHEN** a plan pins a `HostActivation` revision that is no longer current
- **THEN** no observation, resolved object, resolved link, cursor, or completion
  changes

### Requirement: Complete native source envelopes

Each source adapter SHALL validate its native contract and convert a completed
record, delta, or collection into bounded portable source values. It MUST record
native contract version, source instance, record ID, host-attested reset epoch,
tagged sequence or event revision coordinate, completion proof, cursor, canonical input digest, observed time, valid
time, and sensitivity. Partial pages MUST be staged and MUST NOT assert absence.
Source cursor advancement MUST be atomic with successful runtime mutation.

Cross-record relationships MUST arrive as preassembled bounded envelopes or
explicit relationship records with typed endpoint keys. The runtime evaluator
MUST NOT query ServiceRadar storage to complete a mapping. Provider fields and
native unions MUST remain in host source schemas and mapping artifacts.

#### Scenario: Completed inventory collection is admitted

- **WHEN** every page and digest validates and completion is committed
- **THEN** the adapter submits one logical snapshot boundary that may assert
  source-owned absence

#### Scenario: Relationship requires hidden store join

- **WHEN** native input lacks endpoint keys and mapping would need a store lookup
- **THEN** evaluation is rejected until the adapter supplies an explicit complete
  relationship record

### Requirement: Schema-bound DIRE identity without guessing

The adapter SHALL support exact and binding-local source-scoped identity and MAY
use DIRE as an external identity port. Exact and binding-local identity MUST be
limited to ontology-local object types for which the host has no existing native
identity authority. Bindings to canonical ServiceRadar devices and other
DIRE-governed native types MUST use DIRE. A DIRE request MUST use the target
object type's declared identity-key schema and exact typed components. The
response MUST preserve canonical identity, ambiguity, merge/split reassociation,
and association revision. Ambiguity MUST NOT be guessed. One activated host
configuration MUST NOT mix identity modes for the same object type and
identity-key schema. Changing the identity authority for an existing native type
requires a separately approved migration contract.

#### Scenario: DIRE revises an endpoint through a split

- **WHEN** a split advances the association revision for a linked object
- **THEN** affected resolved objects and links are invalidated until replay pins
  the new decision

#### Scenario: Canonical device binding attempts to bypass DIRE

- **WHEN** a manifest selects exact or binding-local identity for a canonical
  ServiceRadar device type
- **THEN** activation rejects the manifest without admitting observations

#### Scenario: One type declares conflicting identity modes

- **WHEN** an activated configuration would use more than one identity mode for
  the same object type and identity-key schema
- **THEN** activation rejects the configuration with a value-free diagnostic

### Requirement: AGE is a disposable ResolvedLink materialization

The adapter SHALL treat portable runtime and canonical host-store
`ResolvedLink` state as the sole semantic link authority. AGE MUST receive only
already-resolved link ID, type, ordered roles, canonical endpoints, optional
multiedge discriminator, bitemporal bounds, and revision pins. AGE MUST NOT mint
link identity, resolve endpoint keys or conflicts, enforce cardinality, turn an
object-reference property into an edge, or override direct or object-backed
relationship state.

Every graph entry MUST pin its source resolved-link revision. Drift detection
MUST remove unexpected entries and rebuild missing or stale entries from the
canonical store. Dropping and rebuilding AGE MUST preserve all semantic evidence
and query results supported by the canonical store.

#### Scenario: AGE contains an extra edge

- **WHEN** a graph edge has no matching current resolved-link ID and revision
- **THEN** drift repair deletes it and never imports it as semantic evidence

#### Scenario: Rebuild object-backed relationship roles

- **WHEN** AGE is recreated from canonical runtime state
- **THEN** relationship-object role links retain their original semantic link
  IDs, endpoints, discriminator, and time bounds

### Requirement: Exact ordered bitemporal query translation

The adapter SHALL translate an authorized, portable-validated semantic query into
equivalent SRQL, CNPG, and optional AGE operations or return a stable unsupported-
capability code. Translation MUST preserve object/interface constraints, direct
and object-backed roles, `valid_at`, `known_at`, ordered sort terms, canonical-ID
tie-break, value/null/absent predicates and bucket order,
`RuntimeConfigurationPin` digest, typed stable keyset cursor, exact-count mode, deployment
scope, and the 256-node/8-traversal/1,000-page bounds and cost budget. Host
activation and scope MUST seal the portable cursor outside the runtime. It MUST
NOT drop a constraint or substitute approximate,
current-only, offset-pagination, or partial semantics. Existing SRQL calls MUST
remain unchanged without an active manifest.

#### Scenario: AGE cannot satisfy historical knowledge time

- **WHEN** a query requires `known_at` history not present in the graph cache
- **THEN** translation uses canonical CNPG history or returns unsupported, never a
  current graph approximation

#### Scenario: Query budget is exhausted

- **WHEN** host execution reaches the portable cost ceiling
- **THEN** it returns no partial page, approximate count, or successor cursor

### Requirement: Streaming telemetry remains JetStream-first

Metrics, logs, traces, security events, and other streaming telemetry SHALL reach
NATS JetStream before any ontology consumer or persistence path. Durable stream
identity, source-contract version, host-attested reset epoch, tagged sequence or
event coordinate, and input
digest MUST enter envelope provenance and idempotency fences. The adapter MUST NOT
add a collector-to-CNPG or collector-to-ontology-store bypass. Applying a
validated mutation in one host transaction MUST NOT require republishing and
reading that plan back through JetStream.

#### Scenario: Streaming metadata enters a manifest

- **WHEN** a durable consumer receives a bound event
- **THEN** its stream coordinates are pinned before mapping and atomic mutation

### Requirement: Three host fixtures without portable changes

The adapter SHALL test OCSF systems/findings/exposure relationships, SNMP
devices/interfaces/addresses/attachment links, and OpenTelemetry resources,
services/runtime instances/dependency links. Fixtures MUST exercise source
records and unions, exact and external identity, multi-source object existence,
final tombstones, direct and object-backed links, endpoint revisions, all
applicable resolution policies, replay, and ordered bitemporal queries. Core and
runtime source, features, binaries, and corpus outputs MUST remain unchanged.
Neutral and textile-certification portable suites MUST also run to detect host
coupling. These host tests MUST NOT count as normative portable or durability
conformance.

#### Scenario: Run unrelated host fixtures

- **WHEN** all three suites run
- **THEN** only host source schemas, mappings, deployments, manifests, port
  responses, and expected host results differ

### Requirement: Failure isolation and rollback

The adapter SHALL turn admission, mapping, identity, storage, materialization, or
query failure into bounded redacted audit and no partial observation, resolved
state, cursor, activation, or completion. A shadow failure MUST NOT affect
existing reads or writes. An admitted surface MUST follow its explicit fail-
closed manifest and MUST NOT use a semantically weaker fallback. Existing native
ingestion MUST continue when ontology evaluation is unavailable. Rollback MUST
append and CAS a new `HostActivation` in `disabled` or the recorded previous mode
and MUST NOT disable or mutate immutable `BindingManifest`. It MUST restore
recorded previous authority while retaining isolated ontology history.

#### Scenario: Runtime is unavailable in shadow

- **WHEN** a shadow source cannot be evaluated
- **THEN** existing ingestion continues, no shadow cursor advances, and a bounded
  failure is audited

#### Scenario: Roll back one admitted query surface

- **WHEN** an administrator rolls back the current activation head
- **THEN** a new `HostActivation` is CAS-appended in `disabled` or previous mode,
  the manifest remains unchanged, and subsequent calls use previous authority

### Requirement: Frozen edge-record handoff preserves admission and identity domains

When a binding consumes `EdgeRecordV1`, the adapter SHALL construct a portable
`SourceRecord` only from an event already admitted by the applicable frozen edge
contract, including its raw-byte bounds, authenticated carrier and capability
checks, delivery-slot-to-artifact binding, output-contract validation, semantic-
envelope verification, and event-ledger idempotency or conflict checks. The
adapter MUST consume a durable admitted-event result or authorized canonical view
that attests that prior admission; a raw pre-admission frame MUST NOT be an
ontology source. Successful protobuf decode or decode/re-encode equality MUST NOT
substitute for admission. Ontology failure after the handoff MUST NOT change edge
admission, delivery, ACK, native canonical-write transactions, or the accepted
event's upstream disposition.

The adapter SHALL preserve, without collapsing, the edge pipeline-stage
identities:

- `submission_sha256` is producer-journal-local, is absent from the wire, and
  MUST NOT be required, synthesized, or placed in the portable source envelope;
- `record_sha256` identifies exact encoded `EdgeRecordV1` bytes and SHALL remain
  physical artifact and delivery evidence;
- `semantic_envelope_sha256` is verified upstream semantic-identity evidence;
- `payload_sha256` is verified exact payload-artifact evidence committed by the
  semantic envelope; and
- `(network_scope_id, event_id)` remains the logical edge-event ledger identity.

The portable runtime's `canonical input hash` is a separate identity and MUST
equal the `SourceRecord` logical contract ID defined by the portable core
requirement `Canonical artifacts and integrity`. It MUST NOT replace or be
represented as any edge digest. For an event-mode edge source
contract, the portable revision coordinate MUST preserve the exact edge
`event_id` as an unordered immutable event ID. The binding SHALL define its
trusted opaque-host-scope mapping, versioned `source_instance_id` and `record_id`
mapping, and host-attested `reset_epoch` explicitly. The admitted
`network_scope_id` MUST match authenticated server context and MUST NOT select
deployment scope. Delivery, retry, and recovery changes MUST NOT advance the
reset epoch. `spool_id`, delivery sequence, `publication_lane_id`, publication
sequence, broker message or delivery ID, delivery capability or proof, delivery
mode, and transport provenance MUST NOT become the portable sequence coordinate,
record identity, reset epoch, source authority, or supersession order. Those
values MAY fence delivery consumption and SHALL remain separately authorized host
physical evidence, but MUST remain outside the portable semantic coordinate and
portable runtime canonical input hash.

`HostActivation` SHALL select an authorized `BindingManifest` independently of
source payload. That selected binding SHALL pin the schema-stable edge contract
identity (`contract_id`, `contract_version`, and `contract_bundle_sha256`) and its
portable source-contract version and mapping deployment. The adapter SHALL
equality-check those values against the admitted record and preserve the complete
`EdgeOutputContractRef`, including registry epoch, registry snapshot, and
effective grant, as admission evidence. The edge reference, production or
delivery capability, and
`EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE` MUST NOT themselves become
a portable `SourceContract`, ontology release, `SourceAuthority`,
`RuntimeConfigurationPin`, `HostActivation`, or payload-controlled selector.
Edge Hello negotiation, lane-open coordinates, and the portable port-capability
descriptor MUST remain separate and MUST NOT be inferred from one another.
Authenticated agent or service identity SHALL remain trusted carrier provenance
and MUST NOT be replaced by producer attribution carried inside the record.

Under the same selected immutable binding, portable source-contract and adapter-
transform versions, coordinate mapping, host-attested reset epoch, and recorded
first-acceptance `known_at`, retries, legal outer-record re-encodings, and recovery
rewrapping with equal edge ledger and semantic-envelope identities SHALL produce
one canonical portable semantic input. Repeated portable admission SHALL be a no-
op; the host MAY append a new physical receipt without mutating the accepted
`SourceRecord`. A changed semantic-envelope identity under an existing edge
ledger key MUST NOT reach portable source admission. The native host MAY retain
the ledger disposition and conflict evidence, but neither SHALL be treated as an
ontology source.

Raw signed nanosecond timestamps SHALL remain unchanged through edge admission
and every edge hash or identity comparison. A named and versioned adapter
transform MAY convert a domain timestamp to the portable signed-microsecond type
only afterward, MUST use the containing microsecond bucket by mathematical floor,
and MUST retain the original nanoseconds as typed source evidence when the native
contract requires exact replay or audit. Before activation, the adapter change
MUST amend the enumerated projection-consumer list in the frozen edge requirement
`Nanosecond time is canonicalized to microseconds only at the projection
boundary` to name this consumer. `valid_at` MUST come from declared domain
evidence under the versioned
source contract and MUST NOT be inferred from UUIDv7 allocation time, broker
arrival, or delivery order. `known_at` MUST come from the authorized host clock
when the durable ontology runtime first accepts the exact portable coordinate.
Duplicate delivery MUST reuse the recorded first-acceptance value; `known_at`
MUST NOT come from producer, payload, broker, spool, or recovery time.

The complete canonical portable source envelope SHALL remain within the 1 MiB
runtime ceiling and all other portable limits. Delivery-varying physical evidence
MUST remain outside that envelope and its canonical input hash. Stable source
provenance required by the portable source contract SHALL remain in the immutable
`SourceRecord`. Any durable-stream identity included there MUST be a binding-
owned logical identity invariant across original and recovery placement. A
concrete NATS stream, subject, or lane placement, JetStream consumer cursor,
publication coordinate, delivery attempt, broker receipt, or consumer position
SHALL remain in the outer host unit-of-work, idempotency fence, and audit record;
it MUST NOT become a portable source cursor or enter the portable runtime
canonical input hash. Exact raw frame and record bytes MAY remain behind
authorized protected-evidence references under host retention policy, but every
value required by pure mapping MUST be present in the bounded envelope
because the evaluator cannot dereference a handle. The adapter SHALL provide a
worst-case sizing proof and MUST NOT truncate, silently split, or partially admit
an oversized conversion. Portable conversion failure MUST leave the already
accepted native event unchanged.

Portable replay SHALL use the exact retained canonical `SourceRecord` and its
historical portable pins. Replaying native Edge-to-Source adaptation SHALL
additionally require exact admitted native evidence, edge-admission version,
trusted carrier attestation, selected binding, coordinate mapping, and adapter-
transform version. A digest or unresolved evidence handle alone MUST NOT satisfy
replayability. If host retention no longer preserves the native input, native
translation SHALL be non-replayable even when the already-retained portable
envelope remains replayable.

If a binding consumes edge loss or recovery artifacts, it SHALL use a separate
explicit source contract and those artifacts MUST first pass their Edge Record V1
freeze gate. Neither a declared delivery-loss span nor a sequence outside the
declared loss union makes a claim about the existence, absence, supersession, or
retraction of ontology evidence.

#### Scenario: One event is legally re-encoded and redelivered

- **WHEN** the same admitted event is processed under the same selected binding,
  source-contract and transform versions, coordinate mapping, reset epoch, and
  recorded `known_at`, with unchanged `event_id` and
  `semantic_envelope_sha256` but a different legal outer encoding and
  `record_sha256` carried on a different valid delivery slot
- **THEN** the adapter produces the same portable source coordinate and canonical
  input hash while the host may append the new physical delivery evidence

#### Scenario: One delivery slot presents different physical bytes

- **WHEN** an existing agent or service delivery slot presents a different
  `record_sha256` than the artifact already bound to that slot
- **THEN** no portable `SourceRecord` is constructed; the native host may retain
  the ledger disposition and conflict evidence, but neither is an ontology source

#### Scenario: Producer receipt identity is unavailable downstream

- **WHEN** an admitted edge event reaches the ontology adapter without the
  journal-local `submission_sha256`
- **THEN** the adapter constructs the source envelope from admitted downstream
  evidence and neither requires nor synthesizes the missing producer receipt

#### Scenario: Delivery sequence advances

- **WHEN** a recovered or retried event arrives at a later spool or publication
  sequence
- **THEN** that coordinate does not select portable `sequence(u64)` and implies
  no semantic supersession, absence, or retraction

#### Scenario: Equal event IDs arrive under different trusted scopes

- **WHEN** two admitted events carry equal `event_id` bytes under different
  authenticated `network_scope_id` values
- **THEN** their trusted opaque-host-scope mappings produce distinct portable
  source coordinates

#### Scenario: Recovery changes delivery without resetting source history

- **WHEN** an admitted event is rewrapped under a different valid delivery slot
  without a host-declared source reset
- **THEN** its host-attested portable `reset_epoch` remains unchanged

#### Scenario: Duplicate delivery is known once

- **WHEN** the same portable coordinate and canonical input hash are delivered
  again after first durable ontology acceptance
- **THEN** the runtime returns the original result with its recorded `known_at`
  rather than assigning the duplicate a later value

#### Scenario: Edge capability is presented as ontology authority

- **WHEN** an admitted record carries a valid output or delivery capability but
  no independently active ontology binding and source authority
- **THEN** no ontology mapping, observation, retraction, or authority transition
  occurs

#### Scenario: Sub-microsecond source time is mapped

- **WHEN** an admitted source value contains `-1500` nanoseconds
- **THEN** edge identity verification uses the unchanged nanosecond value, the
  portable mapped timestamp is `-2` microseconds, and the raw value remains
  available under the source contract's evidence policy

#### Scenario: Recovery reports a lost delivery span

- **WHEN** a frozen recovery artifact proves that physical delivery slots were
  lost
- **THEN** the adapter infers no missing ontology fact, absence, or retraction
  from that span

#### Scenario: A recovery sequence is outside every declared loss span

- **WHEN** a frozen recovery artifact declares loss spans `[1,1]` and `[3,3]`
  while sequence `2` is outside their union
- **THEN** the adapter infers no loss, existence, absence, supersession, or
  retraction claim for sequence `2`

#### Scenario: Native input expands beyond a portable ceiling

- **WHEN** an accepted bounded edge event would produce an oversized portable
  envelope or more than 1,024 observations and retractions
- **THEN** ontology conversion fails atomically without truncation, splitting,
  partial output, cursor advance, or changing native edge acceptance
