# dgraph-topology Specification

## ADDED Requirements

### Requirement: Reasoner-Readable Device Risk Scalars

The system SHALL expose the bounded per-device risk summary scalars, sourced from the `inventory-risk-feed` capability, as predicates on the EXISTING Dgraph `Device` node so that the `causal-reasoning` engine can read device risk during a frozen-graph reasoning tick without dereferencing external storage. The scalars are written by the `dgraph-topology` "Bounded per-device risk scalars on Dgraph" requirement; this requirement adds only the reasoner read contract.

The scalars SHALL be limited to: `device.pkg_worst_severity` (the highest severity band SUPPLIED by `add-cti-signal-coverage` for the device's packages — consumed, not computed here), `device.pkg_critical_count` (count of critical findings), `device.pkg_kev_count` (count of Known-Exploited-Vulnerability findings), `device.pkg_has_unpatched_rce` (boolean), and `device.pkg_risk_summary_at` (timestamp the summary was computed). All severity/CVSS inputs are consumed from `add-cti-signal-coverage` per Decision 3; this capability performs no CVE matching or CVSS scoring.

The system MUST NOT create a `Package` type, and MUST NOT create `HAS_PACKAGE` or `AFFECTED_BY` `TopologyEdge` kinds (or any per-package edge variant). Per-package nodes and edges would reach roughly 150 million elements at fleet scale and would destroy the cost characteristics of the reasoner's CSR freeze/unfreeze cycle; only the bounded scalar summary is permitted on the `Device` node.

#### Scenario: Frozen-graph reasoning reads risk scalars in-process

- **GIVEN** the `causal-reasoning` engine has hydrated and frozen the topology graph from Dgraph for a reasoning tick
- **WHEN** a causaloid evaluates device risk
- **THEN** it reads `device.pkg_worst_severity` / `device.pkg_critical_count` / `device.pkg_kev_count` / `device.pkg_has_unpatched_rce` from the hydrated `Device` context
- **AND** it does not require unfreezing the graph or traversing per-package elements

#### Scenario: Package nodes and per-package edges are prohibited

- **GIVEN** device package inventory exists for thousands of packages per device
- **WHEN** the risk summary projection runs
- **THEN** no `Package` node is created in Dgraph
- **AND** no `HAS_PACKAGE` or `AFFECTED_BY` edge (or any per-package edge) is created
- **AND** only the bounded scalar summary on the `Device` node represents package risk

### Requirement: Reasoner Reverse Management Traversal

The system SHALL let the `causal-reasoning` engine answer "which devices does this manager manage" for the management-plane causaloid (C4) by traversing the `MANAGES` `TopologyEdge` kind that the `dgraph-topology` "Management relationships in Dgraph" requirement writes as the inverse of each `MANAGED_BY` edge.

The reverse traversal SHALL preserve the canonical `sr:`-prefixed device identity on both endpoints and MUST NOT introduce a parallel identity space.

#### Scenario: Reverse management lookup is available to the reasoner

- **GIVEN** a `MANAGED_BY` edge from a managed device to its manager exists in Dgraph
- **WHEN** the `causal-reasoning` engine evaluates the management-plane causaloid (C4) for the manager device
- **THEN** it enumerates the devices the manager manages through the manager's `MANAGES` edges
- **AND** the lookup does not require a full scan of all `MANAGED_BY` edges

#### Scenario: Reverse edge preserves canonical identity

- **GIVEN** both endpoints carry canonical `sr:`-prefixed device ids
- **WHEN** the `MANAGES` edge is read
- **THEN** both endpoints reference the same canonical `Device` nodes as the forward `MANAGED_BY` edge
- **AND** no new device identity is invented

### Requirement: Capacity Eligibility Contract

The system SHALL derive `topo.capacity_bps` for a canonical topology edge as the minimum non-zero of the two endpoints' interface capacities, where each endpoint capacity is taken from `speed_bps` falling back to `if_speed`. An edge for which neither endpoint has a populated capacity SHALL be marked INELIGIBLE for the link-saturation causaloid (C6) by setting `topo.telemetry_eligible` to false; the saturation causaloid SHALL skip ineligible edges rather than treat absent capacity as zero or infinite.

This requirement REFINES (it does not redefine) the `capacity_bps` and `telemetry_eligible` fields already owned by the `dgraph-topology` "Canonical directional edge query shape" requirement: it adds only the capacity-eligibility predicate and the C6 skip obligation, introduces NO new predicate, and leaves the canonical edge query shape unchanged.

#### Scenario: Capacity derived as min-of-both-ends

- **GIVEN** a canonical topology edge whose two endpoint interfaces both report a populated `speed_bps` or `if_speed`
- **WHEN** the topology projection computes the edge
- **THEN** `topo.capacity_bps` is set to the minimum non-zero of the two endpoint capacities
- **AND** `topo.telemetry_eligible` is true

#### Scenario: Edge without populated capacity is ineligible for saturation reasoning

- **GIVEN** a canonical topology edge where neither endpoint has a populated `speed_bps` or `if_speed`
- **WHEN** the topology projection computes the edge
- **THEN** `topo.telemetry_eligible` is set to false
- **AND** the `causal-reasoning` link-saturation causaloid (C6) skips the edge rather than assuming zero or infinite capacity

### Requirement: Device CONTAINS Component Edge

The system SHALL, as a forward-reference to the `device-components` capability, project structured device components as `Component` nodes in Dgraph connected to their owning `Device` node by a `CONTAINS` `TopologyEdge` directed from `Device` to `Component`, so that redundancy and component-failure causaloids can reason over substructure once `device-components` lands. No writer for the `CONTAINS` kind exists yet (GitHub issue #6297). Until `device-components` populates component data and that writer lands, the system SHALL project no `Component` nodes and the `Device` node SHALL remain the leaf of the containment hierarchy.

#### Scenario: Component nodes projected under owning device

- **GIVEN** the `device-components` capability has emitted structured components for a device whose canonical id matches an existing Dgraph `Device` node
- **WHEN** the component projection runs
- **THEN** each component is projected as a `Component` node
- **AND** a `CONTAINS` edge connects the `Device` node to each `Component` node

#### Scenario: No component nodes when component data is absent

- **GIVEN** no `device-components` data exists for a device
- **WHEN** topology projection runs
- **THEN** no `Component` node and no `CONTAINS` edge are created for that device
- **AND** the `Device` node remains the leaf of the containment hierarchy
