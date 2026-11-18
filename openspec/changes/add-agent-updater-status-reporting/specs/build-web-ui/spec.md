## ADDED Requirements

### Requirement: Agent updater state and remedy
The web UI SHALL show each agent's updater version, state, reason, supported operations and last observation, SHALL let operators filter and count agents by updater state, and SHALL present the package upgrade remedy for every agent that needs one.

#### Scenario: Agent needs a package upgrade
- **GIVEN** an agent whose updater state is `package_upgrade_required`
- **WHEN** an operator opens the agent
- **THEN** the page SHALL state the installed and the required updater version
- **AND** SHALL show the package command for the host's package family and the target version
- **AND** SHALL point to the documented fleet-wide package upgrade

#### Scenario: Fleet view of updater state
- **WHEN** an operator opens the agents list
- **THEN** the list SHALL offer a filter and a count for each updater state
- **AND** Edge Ops SHALL show a notice while any agent is `package_upgrade_required` or `unavailable`

#### Scenario: Updater state is unknown
- **WHEN** an agent has reported no updater status
- **THEN** the UI SHALL show the state as unknown and SHALL NOT render it as current

### Requirement: Rollouts name targets excluded for their updater
The release and add-on rollout views SHALL name each agent excluded because of its updater and SHALL state the reason and the remedy on that row.

#### Scenario: Add-on target excluded for its updater
- **WHEN** an add-on rollout excludes an agent whose updater needs a package upgrade
- **THEN** the row SHALL name the agent and state that a package upgrade is required
