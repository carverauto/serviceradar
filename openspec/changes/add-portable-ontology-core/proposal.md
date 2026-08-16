# Change: Add a portable ontology core

## Why

Teams that ingest operational data need a durable semantic model for objects,
properties, identities, and relationships without first adopting a particular
host's storage, query, or ingestion stack. The model must be reusable in unrelated
domains and portable across host applications and languages.

## What Changes

- Add a standalone, domain-neutral Rust library that compiles immutable
  `OntologyModule` and `OntologyRelease` artifacts without performing I/O.
- Define stable namespaces and resource identifiers, semantic value types,
  shared properties, concrete object types, abstract interfaces, and typed
  relationships.
- Give every concrete object type portable identity-key schemas and an explicit
  scalar string title property.
- Support both direct bidirectional links and object-backed relationships whose
  relationship instances carry properties, identity, provenance, and time.
- Put link form, simple-versus-multiedge identity, typed discriminator schema,
  endpoint roles, and compatible link-resolution kinds in core `LinkType`.
- Define deterministic inheritance and conflict validation for interfaces,
  property constraints, and link constraints.
- Add opaque extension annotations so domains can attach metadata without
  changing core semantics.
- Add release comparison, compatibility classification, and explicit migration
  metadata.
- Define canonical JSON and deterministic CBOR artifacts, content integrity,
  the V1 manifest schema, base/core profile sections, and a language-neutral
  conformance corpus; later layers contribute their own sections.
- Reserve kinetic ontology resources, actions, policies, arbitrary functions,
  and workflows for separately approved future proposals.
- Keep provider adapters, persistence, transport, and authorization out of the
  core.

## Impact

- Affected specs: `portable-ontology-core` (new capability)
- Affected code: future standalone Rust package and language-neutral conformance
  fixtures
- Dependency order: this change is first; `add-portable-ontology-runtime` and
  host adapters depend on its released contracts
- Host impact: none until an optional adapter adopts the library
