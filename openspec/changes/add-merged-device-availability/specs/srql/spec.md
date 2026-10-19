## ADDED Requirements

### Requirement: Devices Expose Canonical Availability State
SRQL SHALL expose the device's canonical `availability` (`available`, `unavailable`, `unknown`) and its provenance (`availability_source`, `availability_class`) as filterable, groupable and returned fields of `in:devices`.
`is_available` SHALL remain a boolean field holding the device's last decided availability, with its existing filter semantics, and SHALL NOT be `null` for `unknown` devices. `unknown` SHALL be exposed only through `availability`.

#### Scenario: Filter unknown devices
- **GIVEN** devices in each availability state
- **WHEN** a client sends `in:devices availability:unknown`
- **THEN** SRQL SHALL return only devices whose canonical state is `unknown`

#### Scenario: Unknown device keeps its last boolean
- **GIVEN** a device last decided `available` whose evidence has all expired
- **WHEN** a client sends `in:devices availability:unknown`
- **THEN** the device SHALL be returned with `availability` `unknown` and `is_available` `true`
- **AND** `in:devices availability:available` SHALL NOT return the device

### Requirement: Devices Expose Per-Agent Reachability
SRQL SHALL keep the existing per-agent availability filters (`available_from_agent`, `unavailable_from_agent`, `availability_source_fresh_within`) with unchanged semantics, and SHALL add `agent_reachability:all|partial|none`, `availability_policy:violation|verified|inconclusive`, and the returned fields `agents_up` and `agents_total` derived from the per-agent ledger.

#### Scenario: Find devices unreachable from some agents
- **GIVEN** a device reachable from one of three probing agents
- **WHEN** a client sends `in:devices agent_reachability:partial`
- **THEN** the device SHALL be returned with `agents_up` 1 and `agents_total` 3

#### Scenario: Per-agent filter is unchanged
- **GIVEN** a device whose merged state is `available` while agent B's latest result is unreachable
- **WHEN** a client sends `in:devices unavailable_from_agent:B`
- **THEN** the device SHALL be returned

#### Scenario: Find isolation policy violations
- **GIVEN** a device reached by an agent that is expected to be blocked
- **WHEN** a client sends `in:devices availability_policy:violation`
- **THEN** the device SHALL be returned

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
