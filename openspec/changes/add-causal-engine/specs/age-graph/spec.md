# age-graph Specification

## ADDED Requirements

### Requirement: Bounded Per-Device Risk Summary Scalars

The system SHALL project a small fixed set of per-device risk summary scalars onto the EXISTING `Device` vertex in the `platform_graph` AGE graph, sourced from the `inventory-risk-feed` capability, so that the `causal-reasoning` engine can read device risk during a frozen-graph reasoning tick without dereferencing external storage.

The projected scalars SHALL be limited to: `pkg_worst_severity` (the highest severity band SUPPLIED by `add-cti-signal-coverage` for the device's packages — consumed, not computed here), `pkg_critical_count` (count of critical findings), `pkg_kev_count` (count of Known-Exploited-Vulnerability findings), `pkg_has_unpatched_rce` (boolean), and `pkg_risk_summary_at` (timestamp the summary was computed). All severity/CVSS inputs are consumed from `add-cti-signal-coverage` per Decision 3; this capability performs no CVE matching or CVSS scoring.

The system MUST NOT create `Package` vertices, and MUST NOT create `HAS_PACKAGE` or `AFFECTED_BY` edges (or any per-package edge variant) in `platform_graph`. Per-package vertices and edges would reach roughly 150 million elements at fleet scale and would destroy the cost characteristics of the reasoner's CSR freeze/unfreeze cycle; only the bounded scalar summary is permitted on the `Device` vertex.

#### Scenario: Risk summary scalars upserted onto existing Device vertex

- **GIVEN** the `inventory-risk-feed` capability has computed a per-device risk summary for a device whose canonical id matches an existing AGE `Device` vertex
- **WHEN** the risk summary projection runs
- **THEN** the existing `Device` vertex is upserted in place with `pkg_worst_severity`, `pkg_critical_count`, `pkg_kev_count`, `pkg_has_unpatched_rce`, and `pkg_risk_summary_at`
- **AND** no new vertex is created and no `Device` vertex identity is forked

#### Scenario: Package vertices and per-package edges are prohibited

- **GIVEN** device package inventory exists for thousands of packages per device
- **WHEN** the risk summary projection runs
- **THEN** no `Package` vertex is created in `platform_graph`
- **AND** no `HAS_PACKAGE` or `AFFECTED_BY` edge (or any per-package edge) is created
- **AND** only the bounded scalar summary on the `Device` vertex represents package risk

#### Scenario: Frozen-graph reasoning reads risk scalars in-process

- **GIVEN** the `causal-reasoning` engine has frozen the topology graph for a reasoning tick
- **WHEN** a causaloid evaluates device risk
- **THEN** it reads `pkg_worst_severity` / `pkg_critical_count` / `pkg_kev_count` / `pkg_has_unpatched_rce` directly from the `Device` vertex context
- **AND** it does not require unfreezing the graph or traversing per-package elements

### Requirement: Reverse MANAGES Edge

The system SHALL make the management relationship traversable in the reverse direction in `platform_graph` so that the `causal-reasoning` engine can efficiently answer "which devices does this manager manage" for the management-plane causaloid (C4). This SHALL be satisfied either by projecting an inverse `Device MANAGES Device` edge or by maintaining an index that allows reverse lookup of the existing `MANAGED_BY` relationship.

The reverse traversal SHALL preserve the canonical `sr:`-prefixed device identity on both endpoints and MUST NOT introduce a parallel identity space.

#### Scenario: Reverse management lookup is available to the reasoner

- **GIVEN** a `MANAGED_BY` relationship from a managed device to its manager exists in `platform_graph`
- **WHEN** the `causal-reasoning` engine evaluates the management-plane causaloid (C4) for the manager device
- **THEN** it can enumerate the set of devices the manager manages via a reverse `MANAGES` edge or equivalent reverse index
- **AND** the lookup does not require a full scan of all `MANAGED_BY` edges

#### Scenario: Reverse edge preserves canonical identity

- **GIVEN** both endpoints carry canonical `sr:`-prefixed device ids
- **WHEN** the reverse `MANAGES` edge or index is materialized
- **THEN** both endpoints reference the same canonical `Device` vertex ids as the forward `MANAGED_BY` relationship
- **AND** no new device identity is invented

### Requirement: Capacity Eligibility Contract

The system SHALL derive `capacity_bps` for a canonical topology edge as the minimum non-zero of the two endpoints' interface capacities, where each endpoint capacity is taken from `speed_bps` falling back to `if_speed` in the topology graph projection. An edge for which neither endpoint has a populated capacity SHALL be marked INELIGIBLE for the link-saturation causaloid (C6) by setting `telemetry_eligible` to false; the saturation causaloid SHALL skip ineligible edges rather than treat absent capacity as zero or infinite.

This requirement REFINES (it does not redefine) the existing `capacity_bps` and `telemetry_eligible` fields already owned by the `Canonical Directional Edge Query Shape` requirement: it adds only the capacity-eligibility predicate and the C6 skip obligation, introduces NO new schema column, and leaves the canonical edge query shape unchanged.

#### Scenario: Capacity derived as min-of-both-ends

- **GIVEN** a canonical topology edge whose two endpoint interfaces both report a populated `speed_bps` or `if_speed`
- **WHEN** the topology graph projection computes the edge
- **THEN** `capacity_bps` is set to the minimum non-zero of the two endpoint capacities
- **AND** `telemetry_eligible` is true

#### Scenario: Edge without populated capacity is ineligible for saturation reasoning

- **GIVEN** a canonical topology edge where neither endpoint has a populated `speed_bps` or `if_speed`
- **WHEN** the topology graph projection computes the edge
- **THEN** `telemetry_eligible` is set to false
- **AND** the `causal-reasoning` link-saturation causaloid (C6) skips the edge rather than assuming zero or infinite capacity

### Requirement: Device CONTAINS Component Edge

The system SHALL, as a forward-reference to the `device-components` capability, project structured device components as `Component` vertices in `platform_graph` connected to their owning `Device` vertex by a `Device CONTAINS Component` edge, so that redundancy and component-failure causaloids can reason over substructure once `device-components` lands. Until `device-components` populates component data, the system SHALL project no `Component` vertices and the `Device` vertex SHALL remain the leaf of the containment hierarchy.

#### Scenario: Component vertices projected under owning device

- **GIVEN** the `device-components` capability has emitted structured components for a device whose canonical id matches an existing AGE `Device` vertex
- **WHEN** the component projection runs
- **THEN** each component is projected as a `Component` vertex
- **AND** a `Device CONTAINS Component` edge connects the `Device` vertex to each `Component` vertex

#### Scenario: No component vertices when component data is absent

- **GIVEN** no `device-components` data exists for a device
- **WHEN** topology projection runs
- **THEN** no `Component` vertex and no `CONTAINS` edge are created for that device
- **AND** the `Device` vertex remains the leaf of the containment hierarchy
