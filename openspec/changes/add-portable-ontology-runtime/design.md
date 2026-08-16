## Context

The ontology core compiles semantic releases but knows nothing about source
records, object existence, identity services, competing evidence, persistence, or
queries. The runtime supplies those portable semantics behind replaceable ports.
A security analytics service, a textile-certification service, and an embedded
SQLite application must interpret the same observations and links identically.

## Goals / Non-Goals

### Goals

- Convert bounded source envelopes into deterministic semantic mutation plans.
- Make object and link existence, identity, time, provenance, retraction, and
  multi-source resolution exact.
- Keep semantic link authority in the portable runtime rather than a host graph.
- Support atomic replayable stores through portable contracts and a production-
  supported SQLite implementation.
- Query types, interfaces, properties, and relationships with stable pagination
  and cost behavior.
- Prove portability across unrelated domains and durable crash recovery.

### Non-Goals

- Provider-specific field names, parsers, identity heuristics, or code branches.
- Store lookups during mapping evaluation or unbounded cross-record joins.
- Making a host graph the canonical semantic relationship store.
- Aggregates, subscriptions, recursive queries, or approximate counts in V1.
- Kinetic ontology, actions, policies, workflows, or external execution.

## Decisions

### 1. Runtime artifacts stop before concrete host activation

The runtime owns `SourceContract`, `SourceSchema`, mapping language/compiler and
evaluator, `MappingArtifact`, `MappingDeployment`, candidates, observations,
resolution, queries, ports, and SQLite. A mapping artifact pins one source-
contract version, source schema, ontology release, mapper contract, profile, and
compiled mapping. A `MappingArtifact` pins exactly one source-contract version and
schema and exactly one ontology-release digest. An immutable `MappingDeployment`
pins exactly one mapping artifact, one `SourceAuthority` revision,
`source_binding_slot`, output-ownership namespace, quotas, and downward-only
limits. It contains no concrete source instance, resolution binding, generation,
mode, or activation state and cannot activate itself.

Concrete `BindingManifest` and `HostActivation` are host-adapter state, never
portable artifacts. A host constructs a `RuntimeConfigurationPin` request with
exact ontology release, deployment set, resolution bindings, opaque
`host_configuration_revision`, and port-capability digest. Runtime validates all
known fields, compares the opaque fence, and computes the pin digest, but owns no
activation state. It cannot inspect host
credentials, transports, rollout mode, or activation history. SQLite owns its
separate local configuration and activation state.

### 2. Source values may be richer than semantic property values

Each immutable `SourceContract` version gives stable IDs to its contract, record
kinds, and declared fields; pins `SourceSchema`, allowed sequence/event revision
coordinate, reset semantics, ingestion mode, classification, and allowed semantic
targets. Modes are event, delta, per-object snapshot, and complete collection.
Only complete-collection mode can infer collection absence after a verified
completion boundary; per-object snapshot can infer absence only inside that
record's owned output lineage; event and delta require explicit retraction.
Payload fields can never select host scope, authorization, ontology release,
mapping deployment, source authority, or canonical object ID.

`SourceSchema` supports portable scalars plus source-only bounded records,
homogeneous lists, and tagged unions. A record has declared fields and rejects
unknown fields unless an explicit bounded extras field exists. A tagged union has
one declared discriminator and exactly one schema-valid variant. Nesting depth is
at most 8, each record has at most 1,024 fields, and each list has at most 1,024
elements.

Mappings project these shapes into core semantic values. They cannot persist a
source-only record or tagged union as an undeclared semantic property value.
Bounded extras are preserved as opaque protected evidence, but no mapping may
select an extra until a later contract version assigns it a stable field ID and
schema. Classification is a floor that mapping outputs cannot lower.

### 3. Mapping is pure, bounded, and cannot query the store

An immutable mapping uses exact selectors, typed deterministic transforms, typed
identity-key templates, and emission templates. It produces `ObjectCandidate`
values with exact object-type version, identity-key schema ID and components,
property candidates, relationship candidates, and retractions. A candidate has
no canonical object ID or association revision. It can iterate only bounded input
collections. No evaluator operator performs I/O, calls host code, or looks up
prior objects or records.

A relationship spanning source records must arrive as a preassembled bounded
envelope or an explicit relationship record carrying typed unresolved endpoint
key references. A host may assemble that input before evaluation, but the input
digest and provenance expose the assembly boundary.

### 4. Idempotency is a complete source-coordinate tuple

Every record mutation is keyed by
`(opaque_host_scope, source_contract_version_id, source_instance_id, record_id,
reset_epoch, revision_coordinate)`. `revision_coordinate` is tagged as either
`sequence(u64)` or `event_id(canonical bounded bytes)`. The host attests opaque
scope and reset epoch. Sequence coordinates are monotonic per exact source-
instance, record lineage, and epoch. Event IDs are unordered and immutable. The
canonical input hash is stored with the tuple.

An identical tuple and hash returns its committed result. An identical tuple with
different content is quarantined as corruption. A higher sequence may supersede
owned earlier outputs only within the exact record/output lineage. An event ID has
no implicit supersession or absence semantics; it requires explicit retractions.

### 5. Object observations explicitly own existence

Identity resolution occurs after mapping. It consumes candidate type version and
typed key components and returns canonical object ID plus association revision.
Only then can admission create `ObjectObservation`, which pins both plus source
authority, source coordinate, valid interval, `known_at`, existence assertion,
properties, and provenance. Ambiguous or rejected identity creates neither
observation nor object. Canonical identity is permanently bound to one stable
object-type ID, while every observation pins its exact type version. Interfaces
are release-derived and cannot be asserted as concrete types.

`ResolvedObject` is active while at least one eligible, unretracted existence
assertion remains. Each authority can retract only its own evidence. Retraction of
the final eligible assertion creates a final-evidence tombstone; it does not
delete history or recycle identity. Current properties and links cease to be
eligible, while bitemporal queries can still inspect them.

### 6. Identity merges and splits invalidate dependent revisions

Identity associations have monotonic association revisions. A merge or split creates a
new revision and an explicit alias or reassociation set; it never edits previous
observations. Every resolved object, resolved link, and mutation plan pins the
association revision for every participating object.

When a pinned decision is superseded, affected current projections are marked
invalid and withheld until deterministic replay or rebuild produces a revision-
current result. Endpoint reassociation cannot leave a link current under the old
identity decision.

### 7. `SourceAuthority` defines exact eligibility

A versioned `SourceAuthority` pins source-contract version and instance selectors,
allowed semantic targets and existence ownership, optional confidence ppm
`0..1_000_000`, authority valid-time and known-time half-open intervals with
required lower and optional upper bounds, classification floor, output quota,
optional `max_age_us`, and resolution class.
An observation is eligible at `(valid_at, known_at)` only when its mapping
deployment and authority revision are active, its source and resource fall within
that authority, target and existence are allowed, confidence is valid, both query
times fall in authority intervals, classification meets the floor, quota is not
exceeded, its observation valid interval contains `valid_at`, it was known no later
than `known_at`, it is not retracted as of `known_at`, its association revision is
current for that view, its value is schema-valid, and, when `max_age_us` exists,
`valid_at` is in the half-open interval
`[valid_from, valid_from + max_age_us)`. Freshness never compares `known_at`.

Missing input emits nothing. Explicit null is an observation only for a nullable
property. Null is not a retraction. Stale, null, superseded, and retracted
candidates remain available to historical and provenance queries.

### 8. Resolution policies have closed V1 semantics

V1 first supersedes lower sequence coordinates only within the exact
record/output lineage. Event IDs never implicitly supersede. It then supports
exactly:

- `single_authority`: exactly one configured authority may contribute; greatest
  `valid_from` among its eligible candidates wins, and any second authority is a
  configuration conflict.
- `precedence`: the first authority in an ordered list with eligible candidates
  wins; within that authority greatest `valid_from` wins.
- `latest_valid`: greatest `valid_from` wins across eligible candidates.
- `highest_confidence`: greatest integer confidence parts-per-million in
  `0..1_000_000` wins, then greatest `valid_from`.
- `union_set`: union schema-valid elements from every eligible set observation,
  deduplicate by canonical semantic bytes, and sort by those bytes.
- `reject_conflict`: resolve only when every eligible candidate has equal
  canonical semantic bytes; otherwise report conflict.

At the final semantic rank, equal canonical values coalesce and unequal values
conflict. IDs order diagnostics only and never decide a winner. A retraction
removes only its referenced source-owned candidate. No eligible candidate yields
`unresolved_no_evidence`; an unequal tie yields `unresolved_conflict`. For
`union_set`, null alongside a set is a conflict; all-null resolves null only if
the output is nullable. `union_set` and `reject_conflict` are property-only. Link
resolution may use only `single_authority`, `precedence`, `latest_valid`, or
`highest_confidence`, applied per logical link identity.

### 9. The runtime is the sole semantic `ResolvedLink` authority

A direct link identity is
`(link_type_version_id, ordered role-to-canonical-object pairs, multiedge discriminator)`.
Role order comes from the release, so inverse traversal uses the same link ID.
A simple link type forbids a discriminator and allows one logical link per
endpoint tuple. A multiedge link declares a typed discriminator schema and
requires it; equal endpoints with distinct discriminators are distinct links.
Equal eligible observations for the same simple logical identity coalesce with
joined provenance. A distinct logical identity conflicts only when its admission
would violate declared cardinality.

Mapping may emit `UnresolvedEndpointKey` containing expected object type or
interface, identity-key schema ID, and exact typed components. Resolution must
produce current canonical endpoints before link admission. An ordinary
object-reference property is never traversable as a relationship. Cardinality
violations produce explicit unresolved conflicts and never overwrite a link.

Object-backed relationships use a normal relationship `ObjectObservation` plus
typed endpoint observations. Their relationship object owns existence,
properties, and identity; the runtime still derives role-addressable
`ResolvedLink` projections. Direct and object-backed links pin endpoint identity
revisions and are invalidated on endpoint tombstone, merge, split, or
reassociation.

A host graph is only a rebuildable materialization or cache of runtime
`ResolvedLink` records. It cannot mint semantic link IDs, resolve conflicts, or
become the source of truth.

### 10. Atomic mutation is release- and deployment-pinned

A resolved plan pins the exact `RuntimeConfigurationPin` digest, ontology release,
mapping artifact and deployment,
`SourceAuthority`, resolution-policy revisions, identity decisions, expected
source cursor, exact idempotency tuple, and input digest. One transaction checks
authorization and pins, applies observations and retractions, recomputes affected
objects and links, advances the cursor, writes audit completion, and records the
result. Any stale fence makes no partial change.

Replay supplies exact artifacts, envelopes, resolver responses, clock values,
and host-scope token. It must reproduce the same plan or report the first changed
pin; it never silently evaluates under current definitions.

### 11. Queries are explicitly bitemporal and stably ordered

`SemanticQuery` selects concrete types or interfaces, property predicates,
projections, and named direct or object-backed roles. `valid_at` selects domain
validity; `known_at` selects evidence and retractions known at that instant. Both
are required, though `known_at` may be bound once by the clock port at admission.

Every query declares ordered sort terms and a total bucket order for value, null,
and absent. Default bucket order is value, null, absent. `is_absent` means no
resolved property slot; `is_present` includes value or explicit null; `is_null`
means present null; `is_not_null` means present value. Equality to null is
invalid. If sort terms are omitted, object or link ID ascending is the complete
order; otherwise canonical ID is appended as final tie-breaker.

Orderable scalar comparators are exact: boolean `false < true`; string and URI by
unsigned UTF-8 bytes; i64, fixed decimal, timestamp microseconds, epoch date days,
and duration microseconds by numeric value; bytes by unsigned lexicographic bytes;
enum by stable member-ID UTF-8 bytes; object reference by stable object-type ID
then object-ID bytes. Lists, sets, records, maps, and unions are not orderable.

Pagination uses a stable keyset cursor containing query digest,
`RuntimeConfigurationPin` digest, `valid_at`, `known_at`, page size, complete order,
typed last tuple, and last canonical ID. A production host seals activation and
scope outside the portable cursor. SQLite uses an adapter-local authenticated
seal. A cursor with any changed pin is
rejected. `count=none` returns only page count;
`count=exact` returns the authorized total at the same bitemporal snapshot before
pagination and consumes the declared cost budget. Approximate counts and
aggregates are not V1 capabilities.

`semantic-query-v1` permits at most 256 AST nodes, 8 relationship traversals, and
page size 1,000. Static validation estimates nodes, traversals, page size, and
exact-count cost.
Execution charges visited objects, links, candidates, decoded bytes, and output
bytes. Exceeding the budget returns no partial page or successor cursor.

### 12. Portable ports isolate hosts without weakening semantics

Transaction, store, authorization, clock, audit, and optional external-identity
ports use opaque host principal and scope values. Authorization precedes protected
evidence reads, replay, query, or mutation. Redacted audit events reference
protected evidence handles rather than source values. A host adapter may reject
an unsupported optional capability with a stable code but cannot substitute
weaker semantics.

### 13. SQLite/WAL is the production-supported portable adapter

The `portable-ontology-sqlite` crate implements exact-key identity keyed by
`(stable_object_type_id, identity_key_schema_id, canonical_key_bytes)`, atomic
object and link storage, bitemporal history, idempotency, cursors, audits, and the bounded
V1 semantic query executor. It uses SQLite WAL, foreign keys enabled, serialized
writes, concurrent readers, and `synchronous=FULL` by default. External identity
resolution is unsupported unless a host supplies that separate port. Multiple
keys converge only through an explicit persisted association; fuzzy matching is
absent.

The adapter owns `SQLiteLocalConfig` and append-only `SQLiteLocalActivation`, not
portable deployment artifacts. A supported local admin CLI verifies and imports
artifacts, manages configuration and CAS activation, accepts preassembled
envelopes, inspects state, runs reconciliation, backup, restore, and integrity
checks. Durable reconciliation jobs rebuild projections after association,
release, or deployment changes and resume idempotently after restart. V1 has no
connectors, UI, multitenant service, or fuzzy identity subsystem.

Versioned forward migrations run transactionally and refuse an unknown or newer
schema. Destructive migration requires an explicit export/rebuild procedure.
Crash and restart tests kill the process at every declared commit boundary and verify WAL
recovery produces either the complete old state or complete new state, never a
partial mutation. Backup, restore, compaction, integrity check, and bounded busy-
timeout behavior are documented production contracts.

The in-memory adapter remains a deterministic conformance and failure-injection
reference, not the production durability proof.

### 14. Profiles and independent gates qualify portability

Runtime contributes `ontology-runtime-v1`, `semantic-query-v1`, and
`sqlite-store-v1` sections to the core-defined manifest schema; a distribution
assembles one manifest with the core-owned base and core sections. Profiles remain
separately claimable. Fixture corpora contain neutral parties/places,
security operations, and textile certification, including direct and object-
backed relationships, source conflicts, lifecycle, queries, and replay.

An implementation reports exactly which profile and corpus versions it passes.
A standalone V1 runtime distribution requires the SQLite profiles and their
complete corpus, migration, CLI, reconciliation, and restart gates. General
cross-host portability GA additionally requires an independently maintained,
production-supported, non-SQLite adapter using only public portable contracts.
A first-party product adapter cannot count as that independent adapter. Component profile reporting remains
accurate and is not blocked by either distribution gate.

## Risks / Trade-offs

- Pure record-local mapping requires hosts to expose cross-record relationships
  explicitly. This makes hidden joins and provenance visible.
- Final-evidence tombstones preserve correctness but require historical storage.
- Strict conflict behavior may produce unresolved projections more often than
  last-write-wins; operators gain an auditable policy instead of silent loss.
- SQLite serializes writers. Bounded plans and documented busy behavior favor
  predictable embedded production over maximum write concurrency.

## Migration Plan

This is a new capability. Implement artifact separation and source values first,
then lifecycle, authority/resolution, link semantics, mutation/query ports, and
the in-memory corpus. Implement SQLite independently and pass migration, local
CLI, reconciliation, and restart gates before a standalone V1 claim. Require a
separate non-SQLite production adapter before cross-host portability GA. No host
integration is enabled by this change.

## Future Proposals

- Kinetic ontology resources, actions, policies, and workflows.
- Aggregate and recursive semantic queries.
- Additional durable and external-identity adapters.
