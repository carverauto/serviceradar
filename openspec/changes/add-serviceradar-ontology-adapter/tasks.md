## 1. Non-normative adapter boundary

- [ ] 1.1 Consume released core and runtime artifacts without changing their
  source, features, binaries, corpora, or profile semantics.
- [ ] 1.2 Add dependency and vocabulary gates preventing ServiceRadar systems
  from entering portable packages.
- [ ] 1.3 Mark adapter conformance as host-specific and prohibit it from satisfying
  the independent durable portability-GA gate.
- [ ] 1.4 Default the global feature to no activation and the first
  `HostActivation` to `disabled`.

## 2. Binding and Rustler boundaries

- [ ] 2.1 Implement immutable host-only `BindingManifest` with non-secret
  credential-reference IDs, transport, selector, scope, deployment, ports, and
  quotas; prove secret material never enters hashes, artifacts, or logs.
- [ ] 2.2 Implement out-of-band authorized secret resolution and append-only CAS
  `HostActivation` with manifest digest, `RuntimeConfigurationPin` digest, opaque
  host revision, capability digest, modes, prior revision, actor, time, and named
  admitted surfaces.
- [ ] 2.3 Expose bounded pure Rustler calls for verification, mapping, validation,
  identity-response application, resolution, and semantic-query validation.
- [ ] 2.4 Keep all host I/O outside NIF calls and test scheduler selection,
  cancellation, panic containment, malformed input, atom safety, and handle quotas.

## 3. Host ports and isolation

- [ ] 3.1 Construct opaque principal and deployment-local scope only from trusted
  authentication and Ash scope.
- [ ] 3.2 Implement distinct authorization for administration, evidence, replay,
  mutation, projection substitution, and semantic query.
- [ ] 3.3 Implement Ash/CNPG bitemporal object/link store, idempotency tuple,
  tombstone, cursor, protected-evidence, redacted-audit, and atomic fence ports.
- [ ] 3.4 Implement exact and source-scoped identity only for ontology-local
  types without a native identity authority; require schema-bound DIRE identity
  for canonical device and other DIRE-governed bindings while preserving
  ambiguity and merge/split association revisions.
- [ ] 3.5 Reject mixed identity modes for one object type/key schema and test
  canonical-device bypass, cross-deployment isolation, stale pins, replay, audit
  redaction, multi-source existence, final tombstones, and revision invalidation.

## 4. Sources and streaming

- [ ] 4.1 Convert native records, deltas, and completed collections into bounded
  portable source shapes with host-attested scope/epoch, source-contract version,
  tagged sequence/event coordinate, and exact provenance.
- [ ] 4.2 Stage partial snapshots and allow absence only after completion proof.
- [ ] 4.3 Supply cross-record links as preassembled envelopes or explicit
  relationship records; prohibit evaluator store joins.
- [ ] 4.4 Implement JetStream consumers and architecture tests proving no
  streaming telemetry bypass into CNPG or ontology persistence.
- [ ] 4.5 Keep provider fields and plugin contracts confined to host source
  schemas and mappings.

## 5. Links, graph materialization, and query

- [ ] 5.1 Persist runtime-authoritative direct and object-backed `ResolvedLink`
  state with inverse, discriminator, cardinality, endpoint, and identity pins.
- [ ] 5.2 Materialize AGE only from canonical resolved-link revisions and add
  drift detection plus complete drop/rebuild tests.
- [ ] 5.3 Prove AGE cannot mint link IDs, resolve endpoints or conflicts, enforce
  cardinality, or turn object-reference properties into links.
- [ ] 5.4 Translate complete ordered bitemporal queries to exact SRQL/CNPG/AGE
  behavior or stable unsupported responses.
- [ ] 5.5 Test `valid_at`, `known_at`, value/null/absent order, configuration-
  bound typed keyset cursors, host seals, exact counts, fixed query limits, cost
  exhaustion, and no semantic fallback.

## 6. Breadth and rollout

- [ ] 6.1 Add OCSF security, SNMP inventory, and OpenTelemetry service fixtures
  covering object lifecycle, identity, both link forms, source resolution, replay,
  and semantic query.
- [ ] 6.2 Run neutral and textile-certification fixtures to detect host coupling
  while keeping portable binaries unchanged.
- [ ] 6.3 Add bounded shadow comparison, materialization drift, latency, storage,
  isolation, and rollback observability without sensitive values.
- [ ] 6.4 Document enable, shadow, promote, fail closed, disable, AGE rebuild, and
  rollback procedures that append/CAS `HostActivation` and never mutate or
  disable immutable `BindingManifest`.
- [ ] 6.5 Reserve kinetic ontology, actions, policies, and workflows for future
  proposals and obtain approval before implementation.

## 7. Frozen Edge Record V1 boundary

- [ ] 7.1 Define a durable admitted-event handoff that attests the applicable
  frozen edge checks and never makes ontology evaluation part of native
  acceptance, EventWriter commit, delivery, or ACK.
- [ ] 7.2 Bind edge logical event identity to an event-tagged source coordinate
  while preserving producer-receipt, physical-artifact, semantic-envelope,
  payload, delivery/publication, and portable canonical identities in their
  separate evidence namespaces. Pin trusted scope, source instance, record ID,
  and reset epoch independently of delivery coordinates and test cross-scope
  event IDs plus stable reset across recovery.
- [ ] 7.3 Make `HostActivation` select the authorized immutable
  `BindingManifest` before checking the admitted record. Pin the schema-stable
  output-contract identity, preserve the complete `EdgeOutputContractRef` as
  evidence, and prove edge capabilities and disposition cannot select portable
  configuration or ontology authority.
- [ ] 7.4 Reuse the frozen containing-bucket nanosecond-to-microsecond conversion
  only after edge admission, amend the enumerated projection-consumer list in the
  frozen edge timestamp requirement to name the adapter, retain raw nanoseconds
  as typed evidence, and reuse the first recorded `known_at` on duplicate
  delivery.
- [ ] 7.5 Test legal outer re-encoding, edge-ledger semantic conflict,
  producer-receipt absence, agent/service delivery separation, retry and
  recovery rewrapping, conditional loss evidence including an uncovered gap,
  exact portable replay, native translation replayability under retention
  policy, and ontology unavailability.
- [ ] 7.6 Enforce the portable source-envelope and output ceilings without
  truncation, splitting, or raw-artifact duplication, and prove an oversized
  conversion cannot affect native ingestion.
