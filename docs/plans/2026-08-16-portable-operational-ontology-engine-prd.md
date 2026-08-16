# Product Requirements Document: Portable Operational Ontology Engine

**Version:** 0.1
**Date:** 2026-08-16
**Status:** Proposed
**Audience:** Platform, data, integration, security, product, and operations teams

## Tracking and Working Artifacts

- Feature branch: [`codex/add-portable-ontology-engine`](https://code.carverauto.dev/carverauto/serviceradar/src/branch/codex/add-portable-ontology-engine)
- Local worktree: `/private/tmp/serviceradar-wt-portable-ontology-engine`
- Tracking issue: [#5004](https://code.carverauto.dev/carverauto/serviceradar/issues/5004)
- Architecture decision record: [standalone ADR review #5006](https://code.carverauto.dev/carverauto/serviceradar/pulls/5006) ([source](https://code.carverauto.dev/carverauto/serviceradar/src/branch/codex/add-portable-ontology-adr/docs/learnings/adr/2026-08-16-portable-operational-ontology-engine.md))
- PRD source: [this document](https://code.carverauto.dev/carverauto/serviceradar/src/branch/codex/add-portable-ontology-engine/docs/plans/2026-08-16-portable-operational-ontology-engine-prd.md)
- Portable schema/model/compiler proposal: [`add-portable-ontology-core`](https://code.carverauto.dev/carverauto/serviceradar/src/branch/codex/add-portable-ontology-engine/openspec/changes/add-portable-ontology-core)
- Portable runtime proposal: [`add-portable-ontology-runtime`](https://code.carverauto.dev/carverauto/serviceradar/src/branch/codex/add-portable-ontology-engine/openspec/changes/add-portable-ontology-runtime)
- Optional ServiceRadar adapter proposal: [`add-serviceradar-ontology-adapter`](https://code.carverauto.dev/carverauto/serviceradar/src/branch/codex/add-portable-ontology-engine/openspec/changes/add-serviceradar-ontology-adapter)

The changes are independently reviewable and intentionally ordered:
`add-portable-ontology-core` -> `add-portable-ontology-runtime` ->
`add-serviceradar-ontology-adapter`. The first two define a domain-neutral
product. The third proves one host integration without making ServiceRadar a
dependency of the portable crates or contracts.

## 1. Executive Decision

Build a portable operational ontology engine: a versioned semantic layer that
turns heterogeneous source records into typed objects, properties, links, and
provenance that applications can query and operate on consistently.

This is an ontology system, not merely a metadata normalizer. Its primary model
contains object types, property definitions, relationship/link types,
interfaces, source contracts, source-backed mappings, provenance, ontology
versions, and semantic query contracts. It lets a platform define what concepts
mean, connect data from different systems to those concepts, evolve that model
safely, and inspect exactly why each object property or link exists.

The product has three layers:

1. A pure Rust ontology core defines and compiles only the semantic model:
   ontology modules/releases, value and property types, object types, interfaces,
   identity-key schemas, link types, compatibility, and canonical codecs.
2. A portable runtime owns source schemas/contracts, the mapping language and
   compiler/evaluator, candidates, observations, resolution, semantic query, and
   explicit storage, identity, authorization, audit, and materialization ports.
   It ships in-memory conformance support and the SQLite/WAL standalone adapter.
3. Optional host adapters own concrete deployment configuration, activation,
   credentials, ingestion, and product integration. The first planned adapter
   targets ServiceRadar. A textile, manufacturing, ERP, SIEM, or other product can
   supply different adapters without modifying or forking either portable layer.

The semantic core and generic runtime contain no ServiceRadar imports, database
clients, product vocabulary, provider branches, or assumptions about OCSF, DIRE,
AGE, SRQL, Ash, NATS, Phoenix, ERP, or textile workflows. Database clients occur
only in portable adapter implementations such as SQLite or in host-specific code;
product names may appear only in adapter data and host-specific code.

V1 is platform-authored, deterministic, and bounded. It is exclusively the
semantic layer: source-backed objects, properties, links, provenance, ontology
versions, and semantic query. Action types, policies, action plans, functions,
workflows, state machines, generated applications, and effect execution are
separate future capabilities.

## 2. Product Definition

An operational ontology combines a semantic catalog with live, source-backed
state:

- The catalog says which object types, properties, interfaces, and link types
  exist and how they may evolve.
- Source contracts describe bounded records without embedding transport or
  vendor behavior in the engine.
- Mapping packs explain how source fields propose object identity evidence,
  property observations, and link observations.
- Runtime objects and links retain their complete source and mapping provenance.
- An activated ontology release gives all reads and writes one coherent semantic
  version.
- A semantic query contract lets host adapters expose the model through their
  native query and catalog surfaces.

"Object" is the normative runtime term. "Entity" is a conversational synonym.
An object is an instance of an `ObjectType`; it is not automatically a row, table,
graph vertex, OCSF device, or provider record. Physical representation belongs to
the host adapter.

Operational means the model is bound to current source evidence, can be queried
with provenance, and evolves under explicit activation and migration rules. It
does not imply a V1 kinetic layer.

### 2.1 Official Palantir Reference Model, Not a Compatibility Target

Palantir's official documentation is a useful reference for the product category:
its [Ontology overview](https://www.palantir.com/docs/foundry/ontology/overview)
describes an operational layer over integrated data; its documentation separates
[object properties](https://www.palantir.com/docs/foundry/object-link-types/properties-overview),
[link types](https://www.palantir.com/docs/foundry/object-link-types/link-types-overview),
and reusable [interfaces](https://www.palantir.com/docs/foundry/interfaces/interface-overview).
Those concepts motivate the focus on source-backed objects, properties, links,
interfaces, and operational query rather than a catalog-only schema.

This project does not claim Palantir API, storage, behavior, package, query,
security, or artifact compatibility; does not copy proprietary implementation;
and does not promise import/export or migration interoperability. Portable V1 is
an independently specified semantic subset. Kinetic concepts described by the
reference model remain outside V1 and require later proposals.

## 3. Problem and Opportunity

Platforms repeatedly solve the same integration problem in product-specific
code:

1. Each source uses different names, encodings, identifiers, and relationship
   shapes for similar real-world concepts.
2. Source payload fields are easily confused with governed product truth.
3. Adding a source or concept often requires changes across ingestion, storage,
   APIs, search, UI, authorization, and provenance.
4. Schema changes are hard to simulate, activate coherently, roll back, or replay.
5. Identity and relationship decisions are frequently embedded in mappers even
   though the host platform already has an authority for them.
6. Analysts cannot reliably answer which definition, source record, mapping,
   identity decision, resolution binding, and ontology version produced a value
   or link.

A portable operational ontology addresses that repetition once. Host products can
reuse a stable type system, compiler, mapping semantics, version model,
provenance envelope, query model, and conformance tests while retaining their own
storage, identity, security, ingestion, UI, and action authorities.

For ServiceRadar, the opportunity spans SIEM, security analytics, asset
intelligence, and IT operations management. For another host, the same engine
could model machines, material lots, work orders, suppliers, documents, or any
other domain without importing ServiceRadar concepts into the core.

## 4. Goals

- Define and evolve typed object types, properties, interfaces, and link types in
  immutable, versioned ontology releases.
- Onboard a new source by registering a bounded source contract and declarative
  mapping pack instead of adding source-specific branches to the engine.
- Map source records into typed `ObjectCandidate` values, unresolved link
  proposals, and owned retraction proposals with complete provenance.
- Preserve host ownership of storage, identity resolution, authorization, query
  execution, indexing, UI, ingestion, and side effects through explicit ports.
- Make the portable runtime authoritative for semantic resolved-object and
  resolved-link lifecycle while treating host stores and graphs as port
  implementations or revisioned materializations.
- Make ontology publication, compatibility analysis, activation, shadow
  evaluation, rollback, and recomputation observable and repeatable.
- Expose one portable semantic catalog and query model that host adapters can
  translate into their native APIs and query languages.
- Guarantee deterministic compilation and evaluation across supported
  architectures for identical source, ontology, mapping, and context bytes.
- Ship an in-memory reference adapter and conformance kit so portability is a
  tested property rather than an architectural claim.
- Ship a durable SQLite/WAL adapter with exact-key identity and bounded bitemporal
  query so the portable engine is usable without a product host.
- Prove the design with multiple unrelated source classes and at least two domain
  vocabularies, without giving any one source privileged engine behavior.

## 5. Non-Goals

V1 will not:

- Generate arbitrary database tables, migrations, REST/GraphQL/OData endpoints,
  forms, dashboards, or complete applications from an ontology.
- Define or execute an action, policy, workflow, state machine, notification,
  approval, remediation, provider callback, or arbitrary user code.
- Provide a rules, authorization-policy, risk, anomaly, causal, or statistical
  engine.
- Replace a host's identity resolver, authorization system, source ingestion
  pipeline, physical graph store, query engine, or storage engine. The portable
  runtime nevertheless remains the sole authority for its semantic
  `ResolvedObject` and `ResolvedLink` projections.
- Require one database, graph, queue, web framework, language binding, or
  deployment model.
- Infer identity or resolved relationships from names, addresses, or provider
  strings without a host identity decision and portable link-resolution rules.
- Treat source payloads as authorization, tenancy, routing, schema, or object-ID
  selectors.
- Permit tenant-authored schemas, custom functions, unsigned package import, or
  unbounded expressions in V1.
- Reinterpret old evidence silently when an ontology or mapping version changes.

## 6. Users and Jobs to Be Done

| User | Job |
| --- | --- |
| Ontology modeler | Define reusable object types, interfaces, properties, links, constraints, labels, and lifecycle rules. |
| Integration engineer | Register a source contract, author mappings, run fixtures and shadow comparisons, and inspect conflicts or missing data. |
| Adapter implementer | Bind runtime ports to a product's storage, identity, authorization, query, audit, and materialization systems and pass conformance tests. |
| Platform administrator | Review, publish, activate, roll back, and monitor ontology releases and mapping versions. |
| Analyst or operator | Discover the semantic catalog, query objects and links, inspect freshness, and trace results to exact source evidence. |
| Security reviewer | Verify isolation, capability bounds, provenance, taint propagation, redaction, package integrity, and adapter authority boundaries. |
| Application developer | Build later domain capabilities against stable ontology contracts without coupling them to source payload shapes. |

## 7. Product Principles

1. **The ontology is operational.** Types are connected to live, versioned,
   provenance-bearing objects and links, not stored as documentation only.
2. **The core is domain-neutral.** Product names and source-specific logic are
   data or adapter concerns, never Rust branches or imports in portable crates.
3. **Definitions and evidence are separate.** A definition says what a property
   means; an observation says what one source reported under one mapping version.
4. **Identity is a port, not a mapper trick.** Mappings emit bounded
   `ObjectCandidate` values with typed identity-key components and no runtime ID.
   The configured host authority decides canonical association before an
   observation can be admitted.
5. **Links are evidence before resolution.** A source-backed link observation does
   not become a semantic `ResolvedLink` until the portable runtime resolves both
   endpoints, source policy, cardinality, and identity revisions. Host graphs only
   materialize that result.
6. **Every operation pins a version.** Compile, map, resolve, query, replay, and
   migration records name the exact ontology release, `RuntimeConfigurationPin`
   digest, and opaque host-configuration revision.
7. **Evolution is explicit.** Breaking changes require a new immutable version,
   impact analysis, activation, and bounded reprojection or migration.
8. **Missing is not false.** Missing, null, stale, denied, unavailable, invalid,
   retracted, and unresolved are distinct typed states.
9. **Provenance is first-class.** Values and links retain source, mapping,
   identity, resolution-binding, version, time, and transformation lineage.
10. **Ports carry authority.** The host authenticates, authorizes, scopes, and
    persists; source data cannot choose those capabilities.
11. **Kinetics are separate.** Actions, policies, functions, and workflows may
    consume the ontology only through later independently approved modules.
12. **Bounds are part of compatibility.** Limit profiles are immutable inputs to
    compilation, evaluation, replay, and adapter conformance.

## 8. Portable Architecture

```text
Ontology modules ----> semantic core compiler ----> OntologyRelease
                                                       |
Source contracts + mappings --> runtime compiler ------+
                                                       v
                             portable ontology runtime
                               |       |       |
                               v       v       v
                          identity   storage   query/audit/materialization ports
                               |       |       |
                               +-------+-------+
                                       |
                                       v
                         host adapters and applications
```

### 8.1 Portable Ontology Core

The core is an ordinary Rust library that owns:

- `OntologyModule`, `OntologyRelease`, `ValueType`, `PropertyDefinition`,
  `ObjectType`, `Interface`, identity-key schema, and `LinkType` definitions;
- direct/object-backed relationship shape, edge identity, role, cardinality, and
  discriminator validation;
- type checking, constraint checking, interface satisfaction, link endpoint
  validation, dependency analysis, and compatibility classification;
- deterministic compilation into immutable semantic releases;
- the exact canonical JSON/CBOR codecs and content hashing contract; and
- golden, property, fuzz, malformed-input, and cross-architecture test vectors.

The core does not define or import `SourceSchema`, `SourceContract`, mapping
syntax, `MappingArtifact`, `MappingDeployment`, `SourceAuthority`, resolution
algorithms/bindings, source evaluation, runtime observations, or query execution.
Those are runtime concerns and may reference core semantic artifacts only through
their public versioned contracts.

It has no filesystem, network, database, system clock, random source, message bus,
HTTP, UI, authorization, Rustler, or product-module dependency. It contains no
handwritten unsafe code. Adapters communicate with it only through versioned
request/result types.

### 8.2 Canonical Contract and Hashing

Portable V1 has one logical data model and two normative encodings:

- Canonical JSON follows RFC 8785/JCS member ordering, string escaping, and
  whitespace rules. Boolean, null, and string values use ordinary JSON forms.
  Portable signed integers use `{"$i64":"<integer-text>"}`, timestamps use
  `{"$timestamp_us":"<integer-text>"}`, durations use
  `{"$duration_us":"<integer-text>"}`, calendar dates use
  `{"$date_days":"<integer-text>"}`, bytes use
  `{"$bytes_b64u":"<unpadded-base64url>"}`, and decimals use
  `{"$decimal":{"coefficient":"<integer-text>","scale":<0..18>}}`. Bare JSON
  numbers are allowed only for schema-fixed structural counters, tags, and
  versions whose full range is within `0..2^53-1`; they are never portable
  property integers or decimals.
- Deterministic CBOR follows RFC 8949 deterministic encoding with definite
  lengths, shortest integer forms, and encoded-key ordering. Signed integers,
  timestamps, durations, and dates use native CBOR integers and are distinguished
  by the enclosing schema; bytes use a CBOR byte string. A decimal uses
  decimal-fraction tag 4 with the exact array
  `[-scale, coefficient]`; the coefficient uses a native integer when
  representable and otherwise bignum tag 2/3 with the shortest big-endian
  magnitude and no leading zero octet.

The two encodings must decode to the same typed logical value. The normative
logical SHA-256 input is the exact deterministic-CBOR encoding of the array
`["portable-ontology-v1", contract_kind, contract_version, payload]`.
`contract_kind` matches `[a-z][a-z0-9._-]{0,63}`, `contract_version` is an
unsigned 32-bit integer, and `payload` is the typed contract value. There is no
additional prefix, delimiter, or platform framing. Canonical JSON and CBOR golden
vectors therefore name the same logical hash even though their wire bytes differ.
Artifact records also retain and verify each wire encoding's own byte hash.

Portable V1 applies no implicit Unicode normalization, case folding, trimming, or
locale conversion. Strings are compared by their exact Unicode scalar sequence
and encoded UTF-8 bytes. A schema may request an explicit versioned transform,
which changes the logical value and provenance.

Binary floating-point values are forbidden. Signed integers are exact signed
64-bit values. A decimal is the pair `(coefficient, scale)`, where coefficient is
a signed 128-bit integer and scale is `0..18`; canonicalization removes trailing
decimal zeroes while scale is positive, and canonical zero is `(0, 0)`. JSON uses
the tagged decimal envelope above rather than a JSON number. Canonical integer
text is base-10 ASCII with no plus sign or leading zeroes; zero is exactly `0` and
negative zero is rejected. CBOR uses the exact tag-4 representation above.

A timestamp is a signed 64-bit count of UTC microseconds from the Unix epoch.
RFC 3339 input offsets are converted exactly to UTC; more than six fractional
digits, leap-second spelling, timezone-less values, and overflow are rejected
rather than rounded. Timestamp ordering is signed integer ordering. Durations use
signed microseconds and are never interpreted as calendar months.

A calendar date is a signed 32-bit count of days from `1970-01-01`. URI values are
validated UTF-8 strings and enum values are canonical stable member-ID strings;
neither receives implicit normalization. An object-ref is JSON
`{"$object_ref":{"object_id":"<unpadded-base64url>","object_type_id":"<stable-id>"}}`
and the CBOR array `[stable_object_type_id, object_id_bytes]`. Lists use arrays in
declared order. Sets also use arrays but must be deduplicated and sorted by each
element's deterministic-CBOR bytes before either wire encoding is produced.

Definition, artifact, configuration, request, decision, trace, cursor, and replay
envelopes are closed: an unknown or duplicate field is rejected. Source records
are also closed by default; a source contract may declare one bounded extension
map whose unknown keys are preserved as opaque evidence but are inaccessible to a
mapping until a later source-contract version declares them. Golden vectors cover
JSON/CBOR logical equivalence, map ordering, minimum and maximum i64/i128 values,
native/bignum boundaries, decimal normalization, negative-zero rejection, Unicode
non-normalization, timestamp offsets and precision, dates, bytes/base64url, URI,
enum, object-ref, list/set ordering, unknown fields, and the exact
domain-separated hash envelope on every supported architecture.

### 8.3 Portable Ontology Runtime

The runtime owns source-neutral orchestration:

- `SourceSchema` and `SourceContract` definitions;
- the bounded mapping language, compiler, evaluator, `MappingArtifact`, and
  `MappingDeployment` lifecycle;
- version-pinned source admission, `ObjectCandidate`, identity requests, accepted
  object/property/link observations, idempotency, and explicit retractions;
- source-authority definitions, property/link resolution bindings and algorithms,
  resolved-object/link lifecycle, replay, and migration planning;
- validation and canonical hashing of host-supplied `RuntimeConfigurationPin`
  requests containing an exact release, deployment set, resolution bindings,
  opaque host-configuration revision, and port-capability digest;
- stale host-fence rejection, replay, and reconciliation, without owning
  activation, rollout mode, promotion, or rollback state;
- semantic catalog and query intermediate representations; and
- provenance, taint, audit-event, and redaction contracts.

The runtime calls explicit traits for persistence, unit-of-work commits, identity,
authorization context, source access, query execution, link materialization,
clock/time authority, audit, and job delivery. It never discovers or imports a
host implementation. A host supplies an opaque host-configuration revision and a
portable port-capability descriptor with each request. The runtime may compare and
echo that opaque revision but cannot decode it into a `BindingManifest`,
`HostActivation`, tenant, credential, database, or product concept.

### 8.4 In-Memory Reference Adapter

The runtime ships an in-memory reference adapter with deterministic exact-key
identity, adapter-local test configuration, bounded query execution, and no
external I/O. It is for conformance, fixtures, examples, and embedding tests, not
production durability or portable activation.

### 8.5 Durable Standalone SQLite/WAL Baseline

Portable V1 also ships a durable `SqliteWalAdapter` as the usable standalone
baseline. It is a library adapter plus local administration CLI, not a remote
service. It provides versioned migrations, SQLite WAL mode, transactional catalog,
a separate SQLite-owned `LocalActivation`, source requests, append-only
object/property/link evidence and retractions, resolved projections, provenance,
replay metadata, durable reconciliation jobs, and restart recovery.

Its identity implementation is exact-key only. The tuple
`(stable_object_type_id, identity_key_schema_id, canonical_key_bytes)` maps to one
stable object ID and monotonically increasing association revision. A new object
type version that retains those stable IDs therefore retains object identity.
Different keys converge only through an explicit association; SQLite performs no
fuzzy matching, cross-key inference, automatic merge, or heuristic split. Its
mandatory bounded semantic-query executor implements deterministic ordering,
keyset pagination, bitemporal filters, exact count, and link traversal.

The SQLite adapter makes the engine useful without ServiceRadar, but it is not a
turnkey application platform: it ships no connectors, multitenant control plane,
distributed workers, fuzzy identity/MDM, UI, authorization product, or graph
service. Scalable hosts implement the portable ports in-process or as their own
adapter libraries; they do not call SQLite as a remote ontology sidecar.

### 8.6 Conformance Levels and Capability Profiles

V1 defines exactly five versioned conformance profiles:

- `portable-base-v1`: canonical contracts, hashes, closed envelopes, diagnostics,
  bounds-manifest integrity, and hostile-input behavior shared by every component;
- `ontology-core-v1`: the semantic-only model, compiler, release compatibility,
  identity-key schemas, links/relationships, and canonical semantic values;
- `ontology-runtime-v1`: source contracts, mappings, identity phases,
  observations, resolution, lifecycle, bitemporal reads, replay, ports,
  configuration fencing, and recovery;
- `semantic-query-v1`: the bounded query IR, exact ordering, keyset cursors,
  traversal, `count = none | exact`, authorization/snapshot rules, and costs; and
- `sqlite-store-v1`: durable SQLite/WAL persistence, local configuration,
  exact-key identity, jobs, reconciliation, query execution, and restart recovery.

Unsupported capabilities fail explicitly; no component silently approximates a
profile requirement. The standalone V1 release requires the SQLite distribution
to pass every applicable profile: all five for the complete distribution. A
general or cross-host portability GA claim additionally requires an independently
maintained non-SQLite production adapter, implemented only through public portable
contracts, to pass `portable-base-v1`, `ontology-core-v1`,
`ontology-runtime-v1`, `semantic-query-v1`, and every capability it exposes.
The ServiceRadar adapter is a first-party integration proof and does not count as
that independent adapter.

The core proposal owns the conformance-manifest schema and contributes only the
`portable-base-v1` and `ontology-core-v1` sections. The runtime proposal
contributes the `ontology-runtime-v1`, `semantic-query-v1`, and `sqlite-store-v1`
sections. The runtime distribution assembles and verifies one manifest and owns
the standalone and cross-host GA gates above; neither proposal maintains a second
copy of profile IDs or ceilings.

### 8.7 Adapter Conformance Kit

Every production adapter must pass its applicable named profiles for:

- exact artifact and ontology-version pinning;
- idempotent source-record admission and output commits;
- atomic or equivalently all-or-nothing visible decisions and evidence;
- source coordinate, identity association revision, `RuntimeConfigurationPin`
  digest, opaque host configuration, and projection fencing;
- explicit retraction, expiry, rollback, and recomputation behavior;
- bitemporal `valid_at`/`known_at` reads and provenance reconstruction;
- authorization-context non-forgeability and redaction;
- crash, duplicate, reordering, timeout, and adapter-restart recovery; and
- bounded query, fan-out, memory, and concurrency rejection.

An adapter cannot claim compatibility by compiling alone or by passing only the
in-memory fixture suite. Profile IDs, ceilings, fixtures, and expected diagnostics
are generated from one versioned conformance manifest; handwritten copies that
can drift are not accepted as profile evidence.

## 9. Semantic and Runtime Model

### 9.1 Ontology Module and Release

An `OntologyModule` is a namespaced, versioned set of semantic definitions. An
`OntologyRelease` is an immutable semantic-only dependency closure: exact module,
value type, property, object type, interface, identity-key schema, and link type
versions plus the `ontology-core-v1` manifest version. It contains no
`SourceSchema`, `SourceContract`, mapping, source authority, resolution algorithm
or binding, deployment, storage binding, adapter capability, tenant, or host
activation state.

Drafts are editable and published releases are immutable. Each mapping artifact
pins exactly one ontology release digest but remains a separate runtime artifact.
A host constructs a closed `RuntimeConfigurationPin` request from an exact release,
exact deployment set, exact resolution bindings, opaque host-configuration
revision, and port-capability digest. No portable request resolves a floating
"latest" dependency. Any activation that selects or rolls back such a pin remains
host-adapter state.

### 9.2 Object Type

An `ObjectType` declares:

- a stable namespaced ID, immutable version, and human-facing labels;
- implemented interfaces;
- allowed properties and link roles;
- at least one versioned identity-key schema, each with an authority URI, ordered
  typed `ValueType` components, and an explicit versioned comparison-normalization
  transform;
- exactly one title-property reference whose target is a scalar UTF-8 string
  `PropertyDefinition`;
- lifecycle, temporal, sensitivity, and retention requirements;
- semantic annotations and query/index hints.

An object type describes meaning. It does not prescribe a table, class, OCSF
record, graph label, or UI component. A source-eligibility rule, resolver choice,
or host binding is runtime or host state and is never serialized into the object
type or `OntologyRelease`. Identity-key comparison applies only the declared
versioned transform; Unicode normalization, case folding, trimming, URI rewriting,
and locale behavior are never implicit.

### 9.3 Object Candidate, Observation, and Resolved Object

An `ObjectCandidate` is a pure, bounded mapping-evaluation output. It contains an
exact object-type version, an identity-key schema ID and typed key components,
an existence proposal, zero or more typed property proposals, source/output
lineage, and diagnostics. It contains no canonical runtime object ID and no
identity association revision. A mapping cannot emit an `ObjectObservation`,
`PropertyObservation`, or `ResolvedObject` directly.

The runtime submits the candidate's typed key to the identity port. Stable object
identity is keyed by `(stable_object_type_id, identity_key_schema_id,
canonical_key_bytes)`, never by object-type version. Different object-type
versions that retain those stable IDs can therefore address the same object.
Multiple identity keys converge on one object only when the identity port returns
an explicit association; neither the mapper nor an adapter may infer convergence
from similar values.

The identity result is `accepted(canonical_object_id, association_revision)`,
`ambiguous`, or `rejected`. Only `accepted` proceeds to atomic admission. That
commit creates an immutable `ObjectObservation` pinned to the canonical object ID,
association revision, exact object-type version and ontology release, source
authority, source coordinate, mapping deployment/output binding, valid-time
interval, `known_at`, classification, and content hash; it also admits the
candidate's property proposals or admits none of them. An ambiguous or rejected
candidate may persist only a value-free diagnostic and an authorized protected
decision record. It never creates an observation, object, property, or current
projection.

A retraction is a separate immutable record that references the exact owned
observation and its valid-time and known-time boundary; it never mutates or
masquerades as the observation.

The portable runtime is the semantic authority for `ResolvedObject`. A resolved
object records a stable runtime object ID, exact object-type version and ontology
release, current identity association revision, all eligible existence
contributors, current property projections, lifecycle state, projection
generation, and next eligibility transition. It is created only after the
identity port returns an accepted association and at least one eligible existence
observation commits.

The V1 lifecycle is explicit and append-only:

- no resolved object exists while identity is rejected or ambiguous, or while no
  eligible existence evidence exists;
- atomic admission of the first eligible `ObjectObservation` creates an `active`
  resolved object;
- an `active` object remains active while at least one eligible contribution
  remains;
- loss of the final contribution transitions it to `tombstoned`;
- an identity merge transitions the losing object to `merged_into(survivor_id)`;
  and
- a tombstoned object returns to `active` only through the explicit continuing
  association rule below.

There is no in-place deletion, state inference from a missing row, or reuse of a
runtime object ID.

Existence is multi-source and ownership-scoped. Each source authority and mapping
binding owns only its own object observations. Retracting one contributor cannot
remove an object still supported by another eligible contributor or a host-owned
assertion admitted through a registered source authority and output binding.
When the final eligible existence observation is retracted or expires, the
runtime appends the transition evidence, marks the resolved object
`tombstoned`, and makes its current properties and incident resolved links
ineligible. It retains the object ID, type, provenance, and history under the
configured retention policy; it does not hard-delete or reuse the ID. Later
evidence may revive the same ID only when the identity authority explicitly
returns the continuing association.

Identity merge and split results are append-only association revisions. A merge
makes the losing object non-current and re-resolves its eligible observations and
links onto the survivor without rewriting source evidence. A split reassigns an
observation only when the identity authority supplies one unique result; ambiguous
evidence becomes unresolved rather than being cloned. Any request pinned to an
older association revision is stale, cannot change a projection, and triggers
bounded object, property, and link reconciliation.

### 9.4 Interface

An `Interface` is a reusable semantic contract that object types can implement.
It may require typed properties, link roles, identity capabilities, and semantic
annotations. A link endpoint or query may target an interface rather than a
concrete object type.

V1 interfaces contain no executable methods. Interface inheritance must be
acyclic, and conflicting inherited property or link requirements fail
compilation rather than using implicit precedence.

### 9.5 Property Definition

A `PropertyDefinition` has a stable ID and immutable versions defining:

- value type, cardinality, nullability, and collection ordering;
- units, enumeration vocabulary, validation constraints, and normalization;
- freshness, valid-time, and retention semantics;
- classification and provenance requirements;
- query/index capabilities; and
- compatibility classification for later versions.

Core V1 semantic values are nullable property slots over boolean, UTF-8 string,
signed i64, fixed decimal, UTC timestamp, calendar date, duration, bytes, URI,
enumeration, object-ref, and bounded homogeneous list or set types. A list
preserves order; a set deduplicates and sorts by canonical element bytes. Binary
floats, NaN, infinity, mixed collections, and unbounded values are rejected.
Strings and URIs receive no implicit Unicode, case, percent-encoding, or URI
normalization; any normalization is an explicit versioned runtime transform.

Semantic maps, records, and unions do not exist in V1. Bounded records, nested
records, homogeneous lists, and closed tagged unions are source-schema types only
and must map into declared semantic values. Nullability belongs to the property
slot rather than creating an untyped universal null value.

An object-ref property is an opaque typed reference for display or external
interchange. It is never traversable and cannot substitute for a `LinkType`. Any
semantic relationship that queries may traverse must use link observations and
the resolved-link lifecycle.

Properties are source-backed or system-asserted through an authorized adapter.
General computed properties and arbitrary functions are future modules.

A `PropertyObservation` is append-only and records the resolved object and
association revision, exact property/type/release, canonical value or explicit
null, source authority and mapping ownership, source-coordinate hash, valid-time
interval, `known_at`, classification, optional confidence, and content hash. Its
retraction is a separate immutable owned record with explicit valid-time and
known-time boundaries. Confidence is an integer in parts per million from
`0..1_000_000`; its authority and admissibility are declared by the source
contract and binding, never inferred from payload truthiness or represented as a
float.

### 9.6 Link Type and Resolved Link

A core `LinkType` declares a stable ID and version, named roles and their object
types or interfaces, cardinality per role, temporal validity, direct or
object-backed representation, `simple` or multiedge identity, a typed
discriminator schema for multiedges, compatible runtime resolution-policy kinds,
classification, and materialization hints. The `RuntimeConfigurationPin`
supplies the exact source-authority resolution binding; no authority or binding is
part of the core `LinkType` or `OntologyRelease`.

A direct relationship has no independent domain identity or properties. Its
release-stable logical identity is `(link_type_version_id,
ordered_role_object_pairs, discriminator)`. Each pair is the stable role ID and
canonical runtime object ID, in LinkType role-declaration order rather than query
direction. The release digest is excluded and retained only in projection and
provenance pins. A `simple` link has no discriminator; equal eligible observations
for the same simple logical identity coalesce with joined provenance. A multiedge
requires a value conforming to its typed, stable
discriminator schema; missing or non-canonical discriminators fail mapping.
Different link-type versions or discriminator values are distinct identities.

Multiple authorities may contribute observations to the same logical link. Each
contributor owns only its evidence. Retraction or expiry of one observation leaves
the resolved link current while another eligible contributor remains; loss of the
final contributor tombstones the resolved link and retains its identity and
history. A later observation may revive that identity only with the same resolved
endpoints, type version, and discriminator under current association revisions.

An object-backed relationship is used when the relationship needs its own domain
identity, properties, source lifecycle, or links. Its core definition names a
relationship object type and at least two participant roles. The mapping emits an
`ObjectCandidate` for that relationship object plus unresolved link proposals for
all required participant roles; accepted identity results later admit the object
and role links. V1 does not attach arbitrary properties to a direct link or encode
an object-backed relationship as a JSON property.

A mapping emits a bounded link proposal with typed unresolved identity-key
references for every role; it never supplies runtime object IDs. Only after every
identity request is accepted does atomic admission create a `LinkObservation`
pinned to the canonical object IDs and association revisions. The portable runtime
alone then creates and owns the semantic `ResolvedLink` projection. A host graph,
search index, or adjacency table is only a versioned materialization/cache of
runtime-resolved links and cannot accept a different semantic link as current.
An ambiguous or rejected role remains only in diagnostics/protected decision
evidence and creates no `LinkObservation`.

Each `LinkObservation` records the exact link-type version and ontology release,
ordered role/object pairs and association revisions, any typed discriminator,
source authority, mapping deployment/output binding, source-coordinate hash,
valid-time interval, `known_at`, classification, optional confidence, and content
hash. Its retraction is a separate owned record with an explicit valid-time and
known-time boundary. Resolving it never changes its source evidence bytes.

Cardinality is checked after role resolution. If multiple distinct eligible links
violate a `one` role, the runtime retains all evidence, records a typed
cardinality conflict, and exposes no winner for that constrained relationship;
there is no implicit last-writer-wins. Link source resolution may remove
ineligible evidence first but cannot weaken declared cardinality.

An unresolved link proposal creates no observation or resolved link. An admitted
`ResolvedLink` is `current` only while role association revisions, source
resolution, and cardinality all succeed; a later cardinality violation makes every
competing candidate `conflicted` and non-traversable. Loss of final evidence makes
it `tombstoned`. These are runtime projection states backed by append-only
transitions, never mutations of the observations.

Endpoint tombstone, merge, split, or association-revision change invalidates the
resolved link immediately. Merge re-keys eligible evidence to the survivor and
coalesces equal observations for the same `simple` logical identity. Split
reassigns an endpoint only with one unique
identity-authority assignment; otherwise the link becomes unresolved. Every
transition is append-only and schedules bounded link and materialization repair.

### 9.7 Source Contract

A versioned runtime `SourceContract` declares a stable source class and immutably
pins exactly one `SourceSchema` version and hash. It also declares record and field
IDs, types, bounds, identity fields, reset/revision semantics, event or snapshot
mode, completeness/absence semantics, classification, and allowed semantic
targets. V1 source schemas support bounded nested records, bounded homogeneous
lists, and closed tagged unions with one declared discriminator and bounded
variant records. Recursive types, heterogeneous lists, untagged unions, and
unbounded extension objects are rejected. These source-only shapes are not core
`ValueType` values. The same contract may be fed by a file, API, queue, database
view, plugin, or test fixture through an adapter.

Source payloads never supply host scope, tenant, database, schema, authorization,
mapping artifact, ontology release, or canonical object identifiers.

### 9.8 Mapping Artifact and Deployment

A mapping source is reviewed declarative runtime input. The runtime mapping
compiler produces an immutable `MappingArtifact` that pins exactly one
`SourceContract` version and its exact `SourceSchema` version/hash, exactly one
`OntologyRelease` digest, output definitions, allowlisted transform versions, the
`ontology-runtime-v1` limits-manifest version, canonical bytes, and build
provenance. Compatible ranges and floating semantic or source versions are
forbidden. It maps one bounded source envelope into:

- `ObjectCandidate` values containing typed identity keys and existence/property
  proposals;
- typed link proposals containing unresolved role/object key references;
- explicit absence and invalid or unresolved outcomes, plus owned expiry and
  retraction proposals; and
- stable diagnostics and provenance nodes.

An unresolved identity-key reference contains the target object-type version,
stable object-type ID, identity-key schema ID, ordered typed key components,
source authority, and source-coordinate hash. It contains no runtime object ID or
association revision and is resolved only by the identity port after pure mapping
evaluation.

Mappings use only declared paths and allowlisted pure transforms. V1 forbids
loops, recursion, dynamic code, arbitrary callbacks, network or storage access,
wall-clock reads, randomness, unbounded regular expressions, and effect calls.
Neither portable layer branches on a source name.

Cross-record correlation is not a hidden mapping feature. A mapping may correlate
only records already assembled into one bounded envelope under a declared source
schema, or consume an explicit relationship record whose endpoint keys are in
that record. It cannot query the object store, scan prior records, or fetch a
missing endpoint during evaluation.

A `MappingDeployment` is immutable portable runtime data that pins exactly one
mapping artifact, one `SourceAuthority` revision, one `source_binding_slot`, one
output-ownership namespace, quotas, and downward-only limits. It contains no
concrete source instance, resolution binding, generation, activation, or
`shadow`/`enforce`/`disabled` mode. The host resolves `source_binding_slot` to an
authorized source instance when it constructs a request. Publishing a deployment
does not activate it.

### 9.9 Runtime Configuration Pin and Host Boundary

A host constructs a closed `RuntimeConfigurationPin` request containing exactly
one ontology release ID/digest, a set of exact immutable mapping-deployment IDs and
digests, exact property/link resolution bindings, an opaque
`host_configuration_revision`, and a `PortCapabilityDescriptor` digest. The pin's
canonical digest covers every field. The host also supplies the descriptor whose
digest was pinned.

The runtime validates every known portable field, referenced digest, compatibility
rule, and advertised capability, and compares the opaque host revision through the
unit-of-work fence before current state can change. It may record and echo the
opaque value but cannot decode it. The runtime owns no activation, generation,
rollout mode, promotion, or rollback aggregate.

Concrete `BindingManifest`, `HostActivation`, and rollout-mode records are
host-adapter state, not portable model types, artifacts, or hashes. SQLite owns a
separate `LocalActivation`, and ServiceRadar owns its own manifest and activation
resources. A host binding manifest may contain only non-secret
credential-reference IDs. Bearer tokens, private keys, passwords, and other
secret material remain outside the manifest, its hash, portable artifacts, and
runtime requests and are resolved out-of-band by the host.

### 9.10 Provenance

Every retained decision, object/property/link observation, identity claim, and
retraction records or immutably references:

- opaque host scope, source contract/version, source instance, record ID, reset
  epoch, tagged revision coordinate, exact source tuple/hash, valid-time interval,
  `known_at`, and completeness marker;
- ontology release, object/property/link definition versions, mapping
  artifact/deployment, resolution bindings, `RuntimeConfigurationPin` digest,
  opaque host-configuration revision, port-capability-descriptor digest, transform
  versions, limits-manifest version, and engine build;
- identity request and returned association revision;
- declared input paths, normalized input hashes, output binding IDs, and decision
  hash;
- validity interval, classification/taint, conflict policy, and current-state
  outcome; and
- actor or system principal and non-secret capability reference, adapter identity,
  and audit correlation ID. Bearer handles, credentials, and capability secrets
  are never provenance fields.

Provenance is append-oriented. Corrections and withdrawals add new observations or
retractions; they do not rewrite the evidence that supported an earlier result.

## 10. Source Mapping and Runtime Semantics

### 10.1 Source Record Envelope

An adapter converts native input into one canonical bounded `SourceRecord`. Its
exact source coordinate is `(opaque_host_scope, source_contract_version_id,
source_instance_id, record_id, reset_epoch, revision_coordinate)`.
`revision_coordinate` is a closed tagged choice of `sequence(u64)` or
`event_id(canonical_bounded_bytes)`; it is never absent or inferred from arrival
order. The host adapter attests the opaque scope and reset epoch from trusted
context. Source payloads cannot select or alter either value.

A sequence is strictly monotonic within the exact `(opaque_host_scope,
source_contract_version_id, source_instance_id, record_id, reset_epoch)` prefix.
A greater sequence may supersede outputs from lower sequences only under the exact
same output lineage defined in Section 10.3. A new reset epoch starts a distinct
sequence history and never supersedes another epoch implicitly. Event IDs are
unordered, immutable coordinates; one event never implies supersession, snapshot
absence, or retraction of another event.

The envelope also carries its valid-time interval, host-assigned `known_at`,
snapshot/delta completeness, declared fields, classification, and canonical
content hash. `valid_at` describes when the source claim is true in the modeled
domain; `known_at` is when the durable runtime first accepted that exact
coordinate. Adapters cannot rewrite `known_at` to hide late arrival. Delivery of
the same source coordinate and canonical envelope hash is a no-op; reuse of the
coordinate with a different hash is quarantined as a source-contract violation.

### 10.2 Identity Resolution Hook

A mapping emits an `ObjectCandidate`, never a caller-selected canonical object ID
or association revision. The runtime sends a bounded `IdentityRequest` to the
configured port with the stable object-type ID, exact type version,
identity-key-schema ID, typed canonical key components, source coordinate,
provenance, ontology release, and expected prior association revision when one is
known.

The identity port returns `accepted(canonical_object_id,
association_revision)`, `ambiguous`, or `rejected`. On acceptance, the runtime
verifies the object ID against the stable identity tuple and alone admits the
observation and changes `ResolvedObject` lifecycle. A later merge, split,
reassignment, or deletion makes work pinned to the older association revision
ineligible and schedules bounded reconciliation. Ambiguous or rejected results
retain only the diagnostics/protected decision described in Section 9.3. The
portable runtime defines this contract, not the host's identity algorithm.

### 10.3 Evaluation and Atomic Visibility

Evaluation is pure and all-or-nothing per source record. It produces one canonical
`MappingDecision` containing `ObjectCandidate` values, unresolved link proposals,
owned retraction proposals, and diagnostics. It does not contain durable
observations or runtime IDs. Decode, validation, integrity, fuel, allocation,
timeout, or panic failure produces no admissible partial decision.

A runtime request carries the exact source coordinate/hash, complete
`RuntimeConfigurationPin` and digest, its opaque `host_configuration_revision`,
the exact mapping deployment and artifact selected by that pin, definition
versions, limits-manifest version, and host authorization capability. Each
proposed output uses the tuple `(mapping_deployment_id,
source_coordinate_hash, output_binding_id, output_kind,
target_definition_version_id, endpoint_or_discriminator_hash)`; fields that do
not apply use a fixed empty tag rather than omission. Reuse with different
canonical output is quarantined.

The exact source-record/output lineage used for sequence supersession is
`(opaque_host_scope, source_contract_version_id, source_instance_id, record_id,
reset_epoch, mapping_deployment_id, output_binding_id, output_kind,
target_definition_version_id, endpoint_or_discriminator_hash)`. Only a greater
`sequence(u64)` in that lineage may supersede a lower sequence, and it may retract
only the earlier output owned by that lineage. An event ID, different epoch,
different source record, or different output lineage never cross-supersedes.

After all required identity calls return, the unit-of-work port atomically makes
the canonical decision, accepted object/property/link observations, owned
retractions, current semantic projections, provenance, and request completion
visible, or provides equivalent staged visibility with idempotent recovery.
Ambiguous/rejected candidates contribute diagnostics but no observations. A
transient identity failure leaves the request incomplete and retryable. Derived
search or graph indexes may lag only when their adapter exposes the materialization
revision and semantic reads cannot confuse them with current authoritative
evidence.

### 10.4 Source Authority and Property Resolution Catalog

The runtime registers immutable `SourceAuthority` revisions. Each binds an
authority ID and revision to eligible source-contract versions and source
instances, permitted semantic targets, confidence range, the half-open intervals
`authority_valid_from <= valid_at < authority_valid_until` and
`authority_known_from <= known_at < authority_known_until`, classification floor,
and output quota. Either upper bound may be absent, meaning unbounded; both lower
bounds are required. Mapping deployments reference one exact authority. Source
payloads cannot name, create, or widen one.

Before any semantic ranking, resolution removes a lower `sequence(u64)` whenever
a greater sequence is visible at the query's `known_at` in the exact
source-record/output lineage from Section 10.3. This does not rewrite history: at
an earlier `known_at` where the greater sequence was not yet known, the lower
sequence remains eligible. Event coordinates and other lineages never participate
in implicit supersession.

Every selected property has exactly one immutable `PropertyResolutionBinding` in
the `RuntimeConfigurationPin`. The binding chooses one V1 policy:

- `single_authority(authority_id)`: keep only the configured authority, then take
  the greatest `valid_from`.
- `precedence(ordered_authority_ids)`: choose the first configured authority with
  eligible evidence, then take that authority's greatest `valid_from`.
- `latest_valid`: across all eligible authorities, take the greatest `valid_from`.
- `highest_confidence`: take the greatest confidence parts-per-million value,
  then the greatest `valid_from`. Missing confidence is ineligible.
- `union_set`: after lineage supersession and eligibility filtering, union all
  eligible set values, deduplicate by canonical element bytes, and sort by those
  bytes. A mix of null and any set is a typed conflict. All-null evidence resolves
  to null only for a nullable property; otherwise it is invalid. No evidence is
  absence, not an empty set.
- `reject_conflict`: resolve only when every eligible observation has identical
  canonical value bytes; otherwise expose a typed conflict and no current value.

For the first four policies, all observations remaining at the final semantic
rank must have identical canonical value bytes. Equal bytes coalesce with joined
provenance and taint; unequal bytes produce a typed conflict and no value. Source,
instance, observation, database-row, arrival, and `known_at` order may sort
diagnostic output only and never choose truth. Confidence is an integer in parts
per million from `0..1_000_000`; binary floating point is forbidden.

Missing input emits no observation. Explicit null is a present canonical value
only for a nullable property and remains distinct from missing, retracted, stale,
invalid, and denied. A retraction removes only its referenced owned observation at
its effective valid/known boundary; it does not assert null or delete another
contributor. Invalid, denied, unresolved, stale, future-invalid, expired,
retracted, inactive-release/deployment, and ineligible-authority observations do
not enter resolution.

Each active link type has one immutable `LinkResolutionBinding`, limited in V1 to
`single_authority`, `precedence`, `latest_valid`, or `highest_confidence` with the
same authority and rank rules above. Resolution groups observations by the exact
logical link identity and ranks only within that group. Equal final-rank evidence
for one `simple` logical identity coalesces with joined provenance. Distinct
logical identities coexist unless they violate a declared role cardinality; only
that violation makes them conflict. Surviving candidate links then pass role
cardinality checks. `union_set` and `reject_conflict` are property-only policies.

### 10.5 Bitemporal Eligibility and Resolution

Every semantic read specifies `valid_at` and `known_at`. A current read defaults
both to the host's current time. A historical-as-known read fixes `known_at` so
evidence received, corrected, or retracted later is invisible even when its
domain-valid time is earlier.

Configuration time and domain-valid time are not interchangeable. An ontology
release and mapping deployment are immutable definitions, not temporal
activations. A historical query supplies one exact `RuntimeConfigurationPin`;
the host decides through its outer activation/scope whether that pin is selectable
at `known_at`. Late-arriving evidence may describe a valid-time interval before
the host configuration that admitted it existed.

An object, property, or link observation is eligible only when:

1. its exact ontology release, mapping artifact/deployment, source-authority
   revision, and resolution binding match the `RuntimeConfigurationPin`;
2. its object identity association revisions are unambiguous and effective;
3. `valid_from <= valid_at` and `valid_until` is absent or `valid_at < valid_until`;
4. `known_at_observation <= known_at_query`;
5. no retraction with `effective_valid_at <= valid_at` and
   `known_at_retraction <= known_at_query` references it;
6. its source authority satisfies both half-open intervals above; and
7. its definition's optional positive `max_age_us` is absent, or checked signed
   arithmetic proves `valid_at < valid_from + max_age_us`.

`max_age_us` must be in `1..i64::MAX`; zero is invalid rather than an
instantaneously fresh value. Addition overflow rejects the definition or
observation instead of saturating. At equality the observation is stale. This
freshness test is independent of, and cannot extend, an earlier `valid_until`.
`known_at` controls evidence visibility and sequence supersession only; it never
drives or extends freshness.

No eligible evidence yields absence. It never yields a fabricated null, false,
zero, empty collection, or unresolved link. Materialized current rows are caches;
every read checks the next valid-time and known-time transition so delayed
maintenance cannot expose ineligible evidence.

### 10.6 Complete Snapshots, Deltas, and Retractions

A source contract declares whether sequence-coordinate records are deltas,
per-object snapshots, or complete collections. Only a greater sequence in the
same reset epoch and an authenticated complete scope may infer absence. A partial,
timed-out, or unauthenticated collection cannot retract unseen objects, properties,
or links. An `event_id` record is always independent for supersession purposes and
never implies absence, regardless of its payload shape.

When newer authoritative evidence removes a previously emitted output, the
runtime appends an explicit owned retraction. A mapping can retract only evidence
owned by its source and output binding. It cannot delete another source's evidence
or a host assertion.

### 10.7 Host Rollout Fence and Reconciliation

`shadow`, `enforce`, `disabled`, promotion, and rollback are host-only rollout
concepts. A host may evaluate a candidate `RuntimeConfigurationPin` against
bounded fixtures or authorized snapshots in its shadow mode, but the portable
runtime receives only an ordinary pinned request and persists no rollout mode or
activation aggregate.

Before committing current state, the runtime asks the unit-of-work port to compare
the request's opaque `host_configuration_revision` with the host's current fence.
Old work may finish for protected audit but cannot update current projections
after that fence changes. Host rollback constructs a pin for retained immutable
artifacts and advances its own host configuration revision; SQLite performs the
same operation through its separate `LocalActivation`.

Host rollout changes, source-contract changes, identity revisions, definition
changes, and adapter recovery may schedule bounded recomputation through the same
pinned path as live work. Reconciliation detects missing requests, stale
projections, unretracted output, and lagging materializations. It never writes
semantic facts through a privileged shortcut.

### 10.8 Replay

Exact replay requires immutable canonical source-envelope bytes and coordinate,
ontology release, mapping artifact/deployment, resolution bindings, the exact
`RuntimeConfigurationPin` and digest, port-capability descriptor,
limits-manifest version, identity-resolution result, engine build, and recorded
output bytes. Replay runs without projection and compares canonical decision and
trace hashes. It never falls forward to current source, identity, mapping,
configuration, or host state.

Protected evidence and deterministic redacted evidence are separate contracts.
The host adapter applies its authorization and retention policy; a hash without
the exact retained inputs is not described as replayable.

## 11. Ontology Versioning and Evolution

### 11.1 Lifecycle

| Artifact | Lifecycle |
| --- | --- |
| Ontology source/module | Draft, under review, rejected, or superseded |
| Ontology release | Published semantic-only dependency set; deprecated or retired; bytes never mutate |
| Mapping source | Draft, under review, rejected, or superseded |
| Mapping artifact | Published immutable source-to-semantic program; deprecated or retired |
| Mapping deployment | Published immutable exact artifact/authority/binding-slot/ownership/quota selection; never activates itself |
| Runtime configuration pin | Closed host request with an exact release, deployment set, resolution bindings, opaque host revision, and port-capability digest |
| Host configuration/activation | Adapter-owned `BindingManifest`, `HostActivation`, and rollout state outside portable artifacts |
| SQLite local activation | Adapter-local `LocalActivation` selecting a runtime configuration pin for the standalone distribution |
| Object/property/link observation or retraction | Append-only evidence under retention |
| Resolved object or link | Runtime-owned current/temporal semantic projection with tombstone history |
| Current projection or index | Rebuildable, version-tagged materialization |

Publication and configuration are separate at every layer. Ontology publication
freezes semantic definitions. Source-contract publication and mapping publication
remain distinct runtime operations. A `MappingArtifact` pins exactly one
`SourceContract` version and schema plus exactly one `OntologyRelease` digest; it
accepts no compatible range. A `MappingDeployment` immutably selects exactly one
artifact, one `SourceAuthority` revision, a source-binding slot, an output
ownership namespace, and downward-only quotas and limits. A host constructs a
`RuntimeConfigurationPin` from exact published dependencies and manages any
activation or rollout without creating a portable activation aggregate.

### 11.2 Compatibility

The owning core or runtime compiler classifies each change:

- **Additive:** adds definitions without changing existing meaning.
- **Compatible:** narrows no accepted value and preserves existing query and
  mapping contracts.
- **Migration-required:** changes constraints, cardinality, interface
  satisfaction, resolution, identity, link endpoints, classification, freshness,
  or indexing in a way that needs recomputation or adapter work.
- **Breaking:** removes or reinterprets a stable contract; requires an explicit
  new major version and consumer migration.

The compatibility report lists affected object types, interfaces, properties,
links, mappings, queries, host bindings, indexes, and retained evidence. An
adapter may be stricter but cannot relabel a breaking change as compatible.

### 11.3 Configuration and Migration

A `RuntimeConfigurationPin` fails closed when a semantic dependency,
mapping artifact/source authority, resolution binding, identity capability,
storage feature, query capability, materializer, or retained artifact is missing
or incompatible with the supplied port-capability descriptor. The operator must
approve and execute a bounded migration or reprojection plan before affected
output becomes current. A host activation may add stricter checks but cannot
weaken this portable validation.

Queries, decisions, provenance, and migration checkpoints always record the exact
`RuntimeConfigurationPin` digest and opaque host-configuration revision they used.
Multiple retained pins may remain queryable where the adapter supports temporal
access, but a request never mixes releases, mapping deployments, resolution
bindings, or host fences implicitly.

## 12. Semantic Catalog and Query

### 12.1 Catalog

The portable catalog exposes:

- ontology modules and active/retained releases;
- object types, implemented interfaces, properties, link types, and constraints;
- source contracts and mapping lineage;
- compatibility and deprecation status;
- host capability and materialization availability;
- classification, freshness, retention, and query support; and
- provenance fields available for authorized inspection.

Labels and documentation are presentation metadata. Stable IDs and immutable
versions are the programmatic contract.

### 12.2 Semantic Query Model

The portable query intermediate representation supports bounded:

- object-type or interface selection;
- typed property existence, equality, range, set, and text capabilities declared
  by the adapter;
- directed link traversal constrained by registered link types;
- projection of selected properties and links;
- exact `RuntimeConfigurationPin` digest, opaque host-configuration revision,
  `valid_at`, and `known_at` selection; and
- provenance and freshness inspection.

The runtime validates semantic meaning and bounds. A `QueryAdapter` translates or
executes the validated plan using host facilities. The portable crates do not
contain SQL, SRQL, Cypher, GraphQL, OData, or provider query parsing.

V1 query semantics are complete for ordering and pagination:

- Without an explicit order, results sort by canonical runtime object ID bytes
  ascending.
- An explicit order lists typed property keys and direction. V1 order keys are
  limited to booleans (`false < true`), signed integers, decimals by exact
  mathematical value without rounding, timestamps and durations by signed
  microseconds, dates by signed epoch-day value, strings and URIs by unsigned
  UTF-8 byte lexicographic order, bytes by unsigned byte lexicographic order,
  enumerations by canonical member-ID bytes, object references by object-type then
  canonical object-ID bytes, and runtime object IDs by canonical ID bytes.
  Decimal comparison uses an overflow-free bounded intermediate; an adapter may
  not substitute floating point or a database-native collation. Lists and sets
  are not orderable in V1. Each order key declares exactly one
  total permutation of the `value`, `null`, and `absent` buckets; the default is
  `value, null, absent`, and a duplicate or omitted bucket is invalid. The
  ascending/descending direction applies within the `value` bucket and does not
  reverse the declared bucket permutation. Null and absent never compare equal.
- Canonical runtime object ID ascending is always appended as the final unique
  tie-breaker. Link traversal results add canonical resolved-link identity before
  target object ID when duplicate target occurrences are requested.
- `is_present` matches an eligible resolved value or explicit null;
  `is_not_null` matches an eligible present non-null value; `is_null` matches an
  eligible explicit null; and `is_absent` matches no resolved value.
  Equality/range with a null literal is invalid rather than three-valued or
  backend-specific behavior.
- Pagination is keyset-only. The closed portable cursor binds the canonical query
  digest, exact `RuntimeConfigurationPin` digest, opaque host-configuration
  revision, `valid_at`, `known_at`, page size, complete order definition, typed
  last-returned tuple, and final canonical object ID. Each tuple component
  preserves its absent/null/value state, type, and canonical value bytes. A
  changed field rejects the cursor; offsets and unbound backend cursors are
  forbidden. Every production host adapter MUST authenticate and seal the
  portable cursor inside an outer host cursor that also pins host activation and
  authorization scope. SQLite MUST apply an adapter-local authenticated seal that
  pins its `LocalActivation` and local scope. Those outer fields are not part of
  the portable cursor.

Every plan carries a caller budget and every query adapter advertises supported
operators, traversal depth, indexes, and a deterministic cost class. The request
field `count` is exactly `none` or `exact`, and both modes are required by
`semantic-query-v1`. An exact count uses the identical authorization filter,
`RuntimeConfigurationPin` digest, opaque host-configuration revision, bitemporal
snapshot, predicates, traversal, and cost budget as the returned rows. A plan over
budget is rejected before execution.
Approximate count, grouping, aggregation, and pivots are deferred beyond V1.

Every portable result reports the `RuntimeConfigurationPin` digest, opaque
host-configuration revision, `valid_at`, `known_at`, and any materialization
revision used. A host adapter may add its activation and scope metadata only in an
outer host result.
Authorization and classification filtering occur before predicates, counts,
sorting, traversal, or provenance disclosure so denied existence cannot be
inferred.

## 13. Ports and Adapter Responsibilities

| Capability | Portable contract | SQLite/WAL baseline | Scalable host responsibility |
| --- | --- | --- | --- |
| Storage and unit of work | Immutable catalog/evidence plus atomic-visibility traits | Local SQLite transactions and WAL | Implement the traits against host stores; do not call SQLite as a service |
| Identity | Typed evidence request and revision-pinned result | Exact typed key only | ERP master data, MDM, graph identity, or another resolver |
| Links and graph | Runtime-owned `ResolvedLink`; materialization port is a revisioned cache only | Relational adjacency in SQLite | External graph/adjacency cache or no separate graph |
| Authorization and scope | Opaque non-payload capability context | Single local administration scope | Host RBAC/ABAC and tenancy model |
| Source ingestion | Bounded `SourceRecord` contract | Local CLI/library admission | Connectors, files, APIs, CDC, or queues |
| Query | `semantic-query-v1` IR and catalog | Mandatory bounded executor including exact count | Host SQL/API/search translation plus declared port capabilities |
| UI | Catalog and result contracts only | None | Host-specific UI or no UI |

The portable runtime must function with the in-memory and SQLite adapters and
without any product adapter present. A textile-oriented adapter may bind object identity
to material lots, work orders, suppliers, and machines; use different storage and
authorization; and expose a different query or UI. None of those choices may
require a provider branch in the core.

## 14. Non-Normative Appendix: ServiceRadar Adapter Sketch

This appendix illustrates one optional host integration. It is not part of the
portable V1 model or base conformance contract and cannot add ServiceRadar
vocabulary or behavior to portable artifacts or crates.

### 14.1 Existing Authorities Remain Authoritative

- OCSF events and devices remain the canonical event and device resources. An
  ontology object type may bind to or project an authorized view of them, but the
  portable runtime does not overwrite canonical OCSF fields.
- DIRE remains the identity authority for canonical ServiceRadar device bindings
  and any other native type already governed by DIRE. An ontology-local type with
  no existing host identity authority may use exact or binding-local
  source-scoped identity. One activated host configuration must not mix identity
  modes for the same object type and identity-key schema. Opting an existing
  native type out of its identity authority requires a separate approved ADR,
  migration proposal, and reconciliation plan.
- Existing AGE-native topology remains owned by its current producers. For links
  defined in the portable ontology, the runtime is the semantic authority and AGE
  is only a revisioned materialization/cache of `ResolvedLink` output. The adapter
  must not let an AGE-only edge masquerade as a current ontology link.
- SRQL remains the product query surface. The adapter maps validated semantic
  queries and catalog entries into approved SRQL/read-model shapes.
- Plugin manifests and Wasm/native source contracts own collection and field
  allowlisting. Ontology mappings never call providers or broaden collected data.
- Ash resources, policies, and `Ash.Scope` own persistence authorization.

### 14.2 Deployment Isolation

Each ServiceRadar deployment remains isolated by its services, schema-scoped
database credentials, and PostgreSQL `search_path`. The adapter constructs a
trusted project-owned scope for background work. It never serializes a
caller-selectable deployment, schema, search path, or arbitrary actor into a
portable source record, artifact, mapping, runtime request, or cache handle.

Existing partition and canonical object references are copied only from
authenticated server context and revalidated at commit. Source payloads cannot
select another partition, entity, ontology release, mapping, or output definition.

ServiceRadar, not the portable runtime, owns its concrete `BindingManifest` and
`HostActivation` Ash resources. The activation selects an exact
`RuntimeConfigurationPin` and passes that request, its digest, its opaque
host-configuration revision, and the pinned port-capability descriptor across the
portable boundary. Its binding manifest may store non-secret credential-reference
IDs only. Credential bytes and bearer material are resolved out-of-band and are
excluded from the manifest hash, portable artifacts, source records, runtime
requests, and provenance.

### 14.3 Telemetry and Application State

All ServiceRadar metrics and telemetry continue to publish to NATS JetStream
first and persist through EventWriter. An ontology adapter may consume a durable
JetStream event or an authorized canonical event view after that boundary; it
must not add a collector-to-CNPG telemetry path or require publish-and-read-back
merely to persist non-telemetry ontology administration state.

Inventory or configuration observations already committed through Ash/CNPG may
schedule ontology work in the same transaction. Evaluation remains asynchronous.
The ontology engine is not inserted synchronously into metric, log, flow, trace,
identity, topology, or canonical device write paths.

### 14.4 ServiceRadar Query and Rustler Gates

The adapter may expose the portable catalog, object/property predicates, direct
link traversal, bitemporal pins, ordering, keyset cursor, and exact count through
SRQL only when SRQL preserves `semantic-query-v1` exactly. Approximate count and
other deferred query features remain explicit errors. SRQL parsing and planning
stay outside the portable Rust crates.

Adapter approval must select the exact SRQL shapes that preserve those semantics;
that adapter-local decision does not block either portable proposal.

The Rustler binding is a ServiceRadar execution adapter only. Compile, evaluate,
batch, replay, and artifact verification/load over 64 KiB use `DirtyCpu`;
normal-scheduler NIFs are constant-time handle operations over no caller-sized
collection. Scheduler, panic, cache, restart, overload, and malformed-binary tests
are gates for this adapter, not requirements that another host use BEAM or Rustler.

### 14.5 ServiceRadar Coexistence

| Existing capability | Ontology adapter behavior |
| --- | --- |
| OCSF canonical fields | Bind or read through explicit definitions; never silently replace or dual-write them. |
| DIRE associations | Consume revisioned outcomes; never merge, split, or guess identity itself. |
| AGE graph | Materialize runtime-owned `ResolvedLink` rows with an exact generation; keep unrelated native AGE topology separately labeled. |
| SRQL | Add bounded semantic catalog/object/link shapes through the existing authorization path. |
| Legacy flat metadata | Keep a separately labeled compatibility surface; no implicit fallback or precedence. |
| Risk, anomaly, causal, alert, and security analytics | May consume ontology output through explicit versioned contracts; ontology core does not run their algorithms. |
| Actions, notifications, and remediation | Remain outside the V1 ontology adapter and may consume versioned ontology output only through later approved contracts. |

### 14.6 Edge Record V1 Adapter Boundary

This subsection applies only when a ServiceRadar binding consumes an admitted
`EdgeRecordV1`. It does not change the portable core or runtime contracts, and it
does not redefine the Edge Record V1 ABI. That ABI remains the authority for raw
frame bounds, authenticated carrier and capability checks, record and frame
integrity, semantic-envelope verification, delivery-slot comparison, and ingest-
ledger admission.

The ontology adapter may consume only a durable item or authorized canonical
event view that attests prior completion of that full edge boundary. A raw pre-
admission frame is not an ontology source, and decoding protobuf successfully is
not admission. Ontology evaluation remains asynchronous and outside edge
admission, ACK, delivery, and native canonical-write transactions, including
EventWriter where applicable.

The adapter preserves, but does not collapse, the edge identity layers:

| Edge quantity | Ontology-adapter treatment |
| --- | --- |
| `submission_sha256` | Producer-receipt identity local to the producer journal. It is not required, reconstructed, or placed on the portable source envelope. |
| `(network_scope_id, event_id)` | Edge ingest-ledger identity. An event-mode edge binding preserves the exact `event_id` as its unordered event revision coordinate; its versioned `record_id` and `source_instance_id` mapping must not use a delivery slot. |
| `semantic_envelope_sha256` | Verified edge semantic-identity evidence. It is not recomputed from portable JSON or CBOR. |
| `payload_sha256` | Verified exact payload-artifact evidence committed by the semantic envelope. It is not the `SourceRecord` canonical content hash. |
| `record_sha256` and, when retained, exact record bytes | Host physical-artifact evidence. A legal protobuf re-encoding may change them without creating a different semantic source record. |
| Agent or service slot, NATS publication identity, delivery capability or proof, delivery mode, and transport provenance | Host delivery evidence kept outside the portable semantic coordinate and `SourceRecord` canonical content hash under the applicable retention policy. It never implies source supersession, absence, or retraction. |
| `SourceRecord` canonical content hash | The Section 8.2 logical hash of the canonical `SourceRecord` contract envelope in the `portable-ontology-v1` domain. It never substitutes for an edge artifact, semantic, event-ledger, or publication identity. |

The selected binding defines every adapter-owned coordinate component: the
trusted opaque-host-scope mapping, source instance, record ID, and host-attested
reset epoch. The admitted `network_scope_id` must match authenticated server
context rather than select deployment scope. Delivery, retry, and recovery changes
do not advance the reset epoch.

`HostActivation` selects an authorized `BindingManifest` independently of source
payload. That selected binding pins the expected schema-stable edge contract
identity (`contract_id`, `contract_version`, and `contract_bundle_sha256`) and its
portable source-contract version and mapping deployment. The adapter equality-
checks those values against the admitted record while preserving the complete
`EdgeOutputContractRef`, including registry epoch, registry snapshot, and
effective grant, as admission evidence. The edge reference is not itself a
portable `SourceContract`, ontology release, source authority, or mapping
selector. Likewise, `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE` does
not authorize an ontology observation or projection. That decision remains
separately pinned by `BindingManifest`, `SourceAuthority`, and `HostActivation`.
Edge Hello negotiation, lane-open coordinates, and the portable
`PortCapabilityDescriptor` are separate contracts and are not inferred from one
another. Authenticated agent or service identity remains trusted carrier
provenance and is not replaced by producer attribution carried in the record.

Under the same selected immutable binding, portable source-contract and adapter-
transform versions, coordinate mapping, host-attested reset epoch, and recorded
first-acceptance `known_at`, retries, legal outer-record re-encodings, and recovery
rewrapping with the same edge ledger identity and semantic-envelope identity
produce the same portable semantic input. Repeated portable admission is a no-op;
a new physical delivery receipt may be appended host-side without mutating the
accepted `SourceRecord`. A different semantic-envelope identity under the same
edge ledger key must not reach portable source admission. The native host may
retain the ledger disposition and conflict evidence, but neither is an ontology
source.
Agent spool sequence and service publication sequence are never mapped to
portable semantic `sequence(u64)` merely because they are ordered delivery
coordinates.

Edge timestamps remain raw signed nanoseconds through edge decoding, admission,
and every edge hash or identity comparison. Only after that boundary may source
adaptation under a named, versioned transform convert a domain timestamp to the
portable signed-microsecond type. The transform uses the frozen containing-
microsecond-bucket rule (mathematical floor, including for negative values) and
retains the original nanoseconds as typed source evidence when replay or audit
requires their fidelity. Before activation, the adapter change must register
this new consumer in the enumerated projection-consumer list of the frozen edge
requirement `Nanosecond time is canonicalized to microseconds only at the
projection boundary`. A `SourceRecord` canonical content hash therefore never
masquerades as an edge hash over normalized time. Portable
`valid_at` comes only from declared domain evidence under the versioned source
contract, never from UUIDv7 allocation time, broker arrival, or delivery order.
`known_at` keeps its Section 10.1 meaning: the authorized host clock assigns it
when the durable ontology runtime first accepts the exact portable coordinate,
not from producer, payload, broker, spool, or recovery time.

One canonical portable source envelope, including its metadata, must remain
within the 1 MiB runtime ceiling. Delivery-varying physical evidence stays
outside that envelope and its canonical content hash. Stable source provenance
required by the portable source contract remains in the immutable `SourceRecord`.
Any durable-stream identity included there is a binding-owned logical identity
that is invariant across original and recovery placement. A concrete NATS stream,
subject, or lane placement, JetStream consumer cursor, publication coordinate,
delivery attempt, or receipt belongs to the outer host unit-of-work, idempotency
fence, and audit record; it does not become a portable source cursor or enter the
`SourceRecord` canonical content hash. Physical
receipts need not be duplicated inside the source envelope; when host retention
policy keeps exact frame or record bytes, protected evidence references or
verified hashes may identify them. Every value required by pure mapping remains
in the bounded envelope; the evaluator cannot dereference the host evidence
handle. An edge-
source binding requires an explicit worst-case sizing proof and fails without
truncation, splitting, or partial output when the portable ceiling is exceeded.
That failure does not alter the already accepted native event.

Portable replay continues to use the exact retained canonical `SourceRecord` and
historical portable pins from Section 10.8. Replaying the native Edge-to-Source
adaptation additionally requires exact admitted native evidence, the edge-
admission version, trusted carrier attestation, selected binding, coordinate
mapping, and adapter-transform version. A digest or unresolved evidence handle
alone is not replayability. If host retention no longer preserves the native
input, native translation is non-replayable even when the already-retained
portable envelope remains replayable.

If normative edge loss or recovery artifacts are later adapted, they require a
separately declared source contract. A declared delivery-loss span and a sequence
outside the declared loss union make no claim about the existence, absence,
supersession, or retraction of ontology evidence.

## 15. Non-Normative Source and Domain Examples

No example below is a required provider integration or privileged core concept.
The conformance corpus must include all five source classes so the design cannot
quietly specialize around one.

| Source class | Illustrative source | Illustrative ontology output |
| --- | --- | --- |
| Asset inventory snapshot | Commercial or open-source inventory export | Device-like objects, source-qualified attachment properties, and candidate network links |
| Network discovery | SNMP, LLDP, or neighbor discovery | Network node and interface objects with `connected_to` or `observed_via` link evidence |
| Cloud/orchestrator inventory | Kubernetes or cloud resource APIs | Cluster, node, workload, account, and service objects with containment and runtime links |
| Security analytics | Normalized events, vulnerability scanners, or SIEM feeds | Finding, software, actor, and asset observations with `affects` or `observed_on` links |
| Textile/operations | ERP, MES, machine, or batch exports | Material lot, machine, work order, supplier, and process-step objects with production links |

Provider names, field paths, enum vocabularies, and normalization details live in
fixture or package data. Replacing any source above with another conforming source
must require no portable-core code change.

## 16. Security, Privacy, and Governance

- V1 ontology sources and mappings are platform-authored, reviewed, and published
  as immutable artifacts. Tenant-authored or third-party package import requires a
  separate supply-chain and isolation proposal.
- The portable engine accepts opaque capability and scope handles only from a host
  adapter. It never derives authorization from source fields or ontology labels.
- Every adapter operation for authoring, review, publication, activation, rollback,
  replay, protected evidence, and query must map to an explicit host permission.
- Publication requires review distinct from the last editor. Activation and
  rollback reference an approved artifact and are fully audited.
- A finite host-registered classification lattice governs taint. Outputs, reasons,
  traces, counts, link selection, and provenance inherit the join of all
  referenced inputs and identity/resolution-port-added data. V1 provides no declassification
  transform.
- Protected and redacted traces are different canonical artifacts with different
  hashes and limits. Protected source values, hashes, paths, contributor identity,
  and branch-selection details never enter ordinary logs, telemetry, errors,
  catalog results, exports, or query responses.
- Secret and credential values are forbidden semantic/source/mapping values. A
  host binding manifest may retain a non-secret credential-reference ID only;
  V1 never stores, hashes, maps, or transports the referenced secret material.
- Artifact, source-record, snapshot, decision, and replay bytes are hash-verified
  and decoded with hostile-input bounds. Unknown versions and fields fail closed.
- Source, mapping, identity, storage, query, and materialization adapters each have
  an explicit threat model and negative conformance tests.
- Retention and legal deletion are host policies recorded in immutable evidence
  metadata. Missing protected bytes make a record non-replayable; hashes alone do
  not recreate evidence.

## 17. Reliability, Limits, and Operability

### 17.1 Initial V1 Platform Ceilings

The `ontology-core-v1` profile has these exact hard ceilings:

- 64 namespaces;
- 256 interfaces;
- 1,024 property definitions;
- 1,024 object types;
- 2,048 link/relationship types;
- interface inheritance depth 8;
- 8 directly implemented interfaces per object type;
- 256 effective properties per object type after inheritance;
- 256 effective link roles per object type after inheritance;
- 4 KiB per semantic string;
- 1,024 elements per semantic list or set;
- 64 KiB of annotations per semantic resource; and
- 16 MiB per compiled semantic artifact encoding.

The `ontology-runtime-v1` profile has these exact hard ceilings:

- `SourceSchema` nesting depth 8;
- 1,024 fields per source record type;
- 1,024 elements per source list;
- 1 MiB per canonical `SourceRecord` envelope;
- 256 emission templates per mapping;
- 256 expression nodes per emission template;
- 1,024 iterations for any bounded mapping iteration;
- 1,024 combined observations and retractions admitted from one source record;
  and
- 4 MiB per compiled mapping plan.

These ceilings, profile IDs, and their rejection diagnostics are generated from
one versioned conformance manifest used by the compiler, runtime, SQLite adapter,
tests, and documentation. A release, mapping, deployment, or adapter may lower but
never raise them. Limit excess produces a stable value-free error before partial
output; the engine does not truncate, silently sample, or split one atomic
decision. Any additional trace, batch, query, or concurrency bound belongs to its
named profile or host capability descriptor and cannot masquerade as a different
portable V1 ceiling.

### 17.2 Runtime Properties

- Compilation, evaluation, replay, migration planning, and semantic-query
  validation are deterministic for identical canonical inputs and
  limits-manifest version.
- Source admission is idempotent under the exact source coordinate, quarantines
  coordinate reuse with different content, and applies sequence supersession only
  inside the exact source-record/output lineage.
- Old source coordinates, identity associations, mapping or ontology versions,
  `RuntimeConfigurationPin` digests, and opaque host-configuration revisions
  cannot overwrite current evidence after a fence changes.
- Expiry and retraction correctness does not depend solely on a maintenance worker
  running on time.
- Work leases, retries, abandoned-work recovery, backfill, and reconciliation are
  bounded and resumable.
- Runtime failure cannot block a host's established source, identity, query,
  telemetry, or effect path.
- Adapter restart, replica join, stale cache handle, incompatible artifact, and
  configuration race fail visibly and preserve the prior portable runtime
  configuration; host activation recovery remains adapter-owned.
- Replay distinguishes expired evidence, missing build, incompatibility, integrity
  failure, and output mismatch.

### 17.3 Scheduler and Performance Gates

Compile, evaluate, batch, and artifact verification/load use a host execution class
appropriate for bounded CPU work. Each adapter must demonstrate that maximum
allowed work cannot starve its control, request, or asynchronous delivery threads.

Before a production adapter activates enforce mode, it must publish a performance
report for:

- compilation time and memory by ontology and mapping size;
- single and batch evaluation p50/p95/p99 latency;
- source-record admission and unit-of-work commit latency;
- identity and link-materialization port latency and failure behavior;
- query latency and plan bounds by storage capability;
- activation, rollback, cache load/swap, and replica restart;
- backfill and reconciliation throughput under live load; and
- evidence, current projection, catalog, graph, and index storage growth.

### 17.4 Observability

Adapters expose value-free counts, latency histograms, and bounded status for
compile, load, evaluate, query-plan validation, identity resolution, source
admission, transaction commit, replay, activation, rollback, backfill,
reconciliation, expiry, retraction, conflict, stale result, and materialization.

Operators can inspect the `RuntimeConfigurationPin` digest, ontology release/hash,
mapping deployments/artifacts, resolution bindings, opaque host-configuration
revision, port-capability-descriptor digest, adapter and engine builds, cache
state, queue age/depth, retry/dead-letter volume, source lag, identity ambiguity,
graph/index materialization revisions, and replay status.

## 18. Primary User Flows

### 18.1 Define and Publish an Ontology Release

1. A platform modeler creates or revises semantic object types, interfaces,
   identity-key schemas, properties, link types, and value types in a draft
   module.
2. The core validates syntax, types, bounds, interface satisfaction, link
   endpoints, dependency cycles, taint, and semantic compatibility without a
   source mapping or host capability.
3. The compiler produces a deterministic compatibility and impact report against
   the selected prior release.
4. Golden semantic and codec fixtures run against the exact source and
   `ontology-core-v1` conformance-manifest version.
5. A distinct reviewer approves the source and impact report.
6. Publication stores immutable source, artifact, catalog, dependency, build, and
   review evidence. It does not activate the release.

### 18.2 Onboard a Source

1. An adapter owner registers a bounded runtime source contract and proves opaque
   scope, reset epoch, tagged sequence/event coordinate, completeness,
   classification, and idempotency semantics.
2. An integration engineer authors mappings using only declared source paths and
   registered ontology outputs.
3. Fixtures cover valid, missing, null, invalid, stale, duplicate, reordered,
   partial, complete, oversized, identity-ambiguous, and link-conflict cases.
4. Shadow evaluation compares `ObjectCandidate` values, unresolved links,
   identity requests, proposed retractions, diagnostics, and provenance without
   creating observations or changing current state.
5. The publisher creates one immutable `MappingDeployment` with its exact
   artifact, `SourceAuthority` revision, binding slot, ownership namespace, and
   limits. The host then constructs a `RuntimeConfigurationPin`, advances its own
   activation if approved, and starts bounded recomputation through the normally
   fenced runtime path. Publishing the deployment alone activates nothing.

### 18.3 Query and Explain

1. A caller selects an object type or interface and supplies a bounded semantic
   query with an exact `RuntimeConfigurationPin` digest, opaque
   host-configuration revision, `valid_at`, and `known_at`.
2. The host authorizes scope and classification before planning predicates or
   traversal.
3. The query adapter translates the validated plan to host storage/query systems,
   applies `semantic-query-v1` and the supplied port-capability descriptor, and
   returns the pin digest, opaque host-configuration revision, and every
   materialization revision used.
4. An authorized explanation traces a property or link to its exact source
   records, identity decision, mapping artifact, definitions, resolution binding,
   `RuntimeConfigurationPin` digest, and opaque host-configuration revision.
5. Ordinary users receive deterministic redacted provenance. Protected evidence
   requires a separate audited host permission.

### 18.4 Evolve or Roll Back

1. The core and runtime compilers classify their owned changes and enumerate
   affected definitions, mappings, queries, bindings, and materializations.
2. The host verifies required capabilities and runs bounded shadow and migration
   plans.
3. The host constructs a new exact `RuntimeConfigurationPin` and compare-and-swaps
   its own `HostActivation` or SQLite `LocalActivation`. The runtime validates the
   pin and compares the opaque host fence but owns no activation transition.
4. Old work remains auditable but cannot update current projections.
5. Reconciliation rebuilds affected state and exposes progress and failures.
6. Host rollback advances host-owned activation to a retained exact pin and
   performs the same guarded recomputation; it never edits history or creates a
   portable rollback aggregate.

## 19. Delivery Strategy and Proposal Boundaries

### Proposal 1: `add-portable-ontology-core`

Owns only the domain-neutral semantic model and compiler:
`OntologyModule`/`OntologyRelease`, `ValueType`, `PropertyDefinition`,
`ObjectType`, `Interface`, identity-key schemas, and `LinkType` including roles,
direct/object-backed representation, edge identity, and typed discriminator
schemas. It also owns semantic compatibility, the exact canonical JSON/CBOR and
SHA-256 contract, the conformance-manifest schema, only the `portable-base-v1`
and `ontology-core-v1` manifest sections, and their golden/fuzz/property corpus.
It contains no source contract, mapping, source authority, resolution algorithm,
evaluator, runtime port, or persistence implementation.

### Proposal 2: `add-portable-ontology-runtime`

Owns `SourceSchema`, `SourceContract`, the mapping language/compiler/evaluator,
`MappingArtifact`, `MappingDeployment`, `ObjectCandidate`, identity requests,
atomic observation admission, runtime-authoritative `ResolvedObject` and
`ResolvedLink`, `SourceAuthority`, property/link resolution, provenance,
retractions, bitemporal semantics, `RuntimeConfigurationPin` validation and
hashing, opaque host-fence comparison, replay, semantic query IR, port
traits/capability descriptors, in-memory conformance support, and the SQLite/WAL
standalone adapter with `LocalActivation`. It contributes the
`ontology-runtime-v1`, `semantic-query-v1`, and `sqlite-store-v1` manifest
sections; its distribution assembles and verifies the single manifest and owns
the standalone and cross-host portability GA gates. It owns no host activation or
rollback aggregate and no product-host `BindingManifest` or `HostActivation`, and
remains free of ServiceRadar and textile/ERP dependencies.

### Proposal 3: `add-serviceradar-ontology-adapter`

Owns the non-normative optional bindings to OCSF, DIRE, AGE, SRQL, plugin
manifests/Wasm source contracts, Ash/CNPG resources, implicit deployment
isolation, Rustler, and NATS JetStream/EventWriter boundaries. It also owns the
concrete ServiceRadar `BindingManifest`, `HostActivation`, credential-reference
resolution, administration, operator UI, and host authorization. It cannot add
ServiceRadar behavior to the portable crates.

### Later Separate Proposals

- Arbitrary ontology functions and safe computed properties.
- Action types, bounded policies, action plans, dispatch, and execution receipts.
- Workflow/playbook definitions, state machines, and orchestration.
- Tenant-authored ontology packages, signing, import/export, and visual authoring.
- Generated APIs or user interfaces.

Each later capability consumes stable ontology contracts and requires its own
security, compatibility, failure, authorization, and rollback design.

## 20. Success Metrics

- A new bounded source can be registered, mapped, fixture-tested, shadowed, and
  activated without a portable-core code change.
- The same ontology source produces a byte-identical `OntologyRelease`, and the
  same runtime source/mapping/configuration fixture produces a byte-identical
  `MappingDecision`, on supported AMD64 and ARM64 builds.
- Canonical JSON and deterministic CBOR vectors decode to one logical value and
  SHA-256 envelope on every supported architecture, including Unicode,
  decimal, timestamp, date, bytes, URI, object-reference, set-order,
  unknown-field, and envelope boundaries.
- The standalone SQLite/WAL V1 distribution passes `portable-base-v1`,
  `ontology-core-v1`, `ontology-runtime-v1`, `semantic-query-v1`, and
  `sqlite-store-v1` with no skipped applicable cases; the in-memory adapter remains
  a non-durable conformance oracle.
- The project makes no general or cross-host portability GA claim until an
  independently maintained non-SQLite production adapter, using only public
  portable contracts, passes every applicable profile. The ServiceRadar adapter
  does not count toward this gate.
- At least two unrelated domain examples, including textile/operations, compile
  and evaluate through the same core artifacts and APIs with zero domain branches
  in portable code.
- One hundred percent of displayed properties and links can be traced to exact
  ontology, mapping, source, identity, and resolution versions, subject to
  authorized retention.
- Multi-source object/link lifecycle tests prove that retracting one contributor
  preserves the resolved projection and retracting the final contributor creates
  a retained tombstone.
- All six property policies pass missing/null/stale/retraction, equal-time,
  authority, confidence, and conflict vectors with no backend-dependent winner.
- Bitemporal fixtures return different correct results for the same `valid_at`
  under two `known_at` values, including late evidence and later-known retraction.
- Source-coordinate fixtures prove same-tuple/same-hash idempotency,
  changed-hash quarantine, sequence supersession only within exact lineage, no
  event supersession, and correct historical-as-known results.
- Ambiguous/rejected identity, stale-association, host-fence race, host rollback,
  and crash tests produce zero unauthorized observations, zero stale-fence current
  writes, and zero partial visible decisions.
- `semantic-query-v1` fixtures prove portable cursor pinning, null/absent ordering,
  exact-count authorization/snapshot parity, and deterministic cost rejection.
- Breaking ontology changes are rejected from compatible activation and enumerate
  every known affected mapping and host binding.
- Unauthorized queries, counts, errors, traces, and provenance reveal neither
  protected values nor protected existence.
- If the optional ServiceRadar adapter proposal is pursued, its adapter-local
  tests show no new telemetry path bypasses JetStream and no ontology payload can
  select deployment, schema, partition, or canonical identity; this is not a
  portable-core or portable-runtime release gate.
- Existing host ingestion, identity, graph, query, and action paths continue when
  the ontology runtime is disabled or unavailable.

## 21. Risks and Mitigations

| Risk | Mitigation |
| --- | --- |
| The engine becomes a generic low-code platform before its model is stable. | Keep V1 exclusively semantic and require separate proposals for actions, policies, functions, and workflows. |
| Portable abstractions collapse to the first host's architecture. | Enforce zero host imports/vocabulary, ship the in-memory adapter, use multi-domain fixtures, and require adapter conformance. |
| The ontology duplicates canonical host data or identity. | Require explicit host bindings and identity ports; distinguish runtime-owned semantic objects/links from native host records and caches. |
| Source-specific behavior leaks into a portable layer. | Keep provider names and paths in source contracts, mapping data, fixtures, or host adapters; prohibit provider callbacks and source-name branches in the generic runtime and semantic core. |
| Link mappings are mistaken for resolved relationships. | Make the portable runtime the sole `ResolvedLink` authority; require endpoint identity, source policy, cardinality, and revision checks before materialization. |
| Ontology evolution silently changes historical meaning. | Use immutable definition versions, coherent releases, version-pinned queries/evidence, compatibility reports, and explicit migration or rollback. |
| Adapter transaction models produce partial state. | Specify atomic-visibility semantics, idempotency, fencing, reconciliation, and failure-injection conformance tests. |
| Query abstraction permits unbounded backend work. | Require declared query capabilities, compile-time validation, traversal/page limits, adapter cost rejection, and keyset pagination. |
| Provenance and protected evidence leak source data. | Apply monotonic taint, separate protected/redacted artifacts, host authorization, finite retention, and negative inference tests. |
| Runtime work harms host availability. | Enforce fixed limits, asynchronous delivery, bounded concurrency/backfill, execution-class requirements, and failure isolation from established host paths. |
| Action or workflow semantics creep into mappings. | Permit only object candidates, property/link proposals, and owned retraction proposals; reject kinetic declarations in portable V1. |

## 22. Open Decisions Before Their Applicable Maturity Gate

Items 1 through 5 must be resolved before approval of the proposal that depends
on them. Item 6 is required only before a general cross-host portability GA claim.

1. What package and crate names will identify the portable project independently
   of the current ServiceRadar repository and branch name?
2. Which language bindings beyond Rust are required for V1, and which are allowed
   to remain generated from the normative JSON/CBOR vectors after V1?
3. What is the minimal host capability descriptor for storage, identity, query,
   classification, transaction visibility, and link materialization?
4. Which ontology modules and multi-domain fixtures form the release conformance
   corpus without becoming normative product vocabulary?
5. What protected-evidence retention range and build-retention policy must every
   production adapter support for exact replay?
6. Before general cross-host portability GA, which independently maintained,
   production-supported, non-SQLite adapter will serve as the portability gate,
   and who owns its long-term conformance runs? This does not block standalone V1
   or approval of the portable core and runtime proposals.

## 23. Approval Gate

This PRD and its three ordered OpenSpec changes authorize design and review only.
Implementation begins per proposal after that proposal is validated, reviewed,
and approved. The portable runtime depends on the approved core contract. The
ServiceRadar adapter depends on both portable proposals and may not move
ServiceRadar vocabulary or authority into them.

Approval does not authorize action or policy types, action planning or dispatch,
workflow or state-machine execution, arbitrary function plugins, authorization
replacement, generated applications, tenant-authored code, or migration of an
existing host authority. Each requires a separate proposal and explicit adapter
contract.
