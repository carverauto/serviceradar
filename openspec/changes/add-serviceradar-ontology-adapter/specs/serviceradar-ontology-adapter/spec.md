## ADDED Requirements

### Requirement: Non-normative replaceable host integration

The ServiceRadar adapter SHALL consume released portable core and runtime
contracts without changing their sources, features, binaries, corpora, or
profile semantics. OCSF, DIRE, AGE, SRQL, Ash, CNPG, NATS, Rustler, plugin, and
deployment-scope types MUST remain inside this adapter. Passing adapter tests MUST
NOT grant a portable profile or satisfy the independent durable-adapter
portability-GA gate.

#### Scenario: Build portable packages without the adapter

- **WHEN** core and runtime are built and tested outside ServiceRadar
- **THEN** all claimed portable vectors pass without a host dependency or feature

#### Scenario: Host type enters a portable contract

- **WHEN** a portable public API names a ServiceRadar system or type
- **THEN** the dependency and vocabulary gate fails before merge

### Requirement: Secret-free BindingManifest and append-only HostActivation

The adapter SHALL keep `BindingManifest` separate from `OntologyRelease`,
`MappingArtifact`, and `MappingDeployment`. An immutable manifest MUST contain
only non-secret credential-reference IDs, transport kind, source-instance
selector, trusted deployment-local scope, mapping-deployment digest, host ports,
and quotas. Bearer tokens, keys, passwords, and resolved secret material MUST stay
outside the manifest, its hash, logs, and portable artifacts and MUST be resolved
out of band after authorization.

Concrete append-only `HostActivation` MUST separately pin manifest digest,
`RuntimeConfigurationPin` digest, opaque `host_configuration_revision`, port-
capability digest, mode, admitted
surfaces, prior activation revision, actor, and time. Modes MUST be `disabled`,
`shadow`, `read_projection`, and `authoritative`; authority MUST apply only to
named object, property, link, or query surfaces. Activation-head promotion and
rollback MUST use compare-and-swap. The runtime MUST receive only the pin request.
With no activation, the adapter MUST be disabled. Unadmitted
surfaces MUST retain existing authority.

#### Scenario: Deploy with no enabled manifest

- **WHEN** adapter code and schemas are installed with default configuration
- **THEN** no consumer, projection substitution, or ontology query surface starts
  and existing behavior is unchanged

#### Scenario: Promote one link projection

- **WHEN** an administrator promotes one named link surface from shadow with the
  expected activation revision
- **THEN** only that surface uses the pinned runtime resolved links

#### Scenario: Credential reference is resolved

- **WHEN** an activated manifest names an authorized credential-reference ID
- **THEN** the secret resolver supplies material out of band without adding it to
  manifest, activation, hash, artifact, log, or runtime configuration

### Requirement: Pure bounded Rustler wrapper

The Rustler wrapper SHALL expose only bounded pure calls for portable artifact
verification, mapping compilation and evaluation, typed validation, identity-
response application, resolution, and semantic-query validation. A NIF MUST NOT
perform Ash, CNPG, AGE, DIRE, SRQL, NATS, filesystem, credential, network, or
plugin I/O. Calls MUST enforce portable limits, choose an appropriate scheduler,
support cancellation, contain panics, quota content-addressed handles, and avoid
creating atoms from untrusted strings.

#### Scenario: Mapping requests external identity

- **WHEN** pure evaluation emits a typed unresolved identity request
- **THEN** Elixir invokes DIRE outside the NIF and supplies a versioned response
  to a later bounded call

#### Scenario: Malformed artifact reaches Rustler

- **WHEN** input is malformed, oversized, corrupt, or uses an unknown required
  field
- **THEN** the call returns a bounded structured error without host I/O, panic,
  atom creation, handle leak, or blocked scheduler

### Requirement: Trusted scope, authorization, and host-store atomicity

The adapter SHALL construct opaque principal and scope only from an authenticated
actor and trusted deployment-local Ash scope. Caller-supplied deployment IDs MUST
NOT select data. CNPG search paths, AGE materialization, SRQL translation,
protected evidence, and audit MUST preserve that scope. Administration, evidence,
replay, mutation, projection substitution, and semantic query MUST have distinct
host authorization checks.

Ash/CNPG ports MUST atomically enforce ontology, mapping deployment, source
authority, resolution, identity, cursor, idempotency tuple, scope, and activation
pins while persisting bitemporal object/link observations, resolved state,
tombstones, protected evidence, and redacted audit. Logs, telemetry, APIs, and
ordinary audit MUST NOT expose protected payloads or identity claims.

#### Scenario: Cross-deployment evidence handle is presented

- **WHEN** an actor supplies a handle owned by another deployment-local scope
- **THEN** authorization fails before retrieval and only a redacted denial is
  audited

#### Scenario: Activation changes before commit

- **WHEN** a plan pins a `HostActivation` revision that is no longer current
- **THEN** no observation, resolved object, resolved link, cursor, or completion
  changes

### Requirement: Complete native source envelopes

Each source adapter SHALL validate its native contract and convert a completed
record, delta, or collection into bounded portable source values. It MUST record
native contract version, source instance, record ID, host-attested reset epoch,
tagged sequence or event revision coordinate, completion proof, cursor, canonical input digest, observed time, valid
time, and sensitivity. Partial pages MUST be staged and MUST NOT assert absence.
Source cursor advancement MUST be atomic with successful runtime mutation.

Cross-record relationships MUST arrive as preassembled bounded envelopes or
explicit relationship records with typed endpoint keys. The runtime evaluator
MUST NOT query ServiceRadar storage to complete a mapping. Provider fields and
native unions MUST remain in host source schemas and mapping artifacts.

#### Scenario: Completed inventory collection is admitted

- **WHEN** every page and digest validates and completion is committed
- **THEN** the adapter submits one logical snapshot boundary that may assert
  source-owned absence

#### Scenario: Relationship requires hidden store join

- **WHEN** native input lacks endpoint keys and mapping would need a store lookup
- **THEN** evaluation is rejected until the adapter supplies an explicit complete
  relationship record

### Requirement: Schema-bound DIRE identity without guessing

The adapter SHALL support exact and binding-local source-scoped identity and MAY
use DIRE as an external identity port. Exact and binding-local identity MUST be
limited to ontology-local object types for which the host has no existing native
identity authority. Bindings to canonical ServiceRadar devices and other
DIRE-governed native types MUST use DIRE. A DIRE request MUST use the target
object type's declared identity-key schema and exact typed components. The
response MUST preserve canonical identity, ambiguity, merge/split reassociation,
and association revision. Ambiguity MUST NOT be guessed. One activated host
configuration MUST NOT mix identity modes for the same object type and
identity-key schema. Changing the identity authority for an existing native type
requires a separately approved migration contract.

#### Scenario: DIRE revises an endpoint through a split

- **WHEN** a split advances the association revision for a linked object
- **THEN** affected resolved objects and links are invalidated until replay pins
  the new decision

#### Scenario: Canonical device binding attempts to bypass DIRE

- **WHEN** a manifest selects exact or binding-local identity for a canonical
  ServiceRadar device type
- **THEN** activation rejects the manifest without admitting observations

#### Scenario: One type declares conflicting identity modes

- **WHEN** an activated configuration would use more than one identity mode for
  the same object type and identity-key schema
- **THEN** activation rejects the configuration with a value-free diagnostic

### Requirement: AGE is a disposable ResolvedLink materialization

The adapter SHALL treat portable runtime and canonical host-store
`ResolvedLink` state as the sole semantic link authority. AGE MUST receive only
already-resolved link ID, type, ordered roles, canonical endpoints, optional
multiedge discriminator, bitemporal bounds, and revision pins. AGE MUST NOT mint
link identity, resolve endpoint keys or conflicts, enforce cardinality, turn an
object-reference property into an edge, or override direct or object-backed
relationship state.

Every graph entry MUST pin its source resolved-link revision. Drift detection
MUST remove unexpected entries and rebuild missing or stale entries from the
canonical store. Dropping and rebuilding AGE MUST preserve all semantic evidence
and query results supported by the canonical store.

#### Scenario: AGE contains an extra edge

- **WHEN** a graph edge has no matching current resolved-link ID and revision
- **THEN** drift repair deletes it and never imports it as semantic evidence

#### Scenario: Rebuild object-backed relationship roles

- **WHEN** AGE is recreated from canonical runtime state
- **THEN** relationship-object role links retain their original semantic link
  IDs, endpoints, discriminator, and time bounds

### Requirement: Exact ordered bitemporal query translation

The adapter SHALL translate an authorized, portable-validated semantic query into
equivalent SRQL, CNPG, and optional AGE operations or return a stable unsupported-
capability code. Translation MUST preserve object/interface constraints, direct
and object-backed roles, `valid_at`, `known_at`, ordered sort terms, canonical-ID
tie-break, value/null/absent predicates and bucket order,
`RuntimeConfigurationPin` digest, typed stable keyset cursor, exact-count mode, deployment
scope, and the 256-node/8-traversal/1,000-page bounds and cost budget. Host
activation and scope MUST seal the portable cursor outside the runtime. It MUST
NOT drop a constraint or substitute approximate,
current-only, offset-pagination, or partial semantics. Existing SRQL calls MUST
remain unchanged without an active manifest.

#### Scenario: AGE cannot satisfy historical knowledge time

- **WHEN** a query requires `known_at` history not present in the graph cache
- **THEN** translation uses canonical CNPG history or returns unsupported, never a
  current graph approximation

#### Scenario: Query budget is exhausted

- **WHEN** host execution reaches the portable cost ceiling
- **THEN** it returns no partial page, approximate count, or successor cursor

### Requirement: Streaming telemetry remains JetStream-first

Metrics, logs, traces, security events, and other streaming telemetry SHALL reach
NATS JetStream before any ontology consumer or persistence path. Durable stream
identity, source-contract version, host-attested reset epoch, tagged sequence or
event coordinate, and input
digest MUST enter envelope provenance and idempotency fences. The adapter MUST NOT
add a collector-to-CNPG or collector-to-ontology-store bypass. Applying a
validated mutation in one host transaction MUST NOT require republishing and
reading that plan back through JetStream.

#### Scenario: Streaming metadata enters a manifest

- **WHEN** a durable consumer receives a bound event
- **THEN** its stream coordinates are pinned before mapping and atomic mutation

### Requirement: Three host fixtures without portable changes

The adapter SHALL test OCSF systems/findings/exposure relationships, SNMP
devices/interfaces/addresses/attachment links, and OpenTelemetry resources,
services/runtime instances/dependency links. Fixtures MUST exercise source
records and unions, exact and external identity, multi-source object existence,
final tombstones, direct and object-backed links, endpoint revisions, all
applicable resolution policies, replay, and ordered bitemporal queries. Core and
runtime source, features, binaries, and corpus outputs MUST remain unchanged.
Neutral and textile-certification portable suites MUST also run to detect host
coupling. These host tests MUST NOT count as normative portable or durability
conformance.

#### Scenario: Run unrelated host fixtures

- **WHEN** all three suites run
- **THEN** only host source schemas, mappings, deployments, manifests, port
  responses, and expected host results differ

### Requirement: Failure isolation and rollback

The adapter SHALL turn admission, mapping, identity, storage, materialization, or
query failure into bounded redacted audit and no partial observation, resolved
state, cursor, activation, or completion. A shadow failure MUST NOT affect
existing reads or writes. An admitted surface MUST follow its explicit fail-
closed manifest and MUST NOT use a semantically weaker fallback. Existing native
ingestion MUST continue when ontology evaluation is unavailable. Rollback MUST
append and CAS a new `HostActivation` in `disabled` or the recorded previous mode
and MUST NOT disable or mutate immutable `BindingManifest`. It MUST restore
recorded previous authority while retaining isolated ontology history.

#### Scenario: Runtime is unavailable in shadow

- **WHEN** a shadow source cannot be evaluated
- **THEN** existing ingestion continues, no shadow cursor advances, and a bounded
  failure is audited

#### Scenario: Roll back one admitted query surface

- **WHEN** an administrator rolls back the current activation head
- **THEN** a new `HostActivation` is CAS-appended in `disabled` or previous mode,
  the manifest remains unchanged, and subsequent calls use previous authority
