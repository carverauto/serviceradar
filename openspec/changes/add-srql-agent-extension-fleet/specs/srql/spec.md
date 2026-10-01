## ADDED Requirements

### Requirement: Scoped agent extension fleet queries

SRQL SHALL expose native add-on fleet health through `addon_fleet` and WASM assignment/runtime health through `plugin_fleet`, using scoped Ash reads and explicit safe field projections.

#### Scenario: Native desired and observed state
- **WHEN** an authorized operator queries `addon_fleet`
- **THEN** rows include desired package/version, observed runtime state/version, health category/reason, report/health timestamps, evidence freshness, rollout state, and version drift
- **AND** native health classification matches the existing fleet model
- **AND** `addon_statuses` retains its existing behavior

#### Scenario: WASM assignment and runtime state
- **WHEN** an authorized operator queries `plugin_fleet`
- **THEN** rows include partition, agent, plugin, safe package/assignment metadata, cadence, and latest runtime evidence
- **AND** runtime joins match both partition and agent and use the existing plugin identity contract
- **AND** assignment placeholders are distinguished from reported results
- **AND** stale observations are never classified as current healthy results

#### Scenario: Credential custody and access control
- **WHEN** a fleet query executes
- **THEN** the caller's scope is used for every Ash read
- **AND** native queries require `devices.view` and WASM queries require `plugins.view`
- **AND** assignment params, overrides, host grants, arbitrary result payloads, and secrets are excluded

#### Scenario: Query operations
- **WHEN** a fleet query includes scalar filters, list membership, sorting, time bounds, or a signed cursor
- **THEN** the compiler validates fields and operators and the scoped read executor applies those operations before pagination
- **AND** unsupported aggregation requests fail explicitly
