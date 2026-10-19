## ADDED Requirements

### Requirement: Devices Expose Canonical Availability State
SRQL SHALL expose the device's canonical `availability` (`available`, `unavailable`, `unknown`) and its provenance (`availability_source`, `availability_class`) as filterable, groupable and returned fields of `in:devices`.
`is_available:true` SHALL match only `available` devices, and `is_available:false` SHALL match only `unavailable` devices, in both list and grouped-stats queries. Returned rows SHALL carry `is_available` as `null` for `unknown` devices, never `false`.

#### Scenario: Filter unknown devices
- **GIVEN** devices in each availability state
- **WHEN** a client sends `in:devices availability:unknown`
- **THEN** SRQL SHALL return only devices whose canonical state is `unknown`

#### Scenario: Unknown is not reported as unavailable
- **GIVEN** a device whose canonical state is `unknown`
- **WHEN** a client sends `in:devices is_available:false`
- **THEN** the device SHALL NOT be returned
- **AND** when the device is returned by another query its `is_available` value SHALL be `null`

#### Scenario: Grouped stats agree with list filters
- **GIVEN** devices in each availability state
- **WHEN** a client sends a grouped stats query filtered with `!is_available:true`
- **THEN** the grouped result SHALL count only `unavailable` devices, matching the list filter's semantics

### Requirement: Device Default Order Uses Canonical Availability
SRQL SHALL order `in:devices` results without an explicit sort by canonical availability rank (`available`, then `unavailable`, then `unknown`), then by IP ascending, then by uid.

#### Scenario: Default device order
- **GIVEN** an available device, an unavailable device and an unknown device
- **WHEN** a client sends `in:devices` with no sort
- **THEN** the available device SHALL be listed first, the unavailable device second and the unknown device third

### Requirement: Inventory Summary Counts Canonical Availability
SRQL `in:devices rollup_stats:inventory_summary` SHALL report `available`, `unavailable` and `unknown` counts derived from the canonical availability state, maintained from the same value the device list sorts and badges by.

#### Scenario: Summary matches the list
- **GIVEN** a device inventory with devices in each availability state
- **WHEN** a client requests `rollup_stats:inventory_summary`
- **THEN** the `available` count SHALL equal the number of devices returned by `in:devices availability:available`
- **AND** the `unknown` count SHALL equal the number returned by `in:devices availability:unknown`
