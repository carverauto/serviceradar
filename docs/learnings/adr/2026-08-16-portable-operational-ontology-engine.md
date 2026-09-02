# Architecture Decision Record: Adopt a Portable Operational Ontology as the Semantic Integration Boundary

| Field | Value |
| --- | --- |
| Status | Proposed |
| Date | 2026-08-16 |
| Accountable owner | Platform architecture owner; a named individual is required before acceptance |
| Consulted owners | Data, integration, security, product, and causal-engine owners |
| Technical owners | Assigned per proposal; a host-adapter owner is required only if that optional proposal is pursued |
| Tracking issue | [#5004](https://code.carverauto.dev/carverauto/serviceradar/issues/5004) |
| Supersedes | None |
| Superseded by | None |

## Context

ServiceRadar is expanding across SIEM, security analytics, asset intelligence,
IT operations management, and causal analysis while ingesting data from an
increasing number of heterogeneous systems. The same underlying concepts appear
under different names, identifiers, encodings, time models, and relationship
shapes in each source.

The difficult part is no longer only transporting or storing the records. It is
deciding what they mean:

- Which real-world object does a record describe, and which records describe the
  same object?
- What does a relationship mean, which source wins a conflict, and is it current?
- When was a fact true versus when did the platform learn it?
- Which source, mapping, identity decision, and model version produced a result?

Today those decisions are distributed across connectors, OCSF resources, DIRE,
CNPG schemas, AGE projections, SRQL handlers, user interfaces, and analytical
consumers. These systems are useful and should remain, but none provides a
portable, versioned contract for turning arbitrary source evidence into governed
objects, properties, and relationships.

As a result, adding a source or cross-domain concept can become a vertical change
through ingestion, storage, identity, graph, query, authorization, user
experience, and analytics. Each downstream consumer can also develop a different
interpretation of the same source evidence.

The approximate cost shape is therefore:

```text
Current: sources x consumers x repeated semantic integration
Target:  source mappings + consumer adapters + one shared semantic runtime
```

This is an architectural cost model, not a claim that connectors or domain work
become free. The objective is to govern each source-to-ontology interpretation
once and reuse it instead of repeating that interpretation inside every
consumer.

## Decision Drivers

In priority order:

1. Reduce the marginal cost and system-wide scope of onboarding each additional
   source or domain concept.
2. Give SIEM, ITOM, security analytics, inventory, and causal analysis consistent
   object, property, identity, and relationship semantics.
3. Preserve exact provenance, historical-as-known analysis, replay, and safe
   semantic evolution.
4. Keep existing ServiceRadar authorities and established telemetry paths intact.
5. Give the causal engine stable, reproducible, source-independent structural
   context.
6. Prove portability and determinism without turning V1 into a low-code, policy,
   action, or workflow platform.

## Decision

Adopt a portable operational ontology as an additive, explicitly activated
semantic integration boundary.

The ontology will define how heterogeneous source evidence becomes typed,
versioned, provenance-bearing semantic objects and relationships. It will be the
semantic authority only for ontology-owned `ResolvedObject` and `ResolvedLink`
projections. It will not claim authority over every record, identity, graph edge,
query, or analytical conclusion in a host product.

The capability will be delivered in three ordered layers:

1. **Portable ontology core.** A pure, domain-neutral Rust library that compiles
   immutable ontology releases containing value types, properties, object types,
   interfaces, identity-key schemas, and direct or object-backed link types. It
   performs no I/O and contains no ServiceRadar, provider, or industry-specific
   vocabulary.
2. **Portable ontology runtime.** A source-neutral runtime for bounded source
   contracts and declarative mappings, identity requests, observations,
   multi-source resolution, semantic object and link lifecycle, provenance,
   retractions, bitemporal query, replay, and explicit host ports. It includes an
   in-memory conformance implementation and a durable SQLite/WAL standalone
   adapter.
3. **Optional host adapters.** Replaceable integrations that own concrete
   deployment configuration, activation, credentials, ingestion, storage,
   authorization, query execution, and materialization. The first planned host
   adapter is for ServiceRadar, but neither portable layer may depend on it.

The dependency order is:

```text
portable ontology core -> portable ontology runtime -> optional host adapter
```

### Authority Boundaries

The following ownership boundaries are part of the decision:

| Concern | Authority after this decision |
| --- | --- |
| Source acquisition, credentials, transport, and completeness claims | Host connector and host adapter |
| Native OCSF event and device fields | Existing OCSF resources |
| Canonical identity association | Host identity port. Ontology-local types with no native authority may use exact/binding-local identity; bindings to canonical ServiceRadar devices use DIRE |
| Ontology definitions and compatibility | Portable ontology core |
| Source observations and semantic property resolution | Portable ontology runtime |
| Ontology-defined `ResolvedObject` and `ResolvedLink` lifecycle | Portable ontology runtime |
| Native topology relationships | Their existing producers |
| Physical graph storage for ontology links | Host materialization; AGE in ServiceRadar is rebuildable for these links |
| Query execution, indexes, and product query syntax | Host query adapter; SRQL remains ServiceRadar's product surface |
| Authorization, deployment isolation, and host activation | Host |
| Causal, anomaly, risk, or detection inference | The corresponding analytical engine |
| Actions, workflows, notifications, and remediation | Outside ontology V1 |

An ontology object is not automatically an OCSF record, database row, AGE
vertex, or provider record. Those are evidence, host representations, or existing
authorities connected through explicit adapters.

### Architectural Invariants

- Definitions, source evidence, identity association, semantic resolution,
  physical storage, causal inference, and effects remain separate concerns.
- Every compile, mapping, resolution, query, and replay operation is pinned to
  exact immutable versions and configuration revisions.
- Semantic reads distinguish `valid_at` from `known_at` so historical analysis
  does not use information learned later.
- Every resolved property and link retains source, mapping, identity, time, and
  resolution provenance, subject to authorization and retention.
- Mapping and resolution are deterministic, bounded, idempotent, and atomically
  visible at the portable contract boundary.
- Provider names and behavior remain in source contracts, mapping data, fixtures,
  or host adapters. They do not become branches in the portable engine.
- Existing host ingestion, identity, graph, query, telemetry, and effect paths
  continue when the ontology is disabled or unavailable.
- Streaming telemetry remains JetStream-first in ServiceRadar. The ontology is
  not inserted synchronously into metric, log, flow, trace, or event hot paths.
- V1 is semantic only. Actions, policies, functions, workflows, state machines,
  generated applications, and effect execution require separate decisions.

## Business Rationale

This decision makes every additional source more valuable to the whole platform
instead of increasing the integration burden of every team.

Expected near-term leverage includes:

- onboarding inventory, discovery, cloud, vulnerability, identity, ERP, OT, and
  other sources through shared contracts and mappings;
- reusing one contextual object model across SIEM, ITOM, security analytics,
  inventory, and causal analysis;
- reducing provider-specific code inside downstream analytics;
- explaining facts and relationships back to their exact evidence;
- detecting semantic incompatibility before activation; and
- evolving models through immutable releases, impact analysis, shadowing,
  replay, and rollback.

The portable boundary also preserves future options for separately approved
domain packages, computed semantics, kinetic capabilities, generated application
surfaces, and uses outside ServiceRadar. None is funded or authorized by this
decision.

Portability is not a branding claim. The SQLite/WAL adapter and multi-domain
fixtures prove the standalone V1 product. A general cross-host portability claim
requires an independently maintained, production-supported, non-SQLite adapter
that uses only public portable contracts and passes every applicable profile.

## Causal-Engine Implications

The ontology and causal engine remain separate systems with different jobs:

```text
Ontology:      What exists, what it means, how it relates, and which evidence supports it
Causal engine: What influenced what under explicit temporal and statistical assumptions
```

When source evidence or an authorized declaration exists, the ontology can
represent and reconcile structural context that telemetry alone does not supply:
containment, component membership, service dependencies, redundancy groups,
ownership, capacity, location, vulnerability context, and multi-state health. It
does not discover or synthesize missing structure. The causal engine can then
spend its complexity budget on causaloids, uncertainty, temporal inference,
predictions, and reasoning explanations rather than rebuilding a private
integration and identity platform.

This ADR establishes only the durable boundary between the efforts:

- A semantic relationship such as `depends_on`, `contains`, or
  `communicates_with` is contextual evidence, not proof of causal direction or
  effect. Causal mechanisms, confidence, interventions, predictions, and
  reasoning traces remain causal-engine responsibilities.
- High-rate metrics, flows, logs, traces, and anomaly episodes remain native
  telemetry/event inputs through causal-owned stores or streams. The ontology
  supplies relatively stable structural context.
- Ontology provenance explains where contextual facts came from. It does not
  replace the causal engine's explanation of how those facts produced a result.
- A ServiceRadar causal-ingest adapter may consume versioned ontology projections.
  Portable ontology crates must not depend on `causal-*`, and causal model,
  context, and reasoning crates must not import the ontology runtime
  implementation or SQLite adapter.
- Changing a production causal input authority requires a causal-owned ADR or
  OpenSpec delta. This ADR does not silently replace current SRQL, CNPG, OCSF, or
  native AGE hydration.

That future causal integration decision must define:

- one coherent snapshot envelope covering the ontology release, exact
  `RuntimeConfigurationPin` digest, opaque host-configuration revision,
  projection and identity revisions, native AGE topology revision, relational
  read snapshot or cursor, stream reconciliation watermarks, causal
  model/catalog/build, causal configuration and calibration revision, and the
  applicable `valid_at` and `known_at` coordinates;
- behavior for fractured or stale context, identity/link invalidation, and
  generalized evidence references;
- separate ontology-source and calibrated causal confidence, plus versioned unit
  and numeric conversion;
- replay or statistical-equivalence rules, including stochastic state; and
- prediction lifecycle, feedback-loop exclusion, and intervention semantics;
- per-context-slice shadow, comparison, cutover, and rollback rules that never
  double-count native and ontology materializations.

Causal development does not need to wait for the complete ontology. Reasoning,
causaloids, calibration, emitters, and test harnesses can proceed in parallel.
Ontology-backed causal consumption is an optional validation track, not an
ontology adoption prerequisite.

## Alternatives Considered

| Alternative | Why it was not selected |
| --- | --- |
| Continue source-specific integration | Lowest immediate platform cost, but preserves repeated mappings, inconsistent semantics, difficult replay, and source-by-consumer coupling |
| Expand OCSF into the universal model | Reuses a valuable security standard but forces unrelated operational, ERP, manufacturing, and other domains into that representation |
| Use AGE as the ontology authority | A physical graph does not define identity admission, property resolution, compatibility, bitemporal truth, or complete provenance |
| Put normalization inside the causal engine | Helps one consumer while duplicating semantics elsewhere and conflating contextual relationships with causal claims |
| Build a ServiceRadar metadata/rules/workflow engine | Mixes semantic and kinetic concerns and embeds one host's architecture in the product |
| Define schemas without a runtime | Leaves every host to implement conflict resolution, lifecycle, history, and replay differently |
| Adopt a third-party ontology platform | Does not by itself provide the decided public contracts and authority boundaries and may impose licensing, deployment, governance, or portability constraints |

Replacing the selected portable core or runtime with a third-party platform
requires a superseding ADR and evidence that it meets the same determinism,
portability, security, and conformance requirements.

## Consequences

### Benefits

- Sources map to reusable semantic contracts, while products share governed
  meaning, provenance, historical reconstruction, and evolution behavior.
- The causal engine can consume stable context without owning source integration,
  and other domains can reuse the portable layers without adopting ServiceRadar.

### Costs and Trade-offs

- Initial integrations may take longer while the shared contracts and
  conformance suite are established.
- The platform gains another versioned artifact lifecycle, operational surface,
  and governance responsibility.
- Source mapping, identity ambiguity, and domain modeling remain substantial
  work; provenance and history also increase storage.
- Semantic projection and host materializations are eventually consistent, and
  adapters must meet stricter atomicity, fencing, authorization, cost, and
  recovery contracts.
- V1 does not deliver automated response, workflows, or generated applications.

## Consequences of Not Adopting

- Integration cost compounds as each consumer learns each provider, while
  product surfaces can disagree about identity and relationships.
- The causal engine is likely to become another private metadata and identity
  platform coupled to current source fields, SRQL entities, and AGE labels.
- Corrections can leave stale analytical paths, and historical backtests can use
  knowledge learned after the evaluated period.
- Operators lose consistent reconstruction of facts and conclusions, while every
  new domain adds bespoke schemas, graph labels, query handlers, and joins.
- Reuse outside ServiceRadar and future governed automation become progressively
  more expensive.

## Risks and Mitigations

| Risk | Mitigation |
| --- | --- |
| The effort becomes an open-ended platform project | Keep V1 semantic-only and require separate decisions for kinetics and generated applications |
| ServiceRadar or provider concepts leak into portable code | Prohibit host vocabulary and imports; require multi-domain fixtures and independent adapter conformance |
| The ontology competes with existing sources of truth | Enforce the authority table, opt-in bindings, separate labels, and no implicit fallback or dual-write |
| Semantic governance becomes a bottleneck | Assign owners, publish review expectations, use modular releases, and automate fixture and compatibility review |
| Partial or stale state becomes visible | Require atomic admission, idempotency, activation fences, reconciliation, and failure-injection tests |
| Query, replay, or backfill harms availability | Use fixed ceilings, capability descriptors, deterministic cost rejection, bounded concurrency, and failure isolation from host paths |
| Protected evidence leaks through provenance or explanation | Apply host authorization, monotonic classification, redaction, retention, and negative-inference tests |
| The causal engine mistakes semantic links for causality | Keep separate models, namespaces, provenance, reasoning traces, and feedback-loop controls |
| Portability remains theoretical | Distinguish standalone V1 from cross-host GA; require an independently maintained non-SQLite production adapter before the latter claim |
| The investment does not reduce integration cost | Baseline recent integrations and enforce measurable pilot exit criteria before broader adoption |

## Approval and Incremental Adoption

Three approvals remain distinct:

1. **ADR acceptance** adopts the semantic boundary, authority model, portable
   implementation direction, and semantic-only V1 scope.
2. **OpenSpec approval** separately authorizes implementation of the core,
   runtime, and optional ServiceRadar adapter in dependency order.
3. **Validation gates** authorize standalone release, host shadowing, narrow
   enforcement, and any later cross-host portability claim.

Before accepting this ADR, name its accountable owner and record who will set the
pilot thresholds. Before approving each OpenSpec proposal, assign that layer's
technical owner and resolve the package, binding, capability, conformance, and
retention decisions applicable to that layer. The optional ServiceRadar adapter
does not need an owner before portable-core work may begin.

Before approving a ServiceRadar shadow pilot, select materially different source
classes and at least two downstream consumers, preferably including one outside
causal analysis. Baseline representative recent work and set explicit comparative
thresholds for engineer-days, systems touched, provider-specific branches,
provenance coverage, replay, performance, storage, and host availability. The
pilot must measure a subsequent source added after shared semantics exist; mapping
two initial sources alone does not prove consumer reuse. The decision owner
records the thresholds; this ADR does not invent percentages without baseline
evidence.

Validation proceeds incrementally:

- The core must compile unrelated domain vocabularies with no domain branches and
  pass its canonical, compatibility, cross-architecture, malformed-input, and
  robustness suites.
- The runtime and SQLite/WAL adapter must pass every applicable V1 profile and
  demonstrate source onboarding without a portable-core change, deterministic
  resolution, retraction, bitemporal query, replay, crash recovery, and rollback.
- The optional ServiceRadar adapter begins in shadow mode, preserves JetStream-
  first telemetry, publishes performance and storage evidence, and leaves all
  established paths operational when disabled.
- Narrow enforcement may activate only selected bindings after reconciliation
  and rollback evidence. This ADR does not authorize removal of an existing
  authoritative read or write path.
- A causal read-only proof may run in parallel as one consumer validation. It is
  not a gate for standalone or ServiceRadar ontology adoption.
- General cross-host portability GA requires the independently maintained,
  production-supported, non-SQLite adapter described above; it need not be named
  before accepting this architectural direction.

Failure to demonstrate reuse across materially different sources and domains, or
failure to reduce downstream integration work against the recorded thresholds,
is a stop or redesign signal. It is not justification to expand V1 scope.

## Rollback

During the adoption authorized here, rollback disables the optional adapter or
advances the host-owned activation to a retained prior configuration pin. It does
not rewrite source evidence or semantic history. Existing OCSF, DIRE, native AGE,
SRQL, ingestion, telemetry, analytics, and effect paths remain available because
this ADR authorizes no legacy-path removal.

A future migration that creates an ontology-only consumer must define its own
last-good snapshot, maximum staleness, degraded behavior, prediction suppression,
and fallback or recovery policy. Disabling the adapter after such a migration may
degrade that consumer and cannot be described as transparent continuity.

No destructive migration of an existing host authority is authorized by this
ADR.

Acceptance of this ADR records an architectural direction; it does not authorize
implementation by itself. A later ADR and OpenSpec proposal are required to
change an authority boundary or add causal algorithms, policies, actions,
workflows, tenant-authored code, or generated applications to the ontology
product.

## Related Records

- [Product requirements document](https://code.carverauto.dev/carverauto/serviceradar/src/branch/codex/add-portable-ontology-engine/docs/plans/2026-08-16-portable-operational-ontology-engine-prd.md)
- [Tracking issue #5004](https://code.carverauto.dev/carverauto/serviceradar/issues/5004)
- [Portable ontology core proposal](https://code.carverauto.dev/carverauto/serviceradar/src/branch/codex/add-portable-ontology-engine/openspec/changes/add-portable-ontology-core)
- [Portable ontology runtime proposal](https://code.carverauto.dev/carverauto/serviceradar/src/branch/codex/add-portable-ontology-engine/openspec/changes/add-portable-ontology-runtime)
- [Optional ServiceRadar adapter proposal](https://code.carverauto.dev/carverauto/serviceradar/src/branch/codex/add-portable-ontology-engine/openspec/changes/add-serviceradar-ontology-adapter)
- [Causal-engine integration assessment](https://code.carverauto.dev/carverauto/serviceradar/src/branch/codex/add-portable-ontology-engine/docs/docs/causal-engine-integration-points.md)
- [Active causal-engine proposal](https://code.carverauto.dev/carverauto/serviceradar/src/branch/codex/add-portable-ontology-engine/openspec/changes/add-causal-engine)
