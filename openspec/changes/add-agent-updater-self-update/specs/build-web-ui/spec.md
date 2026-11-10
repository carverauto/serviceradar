## ADDED Requirements

### Requirement: Agent updater state and remedy
The web UI SHALL show each agent's updater version, state, reason, supported operations and last observation, SHALL let operators filter and count agents by updater state, and SHALL present the remedy for every state the control plane cannot repair by itself.

#### Scenario: Agent needs a one-time package upgrade
- **GIVEN** an agent whose updater state is `bootstrap_required`
- **WHEN** an operator opens the agent
- **THEN** the page SHALL explain that the installed updater predates self-replacement
- **AND** SHALL show the package command for the host's package family and the target version
- **AND** SHALL link to the agent package automation when the Ansible integration can reach that host

#### Scenario: Fleet view of updater state
- **WHEN** an operator opens the agents list
- **THEN** the list SHALL offer a filter and a count for each updater state
- **AND** Edge Ops SHALL show a notice while any agent is `bootstrap_required` or `unavailable`

#### Scenario: Updater state is unknown
- **WHEN** an agent has reported no updater status
- **THEN** the UI SHALL show the state as unknown and SHALL NOT render it as current

### Requirement: Rollouts show updater outcomes
The release and add-on rollout views SHALL show the updater outcome for each target and SHALL name the agent and the reason whenever a target was skipped or paused because of its updater.

#### Scenario: Rollout paused by a candidate defect
- **WHEN** a release rollout pauses because an updater replacement failed with a candidate-defect reason
- **THEN** the rollout view SHALL name the agent, the reason and the updater version involved

#### Scenario: Add-on target skipped for its updater
- **WHEN** an add-on rollout skips an agent whose updater needs a package upgrade
- **THEN** the row SHALL name the agent and state that one package upgrade is required

### Requirement: Updater replacement settings
The settings UI SHALL expose the updater replacement kill switch with its effective value, and SHALL require the release-management permission to change them.

#### Scenario: Operator turns replacement off
- **WHEN** an authorized operator turns updater replacement off
- **THEN** the setting SHALL take effect without a redeploy
- **AND** the change SHALL be recorded in the audit history
