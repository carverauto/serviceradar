# Change: Add an optional ServiceRadar ontology adapter

## Why

ServiceRadar should be able to adopt the portable ontology without turning its
existing internal architecture into the ontology's universal model. A thin,
replaceable adapter can connect current sources, identity, storage, query,
security, and transport systems while preserving the portability of the core and
runtime.

## What Changes

- Add an optional ServiceRadar host adapter that depends on the released portable
  ontology core and runtime.
- Keep every ServiceRadar-specific contract here, including OCSF, DIRE, AGE,
  SRQL, Ash, CNPG, NATS, Rustler, and plugin integration.
- Add a thin Rustler boundary for pure compile, map, validate, resolve, and query
  computation; all host I/O remains outside the NIF.
- Implement ServiceRadar transaction, store, authorization, clock, audit,
  identity, query-translation, and protected-evidence ports.
- Add immutable host `BindingManifest` records containing only non-secret
  credential-reference IDs and append-only CAS `HostActivation` records that
  activate portable mapping deployments for scopes, stores, and rollout modes.
- Keep existing ServiceRadar systems authoritative unless an explicit binding
  opts a narrowly scoped object, property, link, or query projection into
  ontology authority.
- Preserve the architectural rule that streaming telemetry reaches NATS
  JetStream before any ontology consumer or database persistence path.
- Add an explicit Edge Record V1 host boundary that consumes only admitted edge
  events, preserves semantic and physical identities without collapsing them,
  and keeps delivery coordinates, publication identity, and recovery evidence
  out of portable semantic supersession.
- Prove breadth with OCSF security records, SNMP device/interface inventory, and
  OpenTelemetry resource/service metadata fixtures, all using unchanged portable
  core and runtime binaries.
- Treat AGE as a disposable relationship materialization of portable
  `ResolvedLink` state, never semantic authority.
- Disable ingestion, projection substitution, and semantic-query exposure by
  default.
- Keep this adapter non-normative for portable conformance: it proves one host
  integration but does not define core, runtime, or portability-GA semantics.

## Impact

- Affected specs: `serviceradar-ontology-adapter` (new capability)
- Affected code: future optional Rustler wrapper, Elixir host orchestration and
  ports, source bindings, storage/query adapters, and conformance fixtures
- Dependency order: requires approved, released, and conformant
  `add-portable-ontology-core`, then `add-portable-ontology-runtime`
- Edge-source dependency: an Edge Record V1 binding additionally requires the
  applicable `freeze-edge-record-v1-abi` artifacts to pass their final freeze
  gate; other adapter sources do not acquire that dependency
- Existing behavior: unchanged until administrators enable an explicit binding
