## ADDED Requirements

### Requirement: Namespaced topology schema
The system SHALL store topology in Dgraph under namespaced predicates and explicit types so it can share a cluster with other graphs without colliding.

#### Scenario: Predicate prefixes
- **WHEN** the topology schema is applied
- **THEN** every topology predicate is prefixed `device.`, `iface.`, `hop.`, `collector.`, `topo.`, `prefix.`, or `change.`
- **AND** no predicate uses `svc.` or `endpoint.`
- **AND** no unprefixed `id` or `name` predicate is created

#### Scenario: Types present
- **WHEN** schema verification runs on a migrated cluster
- **THEN** types `Device`, `Interface`, `HopNode`, `Collector`, `Service`, `TopologyEdge`, `Prefix`, and `Change` are present
- **AND** `device.id`, `topo.link_key`, `prefix.cidr`, and `change.id` are `@upsert`

### Requirement: Reified property-rich edges
The system SHALL persist topology edges that carry properties as `TopologyEdge` nodes with `topo.src` and `topo.dst` uid edges, not as facet-only `[uid]` links.

#### Scenario: Canonical edge properties survive a round trip
- **WHEN** a canonical topology edge is upserted with confidence, directional flow, `capacity_bps`, and `telemetry_eligible`
- **THEN** a subsequent read returns those properties on the same `topo.link_key`
- **AND** `@reverse` traversal from either endpoint finds the edge

#### Scenario: Idempotent upsert
- **WHEN** the same source/target/interface tuple is projected twice
- **THEN** one `TopologyEdge` exists for that `topo.link_key`
- **AND** confidence and last-observed timestamps are updated in place
- **AND** prior payloads are not stored as additional Dgraph nodes

### Requirement: Dgraph-authoritative topology read model
The system SHALL treat Dgraph canonical topology edges as the only authoritative source for topology rendering and downstream graph consumers.

#### Scenario: Renderer consumes Dgraph edges
- **GIVEN** canonical topology edges are projected in Dgraph
- **WHEN** web topology views are generated
- **THEN** edge construction uses canonical Dgraph adjacency
- **AND** rendering does not require additional identity-fusion heuristics in the UI layer

#### Scenario: Causal hydrator consumes Dgraph
- **WHEN** the causal hydrator loads topology
- **THEN** it queries Dgraph through `in:graph`
- **AND** the edge kinds it reads are `CONNECTS_TO`, `CANONICAL_TOPOLOGY`, `LOGICAL_PEER` and `MANAGED_BY`

### Requirement: Management relationships in Dgraph
The system SHALL project a device's management relationship to Dgraph as a `MANAGED_BY` `TopologyEdge` from the managed device to its management device and an inverse `MANAGES` edge, written by the `management_device_v1` ingestor and not telemetry-eligible. These kinds SHALL NOT be pruned by the mapper stale prune and SHALL NOT appear in the canonical graph or the God View topology view.

#### Scenario: Management pair is stored by kind
- **WHEN** the mapper records that a device is managed by another device
- **THEN** Dgraph holds a `MANAGED_BY` edge from the managed device and a `MANAGES` edge back to it
- **AND** the write does not depend on Apache AGE

#### Scenario: Management edges stay out of canonical reads
- **GIVEN** a `MANAGED_BY` / `MANAGES` pair and a canonical edge between the same devices
- **WHEN** the canonical graph or the topology view is read
- **THEN** only the canonical edge is returned

### Requirement: Canonical directional edge query shape
The system SHALL project and query canonical topology edges from Dgraph in the render-ready directional format God View already consumes.

#### Scenario: Dgraph returns render-ready directional fields
- **GIVEN** canonical topology edges have been reconciled from mapper evidence
- **WHEN** God View requests topology edges
- **THEN** each edge result includes `source`, `target`, `if_index_ab`, `if_index_ba`
- **AND** includes directional telemetry fields `flow_pps_ab`, `flow_pps_ba`, `flow_bps_ab`, `flow_bps_ba`
- **AND** includes `capacity_bps`, `telemetry_eligible`, and evidence metadata fields used for diagnostics

### Requirement: Dgraph is the only topology backend
The system SHALL write and read topology only through Dgraph, with no alternative backend, no backend selector flag, and no implicit fallback, and SHALL report an unconfigured Dgraph endpoint explicitly.

#### Scenario: Topology writes reach Dgraph only
- **WHEN** mapper topology, management relations, risk scalars, config facts, or MTR paths are projected
- **THEN** they are written to Dgraph
- **AND** no Cypher is issued against Apache AGE

#### Scenario: Unconfigured Dgraph is reported, not hidden
- **GIVEN** core starts without a resolvable Dgraph endpoint
- **WHEN** a topology write is attempted
- **THEN** an error naming the missing Dgraph configuration is logged once per transition
- **AND** the write is not redirected to another store

#### Scenario: Helm refuses a release without Dgraph
- **GIVEN** `dgraph.enabled=false` and no `dgraph.external.host`
- **WHEN** the chart is rendered
- **THEN** rendering fails with an error that names both settings

### Requirement: Confidence-aware Dgraph edge lifecycle
The system SHALL maintain topology edges in Dgraph with confidence gating and observation freshness controls applied to mapper evidence.

#### Scenario: Low-confidence links stay off the graph
- **GIVEN** a mapper link candidate labelled `low`
- **WHEN** projection runs
- **THEN** no `TopologyEdge` is created for that candidate
- **AND** the evidence remains in the relational tables

#### Scenario: Stale inferred edge is retracted
- **GIVEN** an inferred edge has no supporting observations within the freshness window
- **WHEN** topology reconciliation runs against Dgraph
- **THEN** the inferred edge is marked stale and removed from canonical Dgraph adjacency
- **AND** direct evidence-backed edges remain unless they are also stale

### Requirement: MTR path projection on Dgraph
The system SHALL project MTR trace paths into Dgraph as `MTR_PATH` `TopologyEdge` nodes between Device or HopNode vertices.

#### Scenario: MTR path edges created from trace data
- **WHEN** an MTR trace result is ingested
- **THEN** for each consecutive responding hop pair, a `MTR_PATH` edge is upserted
- **AND** edge properties include `agent_id`, `avg_rtt_us`, `loss_pct`, `last_seen`, `protocol`
- **AND** hop IPs matching existing Device vertices reuse those vertices
- **AND** hop IPs not matching any known Device create HopNode vertices

#### Scenario: Stale MTR path edges pruned
- **WHEN** an `MTR_PATH` edge has a `last_seen` timestamp older than the configured TTL (default 24 hours)
- **THEN** the edge is removed during the next pruning cycle
- **AND** orphaned HopNode vertices with no remaining edges are also removed

### Requirement: Bounded per-device risk scalars on Dgraph
The system SHALL project the existing bounded per-device risk summary scalars onto the Dgraph `Device` node and SHALL NOT create per-package vertices or edges.

#### Scenario: Risk scalars upserted onto existing Device
- **GIVEN** a per-device risk summary for a device whose canonical id matches an existing Dgraph `Device`
- **WHEN** the risk summary projection runs
- **THEN** the existing `Device` is updated with `pkg_worst_severity`, `pkg_critical_count`, `pkg_kev_count`, `pkg_has_unpatched_rce`, and `pkg_risk_summary_at`
- **AND** no `Package` type, `HAS_PACKAGE` edge, or `AFFECTED_BY` edge is created

### Requirement: Source-agnostic topology projection
The system SHALL project topology evidence from mapper discovery and from parsed network configs into the same Device, Interface, Prefix, and TopologyEdge types, distinguished only by `topo.ingestor` and `topo.evidence_class`.

#### Scenario: Config-declared prefix attaches to the same Device as LLDP
- **GIVEN** mapper LLDP has created a Device and Interface
- **AND** a parsed running-config revision declares an IPv4 prefix on that interface
- **WHEN** the config projector runs
- **THEN** a `Prefix` node for that CIDR is upserted
- **AND** the existing Interface is linked via `iface.prefixes`
- **AND** no second Device identity is created

#### Scenario: Config does not clobber physical backbone
- **GIVEN** a `direct-physical` `CONNECTS_TO` edge from mapper LLDP
- **AND** a config-declared neighbor for the same endpoints
- **WHEN** canonical rebuild runs
- **THEN** the canonical edge remains `direct-physical`
- **AND** the config-declared evidence is retained on the evidence path

### Requirement: Prefix nodes
The system SHALL represent CIDR membership as `Prefix` nodes keyed by `prefix.cidr`, not as unindexed strings on Device.

#### Scenario: Devices in a prefix are reachable from the prefix
- **GIVEN** two interfaces announce `192.0.2.0/24`
- **WHEN** a query starts at that Prefix
- **THEN** `~iface.prefixes` returns both interfaces
- **AND** their owning Devices are the devices in that prefix

### Requirement: Change nodes
The system SHALL represent a proposed or accepted network change as a `Change` node with `change.affects` edges to Device, Prefix, or Interface nodes, and SHALL NOT store ticket comments or config bodies on that node.

#### Scenario: Change affects a prefix
- **GIVEN** a change whose selector is CIDR `192.0.2.0/24`
- **WHEN** the change is projected
- **THEN** a `Change` node exists with that `change.id`
- **AND** `change.affects` includes the Prefix `192.0.2.0/24`
- **AND** no config body predicate is written
