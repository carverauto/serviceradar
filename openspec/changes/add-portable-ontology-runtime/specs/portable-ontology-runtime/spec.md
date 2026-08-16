## ADDED Requirements

### Requirement: Layered immutable runtime artifacts

The runtime SHALL own `SourceContract`, `SourceSchema`, mapping language/compiler
and evaluator, `MappingArtifact`, `MappingDeployment`, candidates, observations,
resolution, query, ports, and SQLite while keeping core semantics and host state
separate. An `OntologyRelease` MUST remain semantic-only. A mapping artifact MUST
pin exactly one source-contract version and schema and exactly one ontology release, mapper contract,
capability profile, compiled mapping, and its own logical ID. An immutable mapping
deployment MUST pin exactly one mapping artifact, exactly one `SourceAuthority`
revision, `source_binding_slot`, output-ownership namespace, quotas, and downward-
only limits. It MUST NOT contain a concrete source instance, resolution binding,
generation, mode, or activation and MUST NOT activate itself. Concrete `BindingManifest` and
`HostActivation` MUST be host-adapter state. The runtime MUST receive only a
`RuntimeConfigurationPin` request containing exact ontology release, deployment
set, resolution bindings, opaque `host_configuration_revision`, and port-
capability digest. Runtime MUST validate known fields, compare the opaque fence,
compute the pin digest, and own no activation state.

#### Scenario: Activate one mapping in two hosts

- **WHEN** two hosts use the same mapping deployment with different
  `RuntimeConfigurationPin` requests
- **THEN** the portable ontology, mapping, and deployment digests remain equal
  while host activation and configuration remain independent

#### Scenario: Mapping field enters an ontology release

- **WHEN** a release artifact contains a source selector, mapping expression,
  source authority, or activation field
- **THEN** artifact validation rejects the layer violation

### Requirement: Immutable SourceContract semantics

The runtime SHALL define immutable `SourceContract` versions with stable contract,
record-kind, and field IDs; one bounded `SourceSchema`; allowed tagged
`sequence(u64)` or `event_id(canonical bounded bytes)` revision coordinate and
host-attested reset semantics; classification floor; allowed semantic targets;
and exactly one ingestion mode: `event`, `delta`, `per_object_snapshot`, or
`complete_collection`. Event and delta modes MUST require explicit retractions.
Per-object snapshot MAY infer absence only within that record's owned output
lineage. Complete collection MAY infer collection absence only after a verified
completion boundary. Payload values MUST NOT select host scope, authorization,
ontology release, mapping deployment, source authority, or canonical object ID.
Bounded extras MUST be preserved as opaque evidence but MUST NOT be selectable by
mapping until a later contract version declares stable field ID and schema.
Mapping outputs MUST NOT lower the contract classification floor.

#### Scenario: Complete collection proves absence

- **WHEN** a complete-collection envelope verifies its declared boundary
- **THEN** absence may retract only outputs owned by that contract, instance,
  collection lineage, authority, and prior sequence

#### Scenario: Event omits an earlier field

- **WHEN** an event envelope omits output from an earlier event ID
- **THEN** no absence is inferred without an explicit retraction

#### Scenario: Payload attempts to select authority

- **WHEN** a source value claims a scope, release, deployment, authority, or
  canonical object ID
- **THEN** admission ignores it as control input and rejects the contract if the
  field is declared for that purpose

#### Scenario: Mapping selects an opaque extra

- **WHEN** mapping references an extras key without a stable declared field ID
- **THEN** compilation fails while the extra remains preserved as opaque evidence

### Requirement: Bounded source shapes and pure source mapping

The runtime SHALL support source scalars plus source-only bounded records,
homogeneous lists, and tagged unions. A record MUST declare its fields and reject
unknown fields unless it declares a bounded extras field. A tagged union MUST
declare one discriminator and exactly one schema-valid variant. Nesting depth
MUST NOT exceed 8, a record MUST NOT exceed 1,024 fields, and a list MUST NOT
exceed 1,024 elements. Source-only records and unions MUST be projected into
declared core semantic values before emission.

An immutable mapping MUST use bounded deterministic selectors, transforms, typed
identity-key templates, and emission templates. It MUST produce `ObjectCandidate`
values with exact object-type version, identity-key schema ID and components,
property candidates, relationship candidates, and retractions. A candidate MUST
NOT contain canonical object ID or association revision. Evaluation MUST NOT
perform I/O or store lookup. A cross-record relationship MUST arrive in a preassembled
bounded envelope or an explicit relationship record with typed unresolved
endpoint key references. The envelope MUST preserve assembly provenance and
digest.

#### Scenario: Map a tagged source event

- **WHEN** an envelope contains one declared tagged-union variant and a bounded
  nested record
- **THEN** mapping validates that variant and deterministically projects selected
  fields into semantic observations

#### Scenario: Evaluator attempts a cross-record lookup

- **WHEN** a mapping requires fetching another source record or current object
  from a store
- **THEN** mapping compilation fails and requires a preassembled envelope or
  explicit relationship record

### Requirement: Bounded mapping evaluation

The `ontology-runtime-v1` mapping profile SHALL limit one schema to 1,024 fields,
one envelope to 1 MiB canonical bytes, one mapping to 256 emission templates, one
template to 256 expression nodes, one iteration to 1,024 items, one record to
1,024 observations and retractions, and one plan to 4 MiB canonical bytes. Core
value limits also apply. Compilation MUST reject a statically excessive maximum.
Evaluation MUST count actual nodes, iterations, outputs, bytes, and diagnostics
and return no partial plan when a limit is exceeded.

#### Scenario: Data-dependent fan-out reaches the ceiling

- **WHEN** evaluation would emit observation 1,025 for one record
- **THEN** it returns a stable fan-out-limit error and no candidate plan

### Requirement: Exact source-coordinate idempotency

Every record mutation SHALL use the exact idempotency tuple
`(opaque_host_scope, source_contract_version_id, source_instance_id, record_id,
reset_epoch, revision_coordinate)` and canonical input hash. The revision
coordinate MUST be tagged `sequence(u64)` or `event_id(canonical bounded bytes)`.
Scope and reset epoch MUST be host-attested. Sequence MUST be monotonic per exact
source-instance, record lineage, and epoch and MAY supersede owned earlier output
only in that exact lineage. Event ID MUST be unordered and immutable and MUST NOT
imply supersession or absence. An identical tuple and hash MUST be a recorded no-
op. The same tuple with a different hash MUST be quarantined as corruption.

#### Scenario: Retry the same record revision

- **WHEN** a committed tuple is retried with the identical canonical input hash
- **THEN** the store returns the original result without duplicate observations,
  retractions, cursors, or audit completion

#### Scenario: Source reuses a revision with different bytes

- **WHEN** a tuple already exists and a new envelope has a different canonical
  input hash
- **THEN** the runtime reports corruption and applies nothing

#### Scenario: Higher sequence supersedes owned output

- **WHEN** a higher sequence arrives in the same attested scope, contract,
  instance, record, epoch, and output lineage
- **THEN** it may supersede that lineage's earlier source-owned outputs only

#### Scenario: Unordered event omits prior output

- **WHEN** a new event ID lacks an output emitted by an earlier event ID
- **THEN** no absence or supersession is inferred without an explicit retraction

### Requirement: Candidate identity admission and object lifecycle

The runtime SHALL resolve each `ObjectCandidate` before admission and represent
source-owned `ObjectObservation` plus derived `ResolvedObject`. Resolution MUST
consume exact object-type version and typed identity-key components and return
canonical object ID plus association revision. Ambiguous or rejected resolution
MUST create neither observation nor object. An admitted observation MUST pin
canonical object ID, stable object-type ID, exact type version, association
revision, source authority and coordinate, valid interval, `known_at`, existence,
properties, and provenance. One canonical object ID MUST remain permanently bound
to one stable object-type ID. A source authority MUST retract only observations
it owns.

A resolved object MUST be active while at least one eligible unretracted
existence assertion remains. Retraction of the final eligible assertion MUST
create a final-evidence tombstone without deleting history or recycling identity.
Current properties and links MUST become ineligible at the tombstone view while
historical bitemporal queries remain valid.

#### Scenario: One of two sources retracts an object

- **WHEN** one authority retracts its existence evidence and another eligible
  authority still asserts existence
- **THEN** the resolved object remains active with both histories preserved

#### Scenario: Final authority retracts existence

- **WHEN** the last eligible existence assertion is retracted
- **THEN** the runtime creates a final-evidence tombstone and removes the object
  and incident links only from current resolved views

#### Scenario: Observation changes concrete type

- **WHEN** a later record assigns an existing canonical object ID a different
  concrete type
- **THEN** mutation fails rather than changing the object's type

#### Scenario: Candidate identity is ambiguous

- **WHEN** identity resolution returns ambiguous or rejected for an
  `ObjectCandidate`
- **THEN** no `ObjectObservation`, canonical object, property, or link is created

#### Scenario: Identity resolves successfully

- **WHEN** exact type version and typed key components resolve to one canonical
  object and association revision
- **THEN** the admitted observation pins both and preserves the candidate type
  version

### Requirement: Identity revisions invalidate merge and split dependents

The runtime SHALL pin a monotonic association revision on each object,
link, and mutation plan. A merge or split MUST create a new revision and explicit
alias or reassociation records rather than editing historical observations. When
a decision is superseded, every dependent current `ResolvedObject` and
`ResolvedLink` MUST become invalid and unavailable until deterministic replay or
rebuild pins the new revision. An endpoint reassociation MUST NOT leave a link
current under its old endpoint decision.

#### Scenario: Two identities merge

- **WHEN** the resolver advances its revision and aliases two objects to one
  canonical identity
- **THEN** dependent object and link projections are invalidated and rebuilt
  before becoming current

#### Scenario: Merged identity later splits

- **WHEN** a later resolver revision separates previously aliased evidence
- **THEN** history retains both decisions and no projection pinned to the merge
  remains current

### Requirement: Exact SourceAuthority eligibility

The runtime SHALL use a versioned `SourceAuthority` that pins source-contract
version and instance selectors, allowed semantic targets and existence ownership,
optional confidence ppm `0..1_000_000`, authority valid-time and known-time half-
open intervals with required lower and optional upper bounds, classification
floor, output quota, optional `max_age_us`, and resolution class. A candidate MUST
be eligible at `(valid_at, known_at)` only if deployment and authority revision are
active; source, target, and existence are admitted; confidence is in range; both
query times fall inside authority intervals; classification meets the floor;
quota is not exceeded; observation valid interval contains `valid_at`; it was
known by `known_at`; it is not retracted by `known_at`; association revision is
current; value is schema-valid; and, when `max_age_us` is
set, `valid_at` is in the half-open interval
`[valid_from, valid_from + max_age_us)`. Freshness MUST NOT compare `known_at`.

Missing input MUST emit nothing. Null MUST be a candidate only for a nullable
property and MUST NOT mean retraction. Stale, null, superseded, and retracted
candidates MUST remain available through historical and provenance queries.

#### Scenario: Candidate becomes stale

- **WHEN** `valid_at` equals `valid_from + max_age_us` for an otherwise valid
  observation
- **THEN** the candidate is excluded from that resolved view but retained in
  evidence history

#### Scenario: Source omits a nullable field

- **WHEN** an input record lacks the field and emits neither null nor retraction
- **THEN** existing source-owned evidence is unchanged

#### Scenario: Authority known-time window excludes evidence

- **WHEN** query `known_at` equals the optional upper bound of the authority's
  known-time interval
- **THEN** the candidate is ineligible because the interval is half-open

#### Scenario: Authority quota or classification is violated

- **WHEN** output exceeds authority quota or falls below its classification floor
- **THEN** admission rejects it before resolution

### Requirement: Closed deterministic V1 resolution policies

The runtime SHALL first supersede a lower `sequence(u64)` only within the exact
record/output lineage and then support exactly `single_authority`, `precedence`,
`latest_valid`, `highest_confidence`, `union_set`, and `reject_conflict` in V1.
Event IDs MUST NOT implicitly supersede. `single_authority` MUST admit one
configured authority and choose greatest `valid_from` among its eligible
candidates. `precedence` MUST choose the first listed authority with evidence and
then greatest `valid_from` within it. `latest_valid` MUST rank greatest
`valid_from`. `highest_confidence` MUST rank integer confidence parts-per-million
`0..1_000_000` then greatest `valid_from`. `union_set` MUST union all eligible
elements, deduplicate by canonical semantic bytes, and order by those bytes.
`reject_conflict` MUST resolve only if every eligible value has equal canonical
semantic bytes.

Unequal values tied at the final semantic rank MUST be `unresolved_conflict`;
IDs MUST order diagnostics only and MUST NOT choose a winner. No evidence MUST be
`unresolved_no_evidence`. A retraction MUST remove only its referenced source-
owned candidate. For `union_set`, null beside any set MUST conflict; all-null MAY
resolve null only for a nullable output. `union_set` and `reject_conflict` MUST be
property-only. Link resolution MUST use only `single_authority`, `precedence`,
`latest_valid`, or `highest_confidence` per logical link identity.

#### Scenario: Precedence skips an ineligible authority

- **WHEN** the first configured authority has only stale or retracted evidence and
  the second has eligible evidence
- **THEN** precedence selects the second authority and records why the first was
  ineligible

#### Scenario: Highest-confidence tie disagrees

- **WHEN** two eligible values have equal confidence ppm and `valid_from`
  but unequal canonical bytes
- **THEN** resolution returns `unresolved_conflict`

#### Scenario: Union includes source-owned retractions

- **WHEN** one source retracts its set observation while another remains eligible
- **THEN** union excludes only the retracted source's elements not asserted by
  another eligible source

### Requirement: Runtime-authoritative direct and object-backed links

The runtime SHALL be the sole semantic authority for `ResolvedLink`. Direct link
identity MUST be `(link_type_version_id, ordered role-to-canonical-object pairs,
multiedge discriminator)`, with role order from the ontology release. Forward and
inverse traversal MUST use the same link ID. A simple link MUST reject a
discriminator. Equal eligible observations for the same simple logical identity
MUST coalesce with joined provenance. A multiedge
link MUST declare a typed discriminator and require it. Cardinality violations
MUST return explicit conflicts only for distinct logical identities and MUST NOT
overwrite an existing link.

A mapping MAY emit a typed `UnresolvedEndpointKey` containing expected object
type or interface, identity-key schema ID, and exact components. It MUST resolve
to a current canonical object before link admission. An object-reference property
MUST NOT be traversed as a link. Object-backed relationships MUST use a normal
relationship object plus at least two typed endpoint observations; their object owns identity,
existence, properties, and history while the runtime derives role-addressable
resolved links. Every link MUST pin endpoint association revisions and become
invalid on endpoint tombstone, merge, split, or reassociation.

A host graph MUST be treated only as a rebuildable materialization or cache and
MUST NOT mint link IDs, resolve conflicts, or become semantic authority.

#### Scenario: Traverse the inverse role

- **WHEN** a direct link is queried from its inverse endpoint
- **THEN** the runtime returns the same link ID and opposite declared role without
  storing an independent inverse fact

#### Scenario: Two parallel links lack a discriminator

- **WHEN** a multiedge type receives two links with equal endpoints and no typed
  discriminator
- **THEN** both are rejected as identity-incomplete rather than collapsed

#### Scenario: Equal simple-link observations arrive

- **WHEN** two eligible observations have the same simple logical link identity
  and equal semantic content
- **THEN** they coalesce into one resolved link with joined provenance

#### Scenario: Distinct link violates cardinality

- **WHEN** a distinct logical link identity would exceed an endpoint cardinality
- **THEN** it conflicts without overwriting or merging either identity

#### Scenario: Relationship object loses final existence evidence

- **WHEN** an object-backed relationship receives a final-evidence tombstone
- **THEN** its derived resolved links leave current views while historical roles
  remain queryable

#### Scenario: Host graph disagrees with runtime links

- **WHEN** a graph materialization contains a link absent from current runtime
  `ResolvedLink` state
- **THEN** the graph entry is discarded during rebuild and never treated as
  semantic evidence

### Requirement: Atomic pinned mutation and deterministic replay

The runtime SHALL produce a resolved plan pinned to exact
`RuntimeConfigurationPin` digest, ontology release, mapping
artifact and deployment, source authority, resolution-policy revisions, identity
decisions, expected source cursor, exact idempotency tuple, and input digest. One
transaction MUST verify authorization and every pin, apply observations and
retractions, recompute affected objects and links, advance the cursor, append
audit completion, and record the result. Any stale fence MUST produce no partial
change. Replay MUST use the exact historical artifacts, envelope, resolver
responses, clock values, and opaque scope or report the first changed pin.

#### Scenario: Identity revision changes before commit

- **WHEN** any object or endpoint decision no longer matches the plan pin
- **THEN** no observation, link, projection, cursor, completion, or idempotency
  record changes

#### Scenario: Historical replay lacks an artifact

- **WHEN** the exact mapping or ontology artifact is unavailable
- **THEN** replay reports non-replayable evidence and does not substitute a newer
  artifact

### Requirement: Ordered bitemporal semantic queries

The runtime SHALL define a typed semantic query AST over concrete types,
interfaces, property predicates, projections, and named direct or object-backed
roles. Every query MUST pin exact `RuntimeConfigurationPin` digest,
`valid_at`, `known_at`, page size, cost budget, ordered sort terms, a total
value/null/absent bucket order, and count mode. `valid_at` MUST
select domain validity and `known_at` MUST select evidence and retractions known
at that time. If no sort is supplied, canonical object or link ID ascending MUST
be the complete order; otherwise canonical ID MUST be appended as final tie-
breaker. Default bucket order MUST be value, null, absent. `is_absent` MUST mean
no resolved slot; `is_present` MUST include value or explicit null; `is_null`
MUST mean present null; `is_not_null` MUST mean present non-null value. Equality
to null MUST be invalid.

Orderable scalar comparison MUST be boolean `false < true`; string and URI by
unsigned UTF-8 bytes; i64, fixed decimal, timestamp microseconds, epoch date days,
and duration microseconds by numeric value; bytes by unsigned lexicographic bytes;
enum by stable member-ID UTF-8 bytes; and object reference by stable object-type ID
then object-ID bytes. Lists, sets, records, maps, and unions MUST NOT be orderable.

Pagination MUST use a stable keyset cursor binding query digest,
`RuntimeConfigurationPin` digest, both times, page size, complete order, typed last
tuple, and last canonical ID. A production host MUST seal activation and scope
outside the portable cursor; SQLite MUST use an adapter-local authenticated seal.
Any changed pin MUST invalidate the cursor.
`count=none` MUST return page count only.
`count=exact` MUST return the authorized total for the same bitemporal snapshot
before pagination and charge it to the cost budget. Approximate counts and
aggregates MUST be unsupported in V1. `semantic-query-v1` MUST limit a query to
256 AST nodes, 8 relationship traversals, and page size 1,000. Static admission and execution MUST charge
declared nodes, traversals, page size, exact count, visited objects and links,
candidates, decoded bytes, and output bytes. Budget exhaustion MUST return no
partial page or successor cursor.

#### Scenario: Page through tied sort values

- **WHEN** several results share every requested sort value
- **THEN** the appended canonical ID and bound keyset cursor return each result
  exactly once at the same bitemporal snapshot

#### Scenario: Query current validity with historical knowledge

- **WHEN** `valid_at` is current and `known_at` predates a later correction
- **THEN** results use only evidence known by `known_at` even if newer evidence is
  valid at the same domain time

#### Scenario: Exact count exceeds budget

- **WHEN** computing the exact authorized total would exceed the query budget
- **THEN** the query fails without an approximate count, partial page, or cursor

#### Scenario: Absent and null properties are queried

- **WHEN** one object lacks a resolved slot and another has an explicit null
- **THEN** `is_absent` and `is_null` distinguish them and sorting follows the
  declared value/null/absent bucket order

#### Scenario: Host activation changes between pages

- **WHEN** the host seal or `RuntimeConfigurationPin` digest differs from the
  first page
- **THEN** the cursor is rejected before returning a mixed-configuration page

### Requirement: Mandatory portable host ports

The runtime SHALL define transaction, store, authorization, clock, audit, and
optional external-identity ports using opaque principal and scope values and a
port-capability descriptor. Concrete host activation MUST remain outside these
portable contracts.
Authorization MUST precede protected evidence access, replay, query, or mutation.
Ordinary audit output MUST use redacted metadata and protected evidence handles.
A host MAY reject an unsupported optional capability with a stable code but MUST
NOT silently weaken portable semantics.

#### Scenario: Host denies replay evidence

- **WHEN** the authorization port denies access to protected source evidence
- **THEN** replay stops before retrieval and emits only a redacted denial audit

### Requirement: Production-supported SQLite/WAL adapter

The runtime SHALL ship a production-supported `portable-ontology-sqlite` crate
implementing exact-key identity keyed by `(stable_object_type_id,
identity_key_schema_id, canonical_key_bytes)`, atomic bitemporal object and link storage,
idempotency, source cursors, redacted audit, protected evidence handles, and the
bounded `semantic-query-v1` executor. It MUST enable WAL and foreign keys, use
serialized writes and concurrent readers, and default to `synchronous=FULL`.
External identity MUST be rejected unless a host supplies that separate port.
Multiple key tuples MUST converge only through an explicit persisted association.
Fuzzy identity MUST be unsupported.

SQLite MUST own local configuration and append-only CAS local activation rather
than portable artifacts. A supported local admin CLI MUST verify and import
artifacts, manage configuration and activation, accept preassembled envelopes,
inspect state, run reconciliation, backup, restore, and integrity checks. Durable
reconciliation jobs MUST rebuild after association, release, or deployment
changes and MUST resume idempotently after restart. V1 MUST NOT include source
connectors, a UI, multitenant service, or fuzzy identity.

Forward schema migrations MUST be versioned and transactional and MUST refuse an
unknown or newer schema. Destructive migration MUST require explicit export and
rebuild. Crash tests MUST kill the process at every declared commit boundary and
verify recovery exposes either complete old state or complete new state. Backup,
restore, compaction, integrity check, bounded busy-timeout, CLI, local activation,
and reconciliation restart behavior MUST be
documented and tested. The in-memory adapter MUST remain a conformance reference,
not the durability gate.

#### Scenario: Process dies after WAL commit

- **WHEN** the process is killed at a declared transaction boundary and the same
  file is reopened
- **THEN** recovery returns one atomically complete state and idempotent retry is
  safe

#### Scenario: Store has a newer schema version

- **WHEN** an older runtime opens a database created by an unsupported newer
  migration
- **THEN** it refuses read-write operation without modifying the file

#### Scenario: Two exact keys should identify one object

- **WHEN** two stable key tuples are known to describe one object
- **THEN** they converge only after an explicit association is persisted and
  never through fuzzy or implicit matching

#### Scenario: Local activation is changed through the CLI

- **WHEN** an administrator supplies the expected local activation revision and
  verified artifacts
- **THEN** the CLI appends one CAS activation record without mutating a portable
  mapping deployment

#### Scenario: Reconciliation is interrupted by restart

- **WHEN** the process restarts during a durable projection rebuild
- **THEN** the job resumes idempotently from durable progress and exposes no
  partially current projection

### Requirement: Capability profiles and independent durable portability gate

The runtime SHALL contribute `ontology-runtime-v1`, `semantic-query-v1`, and
`sqlite-store-v1` sections to the core-defined V1 conformance-manifest schema; a
distribution MUST assemble one manifest with `portable-base-v1` and
`ontology-core-v1` and SHALL report passed subsets with exact corpus versions.
Runtime limits MUST be exactly source nesting depth 8,
1,024 fields per source record, 1,024 elements per source list, 1 MiB per
envelope, 256 emission templates per mapping, 256 expression nodes per template,
1,024 iterations, 1,024 observations and retractions per record, and 4 MiB per
plan. Query limits MUST be exactly 256 AST nodes, 8 relationship traversals, and
page size 1,000. The corpus MUST cover neutral reference, security-operations,
and textile-certification domains, source records and unions, object lifecycle,
both link forms, all resolution policies, association revisions, bitemporal queries,
replay, migrations, CLI, reconciliation, and restart recovery. Runtime code MUST
NOT branch on fixture, provider, namespace, or domain names.

A standalone V1 runtime distribution MUST pass the SQLite profiles and applicable
public corpus, migration, CLI, reconciliation, and restart tests. General cross-
host portability GA MUST additionally require an independently maintained,
production-supported, non-SQLite adapter using only public contracts. A
A first-party product adapter MUST NOT satisfy that independent gate. Neither gate MUST
block accurate component-profile reporting.

#### Scenario: In-memory corpus passes but SQLite recovery fails

- **WHEN** all pure and in-memory vectors pass but any durable migration or crash
  vector fails
- **THEN** component profiles MAY be reported accurately but standalone V1 and
  cross-host portability GA are blocked

#### Scenario: Unrelated domains use identical runtime code

- **WHEN** all three domain suites run through in-memory and SQLite adapters
- **THEN** only artifacts and fixture inputs vary while runtime behavior and
  binaries remain unchanged

#### Scenario: SQLite passes without a non-SQLite adapter

- **WHEN** all standalone SQLite profiles pass but no independently maintained
  production non-SQLite adapter has passed public contracts
- **THEN** standalone V1 MAY be claimed while cross-host portability GA remains
  blocked
