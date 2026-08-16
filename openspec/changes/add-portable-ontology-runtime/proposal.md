# Change: Add a portable ontology runtime

## Why

An ontology becomes operational when unrelated source records can create,
reconcile, relate, query, retract, and replay semantic objects. Those semantics
must remain independent of a product's providers, graph, storage engine,
transport, or query language.

## What Changes

- Add a portable runtime built only on released ontology-core contracts.
- Own portable `SourceContract` and `SourceSchema`, compiled `MappingArtifact`,
  immutable `MappingDeployment`, observations, resolution, queries, and ports,
  while validating `RuntimeConfigurationPin` with opaque
  `host_configuration_revision` and port-capability digest.
- Add bounded source schemas with source-only records, homogeneous lists, and
  tagged unions plus deterministic mapping into objects, properties, identities,
  direct links, and relationship objects.
- Split mapping `ObjectCandidate` from admitted `ObjectObservation`, then define
  exact identity/type invariants, source ownership, bitemporal provenance,
  tombstones, and merge/split invalidation.
- Make the runtime the sole authority for semantic `ResolvedLink` identity,
  inverse roles, cardinality, endpoint identity, simple-link provenance
  coalescing, and multiedge behavior.
- Add exact `SourceAuthority` eligibility and six deterministic multi-source
  resolution policies.
- Define release-pinned atomic mutation, the complete source idempotency tuple,
  replay, and `valid_at` versus `known_at` queries.
- Add an ordered, bounded semantic query AST with stable keyset cursors and exact
  null, count, and cost semantics; defer aggregates.
- Add portable transaction, store, authorization, clock, and audit ports.
- Ship a production-supported durable SQLite/WAL adapter with exact-key identity,
  local configuration and activation, an admin CLI, reconciliation jobs,
  migrations, bounded query execution, atomicity, and restart recovery. Keep the
  in-memory adapter as a conformance reference.
- Publish base and capability-specific conformance profiles plus neutral,
  security-operations, and textile-certification fixture suites.
- Reserve kinetic ontology, actions, policies, and workflows for future
  proposals.

## Impact

- Affected specs: `portable-ontology-runtime` (new capability)
- Affected code: future portable runtime, in-memory reference adapter, durable
  SQLite adapter, conformance CLI, and language-neutral fixtures
- Dependency order: requires approved `add-portable-ontology-core`; optional host
  adapters depend on this runtime
- Portability claim: standalone V1 requires SQLite profiles; cross-host
  portability GA additionally requires an independently maintained production
  non-SQLite adapter, and a product host adapter cannot satisfy that gate
