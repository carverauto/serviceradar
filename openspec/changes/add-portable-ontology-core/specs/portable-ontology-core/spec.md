## ADDED Requirements

### Requirement: Pure standalone ontology compiler

The ontology core SHALL be a standalone Rust library with zero first-party
dependencies. Its public API and diagnostics MUST use domain-neutral terms and
MUST NOT depend on or perform filesystem, persistence, transport, environment, clock,
random, process, authentication, or authorization operations.
Given the same definitions, compiler contract version, and profile, compilation
MUST return byte-equivalent logical output and ordered diagnostics.

#### Scenario: Host-independent compilation

- **WHEN** two hosts compile the same valid definitions with the same core
  contract and profile
- **THEN** they produce the same logical artifact, effective definitions,
  logical ID, wire hashes, and diagnostic order without consulting host state

#### Scenario: Forbidden dependency enters the core boundary

- **WHEN** a build introduces a first-party host dependency or an I/O-bearing
  public core contract
- **THEN** the core dependency-boundary check fails before publication

### Requirement: Immutable semantic modules, releases, and resource identities

Every ontology resource SHALL have a stable local ID owned by a globally unique
namespace URI in an immutable `OntologyModule`. An `OntologyRelease` MUST pin an
ordered set of module versions, semantic version, profile, declared predecessors,
compiler contract, and canonical logical IDs. Modules and releases MUST contain
only semantic definitions and MUST NOT contain source contracts, mappings,
deployments, runtime configuration, host activation, credentials, or storage
configuration. Published meanings MUST be immutable, and a resource ID MUST NOT
be reassigned to a different concept in a descendant module. All references MUST
resolve within the release or to an explicitly qualified external module version.

#### Scenario: Publish a valid successor

- **WHEN** a release adds a new resource while preserving every predecessor
  resource identity and meaning
- **THEN** the compiler emits an immutable successor with resolved references and
  a new logical ID

#### Scenario: Reassign a published resource ID

- **WHEN** a successor uses an existing resource ID for an incompatible semantic
  concept
- **THEN** compilation fails with a stable resource-reassignment diagnostic

### Requirement: Portable semantic value types

The core SHALL define semantic value types independently of implementation-native
types. `ontology-core-v1` MUST support nullability, boolean, UTF-8 string, signed
64-bit integer, fixed decimal, signed UTC microsecond timestamp, date, signed
microsecond duration, bytes, URI, enumeration, object reference, and bounded
homogeneous list and set representations. Maps, records, and tagged unions MUST
be source-only and MUST NOT be semantic property value types. Constraints MAY
narrow length, numeric range, scale,
enumeration membership, pattern, unit, and collection cardinality. A derived
constraint MUST be equal to or narrower than every inherited constraint. Binary
floating point, implementation-native numbers, unbounded containers, and union-
typed semantic values MUST be rejected.

#### Scenario: Reuse a semantic type across properties

- **WHEN** unrelated property definitions reference one constrained semantic
  value type
- **THEN** the compiler applies the same representation and validation semantics
  to each property

#### Scenario: Derived constraint widens its base

- **WHEN** a derived constraint admits a value forbidden by its base constraint
- **THEN** compilation fails with the resource path and violated constraint

### Requirement: Explicit object identity and title contracts

Every concrete object type SHALL declare at least one stable identity-key schema
and exactly one title property. An identity-key schema MUST have a stable resource
ID, authority URI, and ordered named components with semantic value types and
comparison normalization. It defines resolver input but MUST NOT claim that the
core allocates identities or proves uniqueness. The title property MUST reference
a shared scalar UTF-8 string property. A successor MUST NOT change the meaning,
order, type, normalization, or authority of a published key schema; it MUST add a
new key schema and migration metadata before deprecating the old key.

#### Scenario: Resolve-compatible object definition

- **WHEN** an object type declares a typed identity key and a scalar string title
  property
- **THEN** the artifact exposes a portable resolver-key contract and display
  contract without selecting a resolver implementation

#### Scenario: Published key changes component order

- **WHEN** a successor reorders or changes components under an existing identity-
  key resource ID
- **THEN** compilation fails with an incompatible-key-evolution diagnostic

#### Scenario: Add a replacement identity key

- **WHEN** a successor adds a new key resource, retains the old key during a
  migration window, and supplies migration metadata
- **THEN** the compatibility diff identifies an explicit key migration rather
  than silently changing existing object identities

### Requirement: Shared properties, object types, and abstract interfaces

The core SHALL support reusable property definitions, concrete object types, and
abstract interfaces. A property definition MUST identify its semantic value type,
cardinality, and mutability classification. An interface MAY require property
constraints and link-role constraints and MAY extend multiple interfaces. A
concrete object type MAY implement multiple interfaces. Effective members MUST be
expanded in stable resource-ID order. Incompatible inherited value types,
cardinalities, endpoint roles, or defaults MUST fail compilation unless the
concrete type supplies one explicit refinement satisfying all inherited
constraints. Inheritance cycles MUST fail compilation.

#### Scenario: Object satisfies multiple compatible interfaces

- **WHEN** an object type implements two interfaces whose inherited constraints
  are compatible
- **THEN** the artifact contains one deterministic effective property and
  link-role set for that object type

#### Scenario: Diamond inheritance has incompatible requirements

- **WHEN** two interface paths require incompatible types for the same property
  and the concrete object provides no valid refinement
- **THEN** compilation fails with all conflicting inheritance paths

### Requirement: Direct bidirectional link types

The core SHALL define `LinkType` with direct or object-backed form, simple or
multiedge identity, typed endpoint roles, cardinality, forward and inverse labels,
temporal mode, and compatible resolution-policy kinds. A simple link MUST permit
one logical link for its ordered role/object tuple and MUST have no discriminator.
A multiedge link MUST declare and require a semantic discriminator value type.
Stable link identity MUST be `(link_type_version_id, ordered role/object pairs,
discriminator)`, using a distinguished no-discriminator value for simple links;
it MUST NOT include an ontology-release digest. Forward and inverse traversal
MUST use that same identity. Link types MUST admit only `single_authority`,
`precedence`, `latest_valid`, or `highest_confidence`; property-only `union_set`
and `reject_conflict` MUST be invalid for links.

#### Scenario: Traverse a direct relationship in either direction

- **WHEN** a valid link connects two objects satisfying its endpoint constraints
- **THEN** the same link identity can be projected through its forward and inverse
  roles without duplicating the relationship

#### Scenario: Endpoint violates an interface constraint

- **WHEN** a link endpoint object implements neither the required object type nor
  the required interface
- **THEN** value validation rejects the link with the endpoint role and expected
  constraint

#### Scenario: Multiedge link omits its discriminator

- **WHEN** a multiedge `LinkType` has no typed discriminator schema or an edge
  omits the discriminator value
- **THEN** validation rejects the incomplete link identity

### Requirement: Object-backed relationship types

The core SHALL support object-backed relationship types with a concrete
relationship object and at least two typed endpoint roles. The relationship object
MAY carry identity, properties, provenance, temporal validity, and additional
links. A relationship definition that requires relationship-owned properties
MUST use the object-backed form rather than a direct link.

#### Scenario: Relationship carries domain data

- **WHEN** a relationship needs its own status, issuer, and validity interval
- **THEN** it can be modeled as an object-backed relationship without adding
  special semantics to either endpoint object

#### Scenario: Direct link declares relationship-owned properties

- **WHEN** a direct link definition also attempts to own property values
- **THEN** compilation fails and identifies the object-backed relationship form
  as required

### Requirement: Opaque namespaced extension annotations

Every resource SHALL support optional namespaced canonical JSON extension annotations. The
core MUST preserve unknown annotations through canonical round trips. Extension
annotations MUST NOT change resource identity, semantic value validation,
inheritance, relationship constraints, compatibility classification, or
executable behavior.

#### Scenario: Unknown optional annotation round-trips

- **WHEN** an artifact contains a well-formed annotation in an unknown namespace
- **THEN** decode and re-encode preserve it without changing the effective
  ontology

#### Scenario: Annotation attempts to override core semantics

- **WHEN** an annotation claims a different endpoint constraint than the core
  definition
- **THEN** the compiler ignores it for core semantics and a host MAY reject it in
  separate extension validation

### Requirement: Conservative compatibility and migration classification

The core SHALL compare a release with each declared predecessor and emit an
ordered machine-readable diff classified as additive,
compatible-with-migration, or breaking. Removing or repurposing resources,
incompatible constraint changes, and relationship endpoint changes MUST be
breaking. Releases with compatible-with-migration or breaking changes MUST carry
typed migration metadata naming affected resources and required host operations.
The core MUST validate but MUST NOT execute migrations.

#### Scenario: Add an optional property

- **WHEN** a successor adds an optional property without changing predecessor
  constraints
- **THEN** the diff classifies the change as additive

#### Scenario: Narrow a required value range

- **WHEN** a successor rejects previously valid stored values
- **THEN** the diff classifies the change as breaking and publication fails if
  migration metadata is absent

### Requirement: Canonical artifacts and integrity

The core SHALL define one closed typed logical model with RFC 8785 canonical JSON
and deterministic CBOR encodings. Canonical JSON MUST wrap i64 as
`{"$i64":"<canonical-signed-decimal>"}`, UTC timestamp as
`{"$timestamp_us":"<canonical-signed-decimal>"}`, duration as
`{"$duration_us":"<canonical-signed-decimal>"}`, and fixed decimal as
`{"$decimal":{"coefficient":"<canonical-i128>","scale":0..18}}`.
Timestamp and duration units MUST be signed microseconds; timestamp MUST be Unix
epoch UTC. Numeric strings MUST reject plus signs, exponents, leading zeros,
negative zero, and out-of-range values.

Decimal canonicalization MUST remove trailing coefficient zeros while reducing a
positive scale and MUST normalize every zero to coefficient `"0"`, scale `0`.
Deterministic CBOR MUST use native schema-typed i64 for integer,
timestamp-microsecond, and duration-microsecond values and decimal fraction tag 4
with `[-scale, coefficient]`; coefficient MUST use the deterministic shortest
valid integer or bignum representation for i128.

Date JSON MUST be `{"$date_days":"<canonical-i32>"}` and CBOR MUST be a
schema-typed signed epoch-days i32. Bytes JSON MUST be
`{"$bytes_b64u":"<unpadded-base64url>"}` and CBOR MUST be a native byte string.
URI MUST be validated UTF-8 URI text preserved exactly without Unicode or URI
normalization. Enum MUST be its stable member-ID string. Object-reference JSON
MUST be `{"$object_ref":{"object_id":"<unpadded-base64url>","object_type_id":"<stable-id>"}}`
and CBOR MUST be `[stable_object_type_id, object_id_bytes]`. Lists MUST preserve
declared order. Sets MUST deduplicate and sort by deterministic-CBOR element bytes.

The logical contract ID MUST equal SHA-256 over the exact deterministic CBOR array
`["portable-ontology-v1", contract_kind, contract_version, payload]`.
`contract_kind` MUST match `[a-z][a-z0-9._-]{0,63}` and `contract_version` MUST be
u32.
Canonical JSON and deterministic CBOR bytes MUST each have a separate wire-byte
SHA-256 that is not the logical ID. UTF-8 strings MUST retain their exact Unicode
scalar sequence without normalization. Unknown or duplicate fields MUST fail
closed before ID verification except keys inside the explicit namespaced
extension map. Resource arrays, inherited members, diagnostics, JSON object keys,
and CBOR maps MUST use their specified deterministic order.

#### Scenario: Cross-encoding equivalence

- **WHEN** one compiled release is encoded as canonical JSON and deterministic
  CBOR
- **THEN** both decode to the same logical payload and report one logical ID plus
  their distinct wire-byte hashes

#### Scenario: Artifact content is modified

- **WHEN** any integrity-covered logical field changes without a new logical ID
- **THEN** verification rejects the artifact before use

#### Scenario: Equivalent-looking Unicode has different code points

- **WHEN** two strings render similarly but have different Unicode scalar
  sequences
- **THEN** the compiler preserves the two sequences and their logical IDs
  remain distinct

#### Scenario: Decoder sees an unknown core field

- **WHEN** an integrity-covered resource contains an unknown field outside its
  extensions container
- **THEN** decoding fails without verifying a projection that discarded the field

#### Scenario: Decimal has trailing zeros

- **WHEN** decimal coefficient `1200` and scale `2` are admitted
- **THEN** the logical value and both canonical encodings use coefficient `12`
  and scale `0`

#### Scenario: Golden contract vector is evaluated

- **WHEN** a conformance runner evaluates an exact logical-model vector
- **THEN** canonical JSON bytes, deterministic CBOR bytes, logical ID, and both
  wire-byte hashes match the vector exactly

#### Scenario: Set arrives in different orders

- **WHEN** two set values contain equal elements in different input orders
- **THEN** both deduplicate and sort by deterministic-CBOR element bytes to the
  same logical value, encodings, and ID

#### Scenario: Object reference is encoded

- **WHEN** a typed object reference contains stable type ID and object-ID bytes
- **THEN** its exact JSON wrapper and CBOR pair match the golden vector

### Requirement: Bounded independently claimable profiles and conformance corpus

The core SHALL define one V1 conformance-manifest schema and contribute only
`portable-base-v1` and `ontology-core-v1` sections. Runtime and adapters MUST
contribute their owned sections, and a distribution MUST assemble one manifest.
Core ceilings MUST be exactly 64
namespaces, 256 interfaces, 1,024 property definitions, 1,024 object types, 2,048
link types, inheritance depth 8, 8 directly implemented interfaces per object,
256 effective properties and 256 effective link roles per object, 4 KiB per
string, 1,024 elements per collection, 64 KiB annotations per resource, and 16
MiB per artifact encoding. A component claim MUST name each passed profile and
corpus version and MAY report a subset without implying another profile.

A conforming implementation MAY admit lower limits but MUST NOT change semantics
or exceed a claimed profile. The language-neutral corpus MUST contain exact JSON
and CBOR bytes, logical IDs and wire hashes, numeric boundaries, decimal
normalization, UTC microseconds, date days, duration, bytes, URI, enum, object
reference, list order, set deduplication/order, contract-kind/version boundaries,
Unicode cases, duplicate and unknown fields, effective types, diffs, migrations,
base/core manifest sections, and positive and negative diagnostics. It MUST
contain no implementation-native serialization.

#### Scenario: Definition exceeds a portable ceiling

- **WHEN** a release exceeds any claimed profile limit
- **THEN** compilation fails with a stable limit code and resource path before
  artifact publication

#### Scenario: Independent implementation claims conformance

- **WHEN** an implementation runs the complete corpus
- **THEN** it reproduces the expected logical values, ordering, logical IDs,
  classifications, and diagnostic codes for every required vector

#### Scenario: Implementation claims only the core capability

- **WHEN** an implementation passes `portable-base-v1` and `ontology-core-v1`
  but has no runtime or durable-store adapter
- **THEN** it may claim those two profiles but MUST NOT claim runtime, durable-
  store, or general-availability portability

#### Scenario: Runtime section is assembled

- **WHEN** a distribution adds runtime, query, or store profile sections
- **THEN** it assembles them into the core-defined manifest without making the
  core own those section schemas or gates
