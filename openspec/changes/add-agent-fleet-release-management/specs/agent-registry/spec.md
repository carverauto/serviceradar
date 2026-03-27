## ADDED Requirements

### Requirement: Agent inventory includes release state
The system SHALL expose agent release-management fields through inventory and query surfaces, including current version, desired version, rollout state, last update time, and last update error.

#### Scenario: Query agent release state
- **GIVEN** an agent has current version `v1.2.2` and desired version `v1.2.3`
- **AND** its rollout target is in `downloading`
- **WHEN** an operator queries agent inventory
- **THEN** the returned agent record includes current version, desired version, rollout state, and last update timestamp

### Requirement: Agent inventory UI supports rollout operations
The web-ng agent inventory UI SHALL allow operators to view fleet version distribution, filter agents by version and rollout state, and inspect per-agent rollout history and failure diagnostics.

#### Scenario: Filter inventory by rollout state
- **GIVEN** the agent inventory contains agents in `healthy`, `pending`, and `failed` rollout states
- **WHEN** an operator filters the list by `failed`
- **THEN** only failed rollout targets are shown
- **AND** the list includes the current version, desired version, and failure summary for each matching agent

#### Scenario: Inspect rollout history for one agent
- **GIVEN** an operator opens an agent detail page
- **WHEN** the agent has prior rollout attempts
- **THEN** the detail view shows the rollout timeline
- **AND** failed or rolled-back attempts include the recorded error details
