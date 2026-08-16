## Context

ServiceRadar is one optional host for the portable ontology, not its architectural
center. Existing identity, storage, graph, query, source, and transport systems
continue independently until a narrow binding opts in. This adapter is not part
of the normative portable standard and cannot satisfy the independent durable-
adapter portability gate.

## Goals / Non-Goals

### Goals

- Connect ServiceRadar sources and infrastructure through public runtime ports.
- Preserve deployment isolation, authorization, bitemporal provenance, audit,
  and sensitive-data handling.
- Keep Rustler pure and bounded.
- Materialize runtime-authoritative objects and links without granting AGE
  semantic authority.
- Demonstrate security, inventory, and observability sources with unchanged
  portable artifacts and binaries.
- Keep all integration disabled by default and independently rollbackable.

### Non-Goals

- Changing portable semantic, mapping, resolution, link, or query behavior.
- Replacing DIRE, AGE, SRQL, Ash, CNPG, NATS, OCSF, or plugins.
- Making a ServiceRadar binding part of `OntologyRelease`, `MappingArtifact`, or
  `MappingDeployment`.
- Kinetic ontology, actions, policies, or workflows.

## Decisions

### 1. This is a non-normative replaceable host adapter

Only this change may name or import ServiceRadar systems. Core and runtime are
consumed through released public contracts and must produce byte-identical corpus
outputs without the adapter. ServiceRadar extension annotations use their own
namespace and cannot change portable behavior or integrity. Passing adapter tests
does not confer a portable profile or portability-GA claim.

### 2. `BindingManifest` and `HostActivation` are distinct append-only host state

A ServiceRadar `BindingManifest` is immutable and selects only non-secret
credential-reference IDs, transport kind, native source-instance selector,
trusted deployment-local scope, portable mapping-deployment digest, host port
implementations, and quotas. Bearer tokens, keys, passwords, and resolved secret
material never enter the manifest, its hash, logs, or portable artifacts; an
authorized host resolver obtains them out of band.

Append-only `HostActivation` records separately pin manifest digest,
`RuntimeConfigurationPin` digest, opaque `host_configuration_revision`, port-
capability digest, mode, admitted
surfaces, prior activation revision, actor, and time. Promotion and rollback use
CAS over the current activation head. The runtime receives the pin request, not
either concrete host record.

Modes are `disabled`, `shadow`, `read_projection`, and `authoritative`.
`authoritative` applies only to named object, property, link, or query surfaces.
The global feature defaults to no activation, and a first activation is
`disabled`. Existing ServiceRadar systems
remain authoritative everywhere not explicitly admitted.

### 3. Rustler exposes bounded pure computation

The wrapper exposes portable artifact verification, mapping compilation and
evaluation, typed validation, identity-response application, resolution, and
semantic-query validation. It performs no Ash, CNPG, AGE, DIRE, SRQL, NATS,
filesystem, credential, network, or plugin I/O. Elixir orchestration obtains
authorized inputs and invokes host ports outside the NIF.

Content-addressed handles are quota-bound and reference-counted. Calls select the
appropriate scheduler, support cancellation, contain panics, and never create
atoms from untrusted strings.

### 4. Trusted scope and host authorization remain outside portable artifacts

Elixir constructs the opaque runtime principal and scope from the authenticated
actor and trusted deployment-local Ash scope. Caller-provided deployment IDs do
not select data. CNPG search paths, AGE materialization, SRQL translation, audit,
and protected evidence preserve the same boundary.

Binding administration, protected evidence, replay, mutation, and semantic query
have separate host authorization checks. Logs, telemetry, APIs, and ordinary
audit contain redacted metadata and protected evidence handles rather than source
payloads or identity claims.

### 5. Source adapters create portable envelopes, not semantics

OCSF ingestion, collectors, telemetry consumers, and plugins validate native
contracts and convert complete records, deltas, or collections into portable
source values. Adapter provenance includes native contract version, source
instance, record ID, host-attested reset epoch, tagged revision coordinate, completion proof, cursor,
input digest, observed time, valid time, and sensitivity.

Partial snapshot pages are staged and cannot assert absence. Cross-record links
are supplied as bounded preassembled envelopes or explicit relationship records
with typed endpoint keys. The runtime evaluator never queries ServiceRadar to
complete a mapping. Provider fields remain only in source schemas and mappings.

### 6. DIRE is an optional external identity port

Exact and source-scoped identity require no DIRE call. A manifest may select a
DIRE-backed external resolver that translates the declared portable identity-key
schema into typed claims and returns canonical identity, ambiguity, and
association revision. It cannot guess ambiguity or mutate the key schema. DIRE stays
authoritative for existing associations outside an admitted manifest.

### 7. Ash and CNPG implement the canonical host store

Ash resources and deployment-isolated CNPG tables implement portable object and
link observations, resolved objects and links, tombstones, bitemporal history,
idempotency tuples, source cursors, protected evidence, and audit. One transaction
enforces release, mapping deployment, authority, resolution, identity, scope,
cursor, and activation pins.

Storage tables are host details and their IDs do not enter portable artifacts.
Merge/split association revisions invalidate affected projections and trigger
runtime replay before they can be current.

### 8. AGE is only a rebuildable `ResolvedLink` materialization

The portable runtime and canonical host store are the sole semantic authority for
direct and object-backed `ResolvedLink` records. AGE receives only already-
resolved link IDs, endpoint roles, discriminators, validity, knowledge time, and
revision pins. It cannot mint link identity, resolve endpoint ambiguity, enforce
cardinality, or turn an object-reference property into an edge.

Every AGE projection records a source resolved-link revision. Drift detection
deletes unexpected graph entries and rebuilds missing or stale entries from the
canonical store. Dropping and recreating AGE must not lose semantic evidence.

### 9. SRQL translation is exact or unsupported

After host authorization and portable query validation, the adapter translates
the complete ordered bitemporal AST into SRQL, CNPG, and optional AGE operations.
It preserves object/interface types, roles, `valid_at`, `known_at`,
value/null/absent order, the `RuntimeConfigurationPin` digest, typed keyset
cursor, exact-count mode, scope, and cost budget. Host activation and scope seal
the portable cursor outside the runtime. Unsupported features
return stable codes; no predicate, time, order, or cost constraint is dropped.
Existing SRQL behavior remains unchanged without an active manifest.

### 10. Streaming telemetry remains JetStream-first

Metrics, logs, traces, security events, and other streaming telemetry publish to
NATS JetStream before an ontology consumer or persistence path. Durable stream
identity, source-contract version, tagged sequence or event coordinate, and input digest become
envelope provenance and idempotency fences. No collector-to-CNPG or collector-to-
ontology-store bypass is added. A validated mutation need not be published and
read back through JetStream within its host transaction.

### 11. Three host fixtures prove breadth without defining portability

Adapter fixtures cover OCSF systems/findings/exposure relationship objects, SNMP
devices/interfaces/addresses/attachment links, and OpenTelemetry resources,
services, runtime instances, and dependency links. They exercise source shapes,
identity, multi-source existence, direct and object-backed links, bitemporal
correction, resolution policies, and ordered semantic queries.

Core and runtime source, features, binaries, and corpus outputs remain unchanged
across fixtures. Neutral and textile-certification portable fixtures also run to
catch host coupling. These tests prove adapter breadth, not normative portable
conformance or durable portability.

### 12. Failure and rollback preserve existing authority

Admission, mapping, identity, storage, materialization, or query failure produces
a bounded redacted audit and no partial observation, resolved state, cursor,
activation, or completion. Shadow failures do not affect product reads. Opted-in
surfaces fail according to their explicit fail-closed manifest and never use a
semantically weaker fallback.

Native ingestion continues if ontology evaluation is unavailable. Rollback
appends and CASes a new `HostActivation` in `disabled` or the recorded previous
mode; it never disables or mutates immutable `BindingManifest`. Historical
ontology evidence remains isolated and auditable.

## Risks / Trade-offs

- Rustler creates scheduler and memory risk; portable bounds, quotas, scheduler
  selection, cancellation, and panic containment mitigate it.
- AGE and SRQL may not support every portable query; explicit unsupported
  responses are safer than approximations.
- Shadow storage duplicates evidence temporarily; per-manifest quotas and
  retention bound the cost.
- Runtime-authoritative links require graph rebuild tooling; that cost prevents
  host graph drift from changing semantics.

## Migration Plan

1. Pass the portable core, runtime, and independent SQLite durable gates.
2. Land ServiceRadar host ports and schemas with the feature disabled.
3. Add all three host fixtures and portable coupling checks.
4. Run one bounded manifest in shadow and compare canonical resolved state.
5. Promote only named read projections after correctness, latency, isolation,
   materialization-rebuild, and rollback gates pass.
6. Append/CAS a rollback `HostActivation`; never mutate the binding manifest.

## Future Proposals

- Kinetic ontology, actions, policies, and workflows.
- Additional host query capabilities and source adapters.
