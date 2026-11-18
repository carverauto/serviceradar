## ADDED Requirements

### Requirement: Rollouts show updater replacement outcomes
The release rollout view SHALL show the updater replacement outcome for each target and SHALL name the agent and the reason whenever a rollout paused because of a replacement.

#### Scenario: Rollout paused by a candidate defect
- **WHEN** a release rollout pauses because an updater replacement failed with a candidate-defect reason
- **THEN** the rollout view SHALL name the agent, the reason and the updater version involved

### Requirement: Updater replacement settings
The settings UI SHALL expose the updater replacement kill switch with its effective value, and SHALL require the release-management permission to change them.

#### Scenario: Operator turns replacement off
- **WHEN** an authorized operator turns updater replacement off
- **THEN** the setting SHALL take effect without a redeploy
- **AND** the change SHALL be recorded in the audit history
