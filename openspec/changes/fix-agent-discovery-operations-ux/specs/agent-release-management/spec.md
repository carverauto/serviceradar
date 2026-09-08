## ADDED Requirements
### Requirement: Agent detail release status hydration
The system SHALL hydrate the agent detail Release Management section from authoritative release-management state. The displayed values SHALL include current version, desired version, latest rollout state, last update timestamp, and latest error when those values exist in persisted agent state, rollout target state, or live control-stream metadata.

#### Scenario: Release status exists for an agent
- **GIVEN** agent `agent-sr-test-pve04` has a stored current version or active rollout target
- **WHEN** an operator opens `/agents/agent-sr-test-pve04`
- **THEN** the Release Management section SHALL show the known current version, desired version, rollout state, and last update timestamp
- **AND** it SHALL NOT show `Unknown` or `-` for values available from authoritative state

#### Scenario: Successful reconnect clears stale update error
- **GIVEN** an agent previously had `last_update_error` set because its control stream was offline
- **WHEN** the agent reconnects and reports healthy release/update state
- **THEN** the stale last update error SHALL be cleared or superseded by the new successful state
- **AND** agent detail SHALL not continue displaying the stale error as the latest failure

#### Scenario: Release status is genuinely unavailable
- **GIVEN** no persisted release state, rollout target state, or live connected-agent metadata exists for an agent
- **WHEN** an operator opens the agent detail page
- **THEN** the Release Management section MAY show explicit unavailable placeholders
- **AND** the placeholders SHALL distinguish missing data from an unknown rollout state.
