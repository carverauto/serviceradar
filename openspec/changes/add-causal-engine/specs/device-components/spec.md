# device-components

Gap F (Phase 4). Introduces structured physical component entities beneath devices so the causal engine can reason about intra-device redundancy and component-level failure. This capability supplies the substrate (component rows, per-component health events, AGE containment edges, redundancy groups); causaloid predictions over that substrate land later.

This capability coordinates with `add-device-environmental-snmp-metrics` (the environmental/SNMP collector MUST emit structured component rows, not just scalar gauges) and `add-structured-hypervisor-storage-enrichment` (hypervisor/storage enrichment populates disk and memory_module components). It cross-references `age-graph` (containment projection) and `health-events` (per-component health emission).

## ADDED Requirements

### Requirement: Structured Physical Component Entities

The platform SHALL persist physical device subcomponents as structured rows in a `platform.device_components` table keyed by the composite identity `(device_uid, component_type, component_index)`. The `device_uid` MUST be the canonical `sr:`-prefixed device identity used everywhere else in the platform (the same identity that keys `ocsf_devices.uid` and the AGE `Device.id`); this capability MUST NOT invent a parallel component identity space. `component_type` MUST be a controlled value drawn from the set `psu | fan | temp_sensor | disk | memory_module | nic`. `component_index` MUST be a stable, deterministic ordinal within `(device_uid, component_type)` so the same physical component resolves to the same row across collection cycles. Each row MAY carry a `parent_index` referencing another component of an enclosing `component_type` to express physical nesting (for example a `temp_sensor` whose `parent_index` points at the `psu` it monitors). Each row SHALL carry a `health` field constrained to a controlled value vocabulary aligned with `health-events`.

Component rows SHALL be sourced from the ENTITY-MIB `entPhysicalTable` where available, with per-vendor overlays mapping vendor-specific `entPhysicalClass` / `entPhysicalDescr` patterns into the controlled `component_type` set. When ENTITY-MIB is absent for a device, the platform SHALL synthesize a stable `component_index` from whatever vendor-specific enumeration is available (for example an OID instance index or a sensor name), such that re-collection produces the same index for the same physical component.

#### Scenario: ENTITY-MIB physical entry persisted as a typed component row
- **WHEN** an SNMP collection walks `entPhysicalTable` for a device and discovers an `entPhysicalClass` of `powerSupply(6)`
- **THEN** the platform persists a `platform.device_components` row with `component_type='psu'`, the canonical `sr:`-prefixed `device_uid`, and a `component_index` derived deterministically from the ENTITY-MIB instance
- **AND** re-running the same collection updates that same row in place rather than creating a duplicate

#### Scenario: Nested sensor references its parent component
- **WHEN** a temperature sensor reported by ENTITY-MIB is contained by a power supply entity via `entPhysicalContainedIn`
- **THEN** the persisted `temp_sensor` row sets `parent_index` to the `component_index` of the enclosing `psu` row

#### Scenario: Stable index synthesized when ENTITY-MIB is absent
- **WHEN** a device exposes fan status via a vendor-private MIB but does not implement ENTITY-MIB
- **THEN** the platform applies the per-vendor overlay to classify each fan as `component_type='fan'` and synthesizes a stable `component_index` from the vendor OID instance
- **AND** subsequent collections resolve the same fan to the same `component_index`

#### Scenario: Unrecognized physical class is not persisted as a typed component
- **WHEN** an `entPhysicalTable` entry maps to no member of the controlled `component_type` set
- **THEN** the platform does not create a `device_components` row for that entry rather than coercing it into an arbitrary type

### Requirement: Per-Component Health Events

When a component's health changes, the platform SHALL emit a health event into `health-events` carrying `entity_type='component'` and identifying the component by its `(device_uid, component_type, component_index)` key. The emitted `new_state` value MUST be drawn from the `health-events` controlled enum so that component health shares the same severity ordering as device- and service-level health. Component health events MUST NOT be free text and MUST be deduplicated on state transition (no event emitted when the observed health equals the last persisted health for that component).

#### Scenario: PSU failure emits a component health event
- **WHEN** a `psu` component transitions from a healthy reading to a failed reading
- **THEN** the platform emits a `health-events` event with `entity_type='component'`, the component's `(device_uid, component_type, component_index)` key, and a `new_state` value drawn from the controlled health-events enum

#### Scenario: Steady-state component does not re-emit
- **WHEN** consecutive collections observe the same health value for a given component
- **THEN** no new health event is emitted for that component

#### Scenario: Component health rolls up to the owning device
- **WHEN** a component health event for `entity_type='component'` is persisted
- **THEN** it is associated with the canonical `device_uid` so device-level consumers can correlate the degradation to its parent device

### Requirement: AGE Containment Edges

The platform SHALL project structured components into the `age-graph` topology as `Component` vertices and SHALL connect each `Component` to its owning `Device` with a `CONTAINS` edge directed from `Device` to `Component`. Component vertices MUST be keyed by the canonical `(device_uid, component_type, component_index)` identity so the projection is idempotent across refreshes. Where a component declares a `parent_index`, the projection MAY add a `CONTAINS` edge between the parent `Component` and the child `Component` to preserve physical nesting. This projection MUST follow the existing `age-graph` canonical-schema and idempotent-reset conventions and MUST NOT introduce package or other non-component vertices under this edge type.

#### Scenario: Device-to-component containment edge projected
- **WHEN** a `device_components` row exists for a device already present as an AGE `Device` vertex
- **THEN** the projection creates (or matches) a `Component` vertex keyed by `(device_uid, component_type, component_index)` and a `CONTAINS` edge from the `Device` vertex to that `Component` vertex

#### Scenario: Projection is idempotent on refresh
- **WHEN** the component projection runs again with unchanged component rows
- **THEN** no duplicate `Component` vertices or `CONTAINS` edges are created

#### Scenario: Nested component containment preserved
- **WHEN** a `temp_sensor` component carries a `parent_index` referencing a `psu` component
- **THEN** the projection adds a `CONTAINS` edge from the `psu` `Component` vertex to the `temp_sensor` `Component` vertex

### Requirement: Redundancy Substrate

The platform SHALL model component redundancy groups as the structural substrate for future causal reasoning, represented as a grouping over `device_components` entities (for example, all `psu` components of a device that form a redundant power pair). This substrate is defined so that it can later be expressed as ultragraph hyperedges over component entities; this capability provides the grouping data and its persistence ONLY and MUST NOT emit redundancy predictions or alerts. The redundancy substrate MUST reference components exclusively by their canonical `(device_uid, component_type, component_index)` key and MUST NOT duplicate component state.

#### Scenario: Redundant PSU pair recorded as a redundancy group
- **WHEN** a device exposes two `psu` components that vendor metadata identifies as a redundant power pair
- **THEN** the platform records a redundancy group referencing both components by their `(device_uid, component_type, component_index)` keys

#### Scenario: Substrate emits no predictions in this capability
- **WHEN** one member of a recorded redundancy group transitions to a failed health state
- **THEN** the redundancy substrate records the membership and component health only, and emits no redundancy-loss prediction or alert from this capability

#### Scenario: Substrate shape supports future hyperedge expression
- **WHEN** the causal engine later consumes redundancy groups
- **THEN** each group is expressible as a single hyperedge over its member component entities without requiring a parallel identity or duplicated component state
