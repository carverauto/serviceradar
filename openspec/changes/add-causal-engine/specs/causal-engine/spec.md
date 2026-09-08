# causal-engine Specification

## ADDED Requirements

### Requirement: Engine Placement and Module Boundaries

The system SHALL introduce a new top-level Rust crate `rust/causal-engine`, peer to `rust/srql`, deployed as a single binary in a single pod. The engine SHALL be FUSED: the context hydrator and the reasoner MUST run in-process within the same binary, because DeepCausality requires in-process access to its `Context`. The crate SHALL be organized into the modules `context_hydrator`, `domain_model`, `reasoner`, `emitter`, and `snapshot`. A `ContextStore` trait SHALL sit between the hydrator and the reasoner so that a future split into separate hydration and reasoning processes remains possible without rewriting either side. The engine MUST NOT require a separate standalone hydration service for V1.

#### Scenario: Engine deployed as a single fused pod

- **WHEN** the causal engine is deployed
- **THEN** the hydrator and reasoner SHALL run in the same process and pod
- **AND** the reasoner SHALL access the DeepCausality `Context` in-process without a network hop
- **AND** the binary SHALL expose the modules `context_hydrator`, `domain_model`, `reasoner`, `emitter`, and `snapshot`

#### Scenario: ContextStore trait preserves a future hydrator/reasoner split

- **WHEN** the reasoner reads hydrated state
- **THEN** it SHALL access that state through the `ContextStore` trait rather than a concrete hydrator type
- **AND** swapping the in-process `ContextStore` implementation for a remote-backed one SHALL NOT require changes to reasoner logic

### Requirement: Context Hydration via EmbeddedSrql

The engine SHALL hydrate its causal `Context` using the embedded SRQL query engine (`EmbeddedSrql` from `rust/srql`) against CNPG. On cold start it SHALL load current platform state, it SHALL issue on-demand queries against TimescaleDB continuous aggregates for time-series state rather than streaming hypertables, and it SHALL load topology snapshots from Apache AGE by issuing openCypher through the `graph_cypher` entity. Hydration MUST reuse the existing `EmbeddedSrql::new` / `QueryEngine::execute_query` API and MUST NOT open a parallel database connection path that bypasses SRQL.

#### Scenario: Cold-start hydration loads current state via EmbeddedSrql

- **WHEN** the engine starts with no prior snapshot
- **THEN** it SHALL construct an `EmbeddedSrql` instance and execute queries to load current device, service, and health state
- **AND** it SHALL load the topology snapshot by issuing openCypher through the `graph_cypher` entity into AGE

#### Scenario: Time-series state read on demand from continuous aggregates

- **WHEN** the reasoner needs time-series-derived state during a reasoning tick
- **THEN** the hydrator SHALL query the relevant TimescaleDB continuous aggregate on demand via SRQL
- **AND** it SHALL NOT subscribe to or stream the underlying TimescaleDB hypertables

### Requirement: Live Delta Ingestion

The engine SHALL keep its `Context` current by consuming live deltas from two sources. First, it SHALL run a JetStream subscriber on the EXISTING causal subjects (`signals.causal.>`, `arancini.updates.>`, `siem.events.>`, and the zen-consumer OCSF output). Second, it SHALL subscribe to the app-level state-change-events feed in which core-elx publishes `ocsf_devices`, `service_status`, and `health_events` (and virtualization and AGE-projection) state TRANSITIONS to `signals.state.<table>` subjects. This feed is an APPLICATION-LEVEL change-event feed; the engine MUST NOT consume pgoutput CDC, MUST NOT consume logical replication, and MUST NOT stream TimescaleDB hypertables (those are queried on demand per Context Hydration via EmbeddedSrql).

#### Scenario: Live causal subjects update the Context

- **WHEN** a message is published on `signals.causal.>`, `arancini.updates.>`, `siem.events.>`, or the zen-consumer OCSF output
- **THEN** the JetStream subscriber SHALL apply the delta to the in-process `Context`
- **AND** the change SHALL be visible to the next reasoning tick

#### Scenario: App-level state transitions update the Context

- **WHEN** core-elx publishes a state transition for `ocsf_devices`, `service_status`, or `health_events` to `signals.state.<table>`
- **THEN** the engine SHALL apply the transition to the in-process `Context`

#### Scenario: Hypertable and pgoutput CDC are not consumed

- **WHEN** the ingestion layer is configured
- **THEN** the engine SHALL NOT subscribe to pgoutput or logical replication
- **AND** it SHALL NOT stream TimescaleDB hypertables as a live delta feed

### Requirement: Graph Reasoning via ultragraph

The engine SHALL represent the causal/topology graph using an ultragraph `CsmGraph` in compressed-sparse-row (CSR) form. It SHALL `freeze()` the graph before each reasoning tick and SHALL `unfreeze()` only when the topology actually changes, so reasoning runs against an immutable CSR snapshot. The engine SHALL pin a known-good ultragraph version. The six graph-dependent causaloids (C4, C5, C5b, C7, C8, C9) SHALL gate on the committed Phase-0 upstream ultragraph release that adds `articulation_points`, `bridges`, `is_reachable`, `pathway_betweenness_centrality`, and `unfreeze`; until that release is available the engine MUST NOT enable those six causaloids, and the full causaloid set SHALL ship at launch once the upstream release lands. The structural reasoning behavior of these causaloids is specified in the causal-reasoning capability.

#### Scenario: Reasoning tick runs against a frozen CSR graph

- **WHEN** a reasoning tick begins
- **THEN** the engine SHALL ensure the `CsmGraph` is frozen into CSR form before evaluating causaloids
- **AND** it SHALL `unfreeze()` only in response to an actual topology change

#### Scenario: Graph causaloids gate on the upstream ultragraph release

- **WHEN** the engine is built against an ultragraph version lacking `articulation_points`, `bridges`, `is_reachable`, `pathway_betweenness_centrality`, or `unfreeze`
- **THEN** causaloids C4, C5, C5b, C7, C8, and C9 SHALL be disabled
- **AND** once the committed upstream release is pinned, the full causaloid set SHALL be enabled at launch

### Requirement: Canonical Identity Reuse

The engine SHALL reuse the canonical `sr:`-prefixed entity identifiers produced by `RuntimeGraph.canonical_runtime_id/1`, validated at a single point on ingestion. The engine MUST NOT invent a parallel identifier space. It SHALL treat `ocsf_devices.uid`, the AGE `Device.id`, and `ocsf_events.device.uid` as the same identity for a given device. The engine SHALL handle endpoint-cluster summary nodes: when a device identifier has been summarized into a cluster summary node by the God-View stream, the engine SHALL account for that summarization so that a verdict targeting a clustered device identity is still attributable to a renderable node.

#### Scenario: Canonical identifiers reused across feeds

- **WHEN** the engine ingests state referencing a device from any feed
- **THEN** it SHALL key that state on the canonical `sr:`-prefixed identifier
- **AND** `ocsf_devices.uid`, AGE `Device.id`, and `ocsf_events.device.uid` SHALL resolve to the same engine identity

#### Scenario: No parallel identity space is created

- **WHEN** the engine assigns identities to entities in its Context
- **THEN** it SHALL validate identifiers against the canonical scheme at ingestion
- **AND** it SHALL NOT mint identifiers outside the `sr:` canonical scheme

#### Scenario: Verdict on a clustered device remains renderable

- **WHEN** a verdict targets a device identity that the God-View stream has folded into an endpoint-cluster summary node
- **THEN** the engine SHALL account for the summarization so the verdict is attributable to a renderable node rather than being dropped

### Requirement: Snapshot Persistence and Fast Restart

The `snapshot` module SHALL persist the engine's hydrated `Context` and reasoning state to disk so that a single-pod restart recovers in seconds rather than requiring a full cold-start rehydration. On restart the engine SHALL load the most recent snapshot, then reconcile against live deltas before resuming emission, so that no verdict is emitted from stale state.

#### Scenario: Restart recovers from snapshot in seconds

- **WHEN** the engine pod restarts and a recent snapshot exists
- **THEN** the engine SHALL load the snapshot from disk to restore Context and reasoning state
- **AND** it SHALL resume reasoning in seconds without a full cold-start rehydration

#### Scenario: Live deltas reconciled before emission resumes

- **WHEN** the engine resumes from a snapshot
- **THEN** it SHALL reconcile the snapshot against live deltas accumulated since the snapshot was taken
- **AND** it SHALL NOT emit a prediction signal from stale snapshot state before reconciliation completes

### Requirement: Deferred Scaling and High Availability

The engine SHALL be a single-pod, single-binary deployment for V1. HA via active-passive failover with leader election, graph sharding, and a standalone hydration service are explicit NON-GOALS for V1; the engine MUST NOT depend on any of them to operate. The engine SHALL document the revisit triggers that would justify reopening these decisions (for example, reasoning tick latency exceeding its budget at fleet scale, snapshot restart time exceeding the seconds-class target, or a required availability SLA that single-pod restart cannot meet). Prediction emission semantics and the automation-loop closure consumed downstream are specified in the causal-prediction-signals capability.

#### Scenario: Single-pod operation without HA primitives

- **WHEN** the engine operates in V1
- **THEN** it SHALL run as a single pod and SHALL NOT require leader election, active-passive failover, sharding, or a standalone hydration service
- **AND** fast restart from snapshot SHALL be the V1 availability mechanism

#### Scenario: Revisit triggers documented

- **WHEN** a deferred scaling or HA concern is raised
- **THEN** the proposal SHALL identify the documented revisit triggers (such as tick-latency budget breach at fleet scale, snapshot restart exceeding the seconds-class target, or an availability SLA single-pod restart cannot satisfy)
- **AND** the deferred items SHALL remain explicit non-goals until a revisit trigger is met
