## 1. Artifact and source contracts

- [ ] 1.1 Implement runtime-owned `SourceContract`, `SourceSchema`,
  `MappingArtifact`, exact aggregate `MappingDeployment`, and validated
  `RuntimeConfigurationPin` digest with opaque `host_configuration_revision` and
  port-capability digest; own no activation.
- [ ] 1.2 Implement bounded source records, homogeneous lists, tagged unions,
  strict unknown-field behavior, and canonical source envelopes.
- [ ] 1.3 Implement immutable `SourceContract` IDs/versions, stable record/field
  IDs, revision/reset contract, four ingestion modes, completeness/absence,
  classification floor, allowed targets, payload-control rejection, and opaque
  unselectable extras.
- [ ] 1.4 Implement the pure mapping compiler and evaluator producing
  `ObjectCandidate` with exact type version and typed key components, no object ID
  or association revision, plus endpoint keys and relationship records.
- [ ] 1.5 Enforce static and evaluated mapping limits with no partial plan.

## 2. Object and identity lifecycle

- [ ] 2.1 Implement the exact source-coordinate tuple, host-attested scope/epoch,
  tagged sequence/event coordinates, lineage-only sequence supersession, event
  immutability, no-op retry, and mismatch quarantine.
- [ ] 2.2 Implement identity admission before source-owned `ObjectObservation`,
  ambiguity/rejection with no object, stable type ID and exact type-version pins,
  multi-source existence, `ResolvedObject`, retractions, and final-evidence
  tombstones.
- [ ] 2.3 Implement monotonic association revisions, merge/split alias and
  reassociation records, dependency invalidation, and deterministic rebuild.
- [ ] 2.4 Add lifecycle tests for multi-source removal, resurrection, type change,
  stale plans, merge, split, and endpoint reassociation.

## 3. Authority and deterministic resolution

- [ ] 3.1 Implement exact `SourceAuthority` contract/instance selectors, semantic
  targets/existence, confidence ppm, half-open valid/known authority intervals,
  classification floor, output quota, `max_age_us`, and resolution class.
- [ ] 3.2 Implement exact candidate eligibility, missing/null behavior,
  `valid_at` half-open microsecond freshness independent of `known_at`,
  source-owned retractions, and provenance traces.
- [ ] 3.3 Implement `single_authority`, `precedence`, `latest_valid`,
  `highest_confidence`, `union_set`, and `reject_conflict` exactly as specified.
- [ ] 3.4 Add golden cases for sequence prepass, unordered events, no evidence,
  semantic ties, null, ppm confidence, valid-from ranking, set ordering,
  property/link policy restrictions, and retraction ownership.

## 4. Runtime-authoritative relationships

- [ ] 4.1 Implement `link_type_version_id` direct link identity, inverse roles,
  simple and multiedge discriminators, equal-observation provenance coalescing,
  endpoint resolution, and distinct-identity cardinality conflicts.
- [ ] 4.2 Implement relationship-object existence, typed endpoint observations,
  and role-addressable `ResolvedLink` projections.
- [ ] 4.3 Reject object-reference properties as traversable links and reject
  evaluator store joins.
- [ ] 4.4 Implement link invalidation on tombstone, merge, split, reassociation,
  authority change, and release change.
- [ ] 4.5 Publish a materialization contract proving host graphs are disposable
  caches and never semantic link authority.

## 5. Atomic store, replay, and queries

- [ ] 5.1 Implement `RuntimeConfigurationPin` digest, release, artifact, deployment,
  authority, resolution, association, cursor, scope, and idempotency fences.
- [ ] 5.2 Implement deterministic historical replay with exact artifact, envelope,
  resolver, clock, and scope inputs and non-replayable evidence diagnostics.
- [ ] 5.3 Implement `valid_at` and `known_at` semantic queries over types,
  interfaces, properties, direct links, and relationship objects.
- [ ] 5.4 Implement value/null/absent predicates and bucket order, canonical-ID
  tie-breaks, exact scalar comparators, pin-bound typed keyset cursors, production
  host and SQLite local seals, exact authorized snapshot count, and the exact
  256-node/8-traversal/1,000-page bounds and cost budgets.
- [ ] 5.5 Reject aggregates, approximate counts, recursive traversal, changed
  cursors, partial pages, and semantic weakening in V1.

## 6. Ports and reference adapter

- [ ] 6.1 Define transaction, store, authorization, clock, audit, protected-
  evidence, and optional external-identity ports with opaque host values and a
  port-capability descriptor; exclude concrete host activation.
- [ ] 6.2 Implement deterministic in-memory ports for conformance and failure
  injection, clearly labeled non-durable reference behavior.
- [ ] 6.3 Add atomicity, authorization-before-read, audit-redaction, replay, and
  unsupported-capability tests.

## 7. Production SQLite adapter

- [ ] 7.1 Implement the independent `portable-ontology-sqlite` crate with WAL,
  foreign keys, serialized writes, concurrent reads, and `synchronous=FULL`.
- [ ] 7.2 Implement stable-type/key-schema/canonical-key exact identity,
  explicit multi-key association, bitemporal objects and links,
  idempotency, cursors, audit/evidence, and the bounded semantic query executor.
- [ ] 7.3 Implement transactional versioned migrations, newer-schema refusal, and
  explicit destructive export/rebuild.
- [ ] 7.4 Implement SQLite local config, append-only CAS activation, local admin
  CLI, envelope admission, and durable idempotent reconciliation jobs without
  connectors, UI, multitenancy, or fuzzy identity.
- [ ] 7.5 Test kill/restart at every commit and reconciliation boundary plus
  backup, restore, compaction, integrity checks, busy timeout, and recovery.

## 8. Conformance and approval

- [ ] 8.1 Contribute runtime, query, and SQLite sections with exact limits to the
  core-defined manifest schema; assemble one distribution manifest with
  separately reportable subsets.
- [ ] 8.2 Cover neutral reference, security-operations, and textile-certification
  fixtures without runtime domain branches.
- [ ] 8.3 Require SQLite corpus, migration, CLI, reconciliation, and restart gates
  for standalone V1; require an independently maintained production non-SQLite
  public-contract adapter for cross-host portability GA, excluding first-party
  product adapters.
- [ ] 8.4 Document kinetic ontology, actions, policies, workflows, aggregates, and
  additional durable adapters as future proposals, not V1 placeholders.
- [ ] 8.5 Obtain approval before implementation or host integration.
