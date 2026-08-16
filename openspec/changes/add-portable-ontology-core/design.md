## Context

Operational platforms commonly begin with provider-shaped records and gradually
accumulate special-case joins. That makes a new source expensive and makes the
semantic model impossible to reuse outside the original product. The portable
ontology core establishes a small semantic kernel that has no knowledge of any
host, provider, persistence backend, query engine, transport, or product.

The core is inspired by object-centric ontology systems, but it is an original,
open contract. V1 models what exists and how concepts relate. Kinetic ontology
resources require separate future proposals so the first portable contract is
not coupled to authorization, execution, or workflow semantics.

## Goals / Non-Goals

### Goals

- Compile deterministic, immutable ontology releases.
- Model reusable properties, concrete objects, abstract interfaces, identity,
  and direct or object-backed relationships.
- Make type and inheritance errors fail at publication rather than at ingestion.
- Provide artifacts and conformance vectors that implementations in other
  languages can consume.
- Bound every V1 structure so validation and compilation have predictable cost.

### Non-Goals

- Reading source systems or mapping source records.
- Persistence, transactions, clocks, transports, authentication, or
  authorization enforcement.
- A storage schema, query language, graph engine, event bus, or extension system.
- Kinetic ontology resources, actions, policies, workflow state machines, timers,
  arbitrary functions, loops, recursion, or general-purpose expression
  evaluation.
- Any vocabulary or dependency from a host application.

## Decisions

### 1. The core is a pure standalone Rust library

The core accepts in-memory definitions and bytes and returns values, compiled
artifacts, diffs, or structured diagnostics. It performs no filesystem,
persistence, transport, environment, clock, random, or process access. It has zero first-party
dependencies and may use only general-purpose third-party crates behind stable
public contracts.

Public names and diagnostic codes use domain-neutral ontology terminology.
Repository placement must not create a dependency from the library back to the
host repository.

### 2. Every definition belongs to an immutable module and release

An `OntologyModule` groups semantic definitions under one globally unique
namespace URI. An `OntologyRelease` pins an ordered set of module versions,
semantic version, profile, predecessor set, and canonical content IDs. Neither
artifact contains source contracts, mappings, deployments, runtime configuration,
host activation, credentials, or storage configuration. Published resource IDs
are never reassigned to a different semantic concept. A correction creates a new
module version and release.

References are either release-local or explicitly qualified by namespace and
release logical ID. The compiler resolves all references before producing an
artifact. Cycles are allowed only where the resource kind explicitly permits
them, such as mutually referential link endpoints; inheritance cycles are never
allowed.

### 3. Semantic values separate meaning from representation

A semantic value type has a stable ID, one portable representation, constraints,
and annotations. `ontology-core-v1` supports nullability plus boolean, UTF-8
string, signed 64-bit integer, fixed decimal, UTC microsecond timestamp, date,
signed microsecond duration, bytes, URI, enumeration, object reference, and
bounded homogeneous list or set representations. Maps, records, tagged unions,
binary floating point, implementation-native numbers, and heterogeneous or
unbounded containers are rejected as semantic property values.

Constraints can narrow length, range, scale, enumeration membership, pattern,
unit, and collection cardinality. A derived constraint must be equal to or
narrower than its base constraint.

### 4. Object identity and display are explicit portable schemas

Every concrete object type declares at least one stable identity-key schema. A
key schema has its own resource ID, an ordered set of named components with
semantic value types and comparison normalization, and an authority URI that
defines the uniqueness domain. It describes resolver input; the core neither
allocates object IDs nor claims that a key is unique. Runtime resolvers consume
the schema and return the canonical object identity.

Published key component meaning, order, normalization, and authority cannot be
mutated. A release adds a new key schema and migration metadata before
deprecating an old one. Each concrete object type also names exactly one shared,
scalar UTF-8 string property as its title property. Sparse observations may lack
a title value, but every object type has a portable display contract.

### 5. Properties are shared definitions and interfaces are structural contracts

A property definition owns its semantic value type, cardinality, mutability
classification, and optional sensitivity and temporal annotations. Object types
reference shared properties; they do not redefine provider-shaped copies.

An interface is abstract and can require properties and link roles. Interfaces
may extend multiple interfaces. Concrete object types implement zero or more
interfaces. Effective constraints are computed in stable resource-ID order.
Conflicting value types, incompatible cardinalities, contradictory endpoint
roles, and ambiguous defaults are compilation errors unless the concrete type
provides one valid explicit refinement.

### 6. LinkType owns relationship form and edge identity

A `LinkType` declares direct or object-backed form, simple or multiedge identity,
typed endpoint roles, cardinality, direction and inverse labels, temporal mode,
and compatible resolution-policy kinds. Direct link roles constrain an object
type or interface. The two directions are projections of one link observation,
not independently stored facts.

A simple link allows one logical link for an ordered role/object tuple and has no
discriminator. A multiedge link declares a semantic discriminator value type and
requires one discriminator. Its stable edge identity contract is
`(link_type_version_id, ordered role/object pairs, discriminator)`, where simple
links use the distinguished no-discriminator value. A release digest never
enters edge identity.

An object-backed link points to a concrete relationship object type and declares
at least two typed endpoint roles. It is used when the relationship needs its own
identity, properties, provenance, lifecycle, or links. The relationship object
and the role-addressable link projection remain distinct semantic concepts. A
compiler diagnostic rejects direct form when relationship-owned properties are
required. V1 link types may admit only `single_authority`, `precedence`,
`latest_valid`, or `highest_confidence`; property-only `union_set` and
`reject_conflict` are invalid for links.

### 7. Extensions are opaque and cannot rewrite core meaning

Definitions may carry namespaced canonical JSON annotations. The core preserves
unknown annotations byte-for-byte through canonical round trips but does not let
them change identity, inheritance, value validation, endpoint constraints,
compatibility, or integrity. A host that understands an extension validates it
separately.

### 8. Release diffs are machine-readable and conservative

The compiler compares a release with declared predecessors and classifies each
change as additive, compatible-with-migration, or breaking. Removing or
repurposing resources, widening accepted writes while narrowing readable values,
incompatible constraint changes, and endpoint changes are breaking. Renames via
stable display metadata are additive; stable IDs never change during a rename.

A compatible-with-migration or breaking release must include typed migration
metadata that identifies affected resources and the required host operation. The
core validates the metadata but does not execute it.

### 9. One typed logical model has two canonical wire encodings

All contracts share one closed typed logical model. RFC 8785 canonical JSON uses
explicit wrappers: i64 is `{"$i64":"<canonical-signed-decimal>"}`;
timestamp is `{"$timestamp_us":"<canonical-signed-decimal>"}`; duration is
`{"$duration_us":"<canonical-signed-decimal>"}`; and fixed decimal is
`{"$decimal":{"coefficient":"<canonical-i128>","scale":0..18}}`.
Timestamp is signed microseconds since the Unix epoch in UTC. Duration is signed
microseconds. Coefficient, i64, timestamp, and duration strings allow `-` only for
nonzero values, forbid `+`, exponents, leading zeros, and negative zero, and must
fit their declared width.

Decimal canonicalization removes trailing coefficient zeros while decrementing
positive scale; all zero values become coefficient `"0"`, scale `0`. Thus
`1200` at scale 2 normalizes to coefficient `"12"`, scale 0. Deterministic CBOR
uses native schema-typed i64 for integer, timestamp-microsecond, and duration-
microsecond fields, and CBOR decimal fraction tag 4 with `[-scale, coefficient]`
where coefficient is an i128 represented by the deterministic shortest valid
integer or bignum encoding.

Date is signed epoch days in the proleptic Gregorian calendar: JSON uses
`{"$date_days":"<canonical-i32>"}` and CBOR uses a schema-typed signed i32.
Bytes use `{"$bytes_b64u":"<unpadded-base64url>"}` in JSON and a native CBOR
byte string. URI is validated UTF-8 URI text preserved exactly without Unicode or
URI normalization. Enum is its stable member-ID string. Object reference JSON is
`{"$object_ref":{"object_id":"<unpadded-base64url>","object_type_id":"<stable-id>"}}`;
CBOR is `[stable_object_type_id, object_id_bytes]`. Lists preserve declared input
order. Sets deduplicate and sort by each element's deterministic-CBOR bytes.

The logical contract ID is SHA-256 over the exact deterministic CBOR array
`["portable-ontology-v1", contract_kind, contract_version, payload]`. It is
independent of input wire encoding. Canonical JSON bytes and deterministic CBOR
bytes each have a separate wire-byte SHA-256 and never substitute for the logical
ID. `contract_kind` must match `[a-z][a-z0-9._-]{0,63}` and
`contract_version` is an unsigned 32-bit integer.

UTF-8 strings preserve their exact Unicode scalar sequence; no decoder, compiler,
or encoder performs implicit normalization. Every structure is closed: unknown
or duplicate fields fail before logical-ID verification except keys inside the
explicit namespaced extension map. Resource arrays sort by fully qualified
resource ID, inherited members and diagnostics use specified stable keys, JSON
objects use RFC 8785 order, and CBOR follows deterministic map ordering. Golden
vectors include exact JSON bytes, CBOR bytes, logical ID, both wire hashes,
contract-kind/version boundaries, every value encoding, URI and Unicode non-
normalization, list order, set deduplication/order, numeric boundaries, decimal
normalization, duplicate and unknown fields, ordering, and corruption cases.

### 10. Profiles are bounded and independently claimable

The core defines the one V1 conformance-manifest schema and contributes only the
`portable-base-v1` and `ontology-core-v1` sections. Runtime and adapters contribute
their own sections, and a distribution assembles one manifest. A component claim
names the subset it passes; support for one does not imply another. An
implementation may configure lower admission limits but cannot raise a ceiling
or change semantics while claiming the corresponding profile.

The core ceiling is 64 namespaces, 256 interfaces, 1,024 property types, 1,024
object types, 2,048 link or relationship types, inheritance depth 8, 8 directly
implemented interfaces per object type, 256 effective properties and 256
effective link roles per object type, 4 KiB per string value, 1,024 elements per
collection, 64 KiB of annotations per resource, and 16 MiB per artifact encoding.

### 11. A language-neutral corpus is the portability gate

The repository will publish source definitions, exact canonical JSON and
deterministic CBOR bytes, logical IDs, wire hashes, effective type expansions,
compatibility diffs, validation diagnostics, exact value encodings, and the
single profile manifest. Corpus records contain no Rust-native serialization. A
conforming implementation must reproduce the expected logical outputs and stable
diagnostic codes.

## Risks / Trade-offs

- Multiple interface inheritance creates complex errors. Stable linearization,
  explicit refinement, and golden conflict vectors make failures reproducible.
- Fixed limits may be too low for a future domain. A future profile can raise
  them without silently changing existing profile claims.
- Canonical encoding rules add implementation work. Exact logical-ID and wire-
  hash vectors prevent language-specific drift.

## Migration Plan

This is a new standalone capability and does not migrate existing product data.
Implementation proceeds by publishing the core crate and conformance corpus,
then allowing the portable runtime to depend on the released artifact contract.
No host integration is enabled by this change.

## Open Questions

- Which neutral governance process assigns well-known namespace URIs used by
  shared public ontologies?
- Should a future profile add localized display metadata to the canonical model,
  or keep all localization in extensions?
- Kinetic ontology, actions, policies, and workflows require separate future
  proposals and are intentionally not open V1 implementation questions.
