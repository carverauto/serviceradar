## ADDED Requirements

### Requirement: Agent updater state and remedy
The web UI SHALL show each agent's updater version, state, reason, supported operations and last observation, SHALL let operators filter and count agents by updater state, SHALL present the package upgrade remedy for every agent that needs one, and SHALL present the package reinstall or repair remedy for every agent whose updater is unavailable.

#### Scenario: Agent needs a package upgrade
- **GIVEN** an agent whose updater state is `package_upgrade_required`
- **WHEN** an operator opens the agent
- **THEN** the page SHALL state the installed and the required updater version, showing the installed version as unknown when the updater does not report one
- **AND** SHALL show the package command built from the host's package family and the required updater version
- **AND** SHALL point to the documented fleet-wide package upgrade

#### Scenario: Agent updater is unavailable
- **GIVEN** an agent whose updater state is `unavailable`
- **WHEN** an operator opens the agent
- **THEN** the page SHALL state which safety check failed
- **AND** SHALL give a package reinstall or repair of the updater as the remedy
- **AND** SHALL NOT present a package upgrade as the remedy

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

#### Scenario: Add-on target excluded for an unavailable updater
- **WHEN** an add-on rollout excludes an agent whose updater is `unavailable`
- **THEN** the row SHALL name the agent and the failed safety check
- **AND** SHALL give a package reinstall or repair as the remedy

#### Scenario: Add-on target excluded for a missing updater operation
- **GIVEN** an agent whose updater state is `current`: it passes the safety checks, answers self-description and meets the minimum version
- **WHEN** an add-on rollout excludes that agent because its updater lacks an operation the release declares
- **THEN** the row SHALL name the agent and state `updater lacks operation <name>`
- **AND** SHALL give a package reinstall as the remedy and SHALL NOT present a package upgrade

#### Scenario: Short operation list does not replace another remedy
- **GIVEN** an agent whose updater state is `package_upgrade_required` or `unavailable`
- **AND** its operation list lacks an operation the release declares
- **WHEN** an add-on rollout excludes that agent or an operator opens it
- **THEN** the row and the page SHALL show the reason and remedy of that state: a package upgrade for `package_upgrade_required`, a package reinstall or repair for `unavailable`
- **AND** SHALL NOT substitute `updater lacks operation <name>` or the missing-operation remedy for them
