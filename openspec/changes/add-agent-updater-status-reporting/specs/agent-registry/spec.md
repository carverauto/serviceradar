## ADDED Requirements

### Requirement: Per-agent updater status read model
The control plane SHALL persist, for each agent, the privileged updater status the agent reports: version, the agent release's required updater version, state, reason, supported operations, the host's package family and installed package version, and the time of observation. The state SHALL be one of `current`, `package_upgrade_required`, `unavailable`, `not_applicable` or `unknown`, and SHALL be queryable alongside the agent's other attributes.

#### Scenario: Agent reports updater status
- **GIVEN** an agent that reports its updater status in its capability status
- **WHEN** the control plane ingests that status
- **THEN** the agent's updater version, required updater version, state, reason and operations SHALL be stored with the observation time
- **AND** the host's package family and installed package version SHALL be stored with them

#### Scenario: Updater version is unknown
- **GIVEN** an agent that reports `package_upgrade_required` for an updater that does not describe itself
- **WHEN** the control plane ingests that status
- **THEN** the installed updater version SHALL be stored as unknown
- **AND** the required updater version, package family and installed package version SHALL still be stored

#### Scenario: Agent predates updater status reporting
- **GIVEN** an agent release that reports no updater status
- **WHEN** the control plane ingests its capability status
- **THEN** the updater state SHALL be recorded as `unknown` rather than as a healthy state

#### Scenario: Platform without a privileged updater
- **WHEN** an agent runs in a container or on a platform whose installer provides no privileged updater
- **THEN** its updater state SHALL be `not_applicable`
- **AND** it SHALL NOT be counted among agents needing remediation

#### Scenario: Operators query updater state
- **WHEN** an operator filters agents by updater state or version
- **THEN** the result SHALL contain exactly the agents whose stored status matches
