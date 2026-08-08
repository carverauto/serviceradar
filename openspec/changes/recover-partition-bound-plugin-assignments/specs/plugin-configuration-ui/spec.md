## ADDED Requirements

### Requirement: Authenticated partition provenance in assignment UI
The plugin package assignment UI SHALL show the current authenticated partition
state for the selected agent and explain that it is derived from the live
server-observed mTLS control session. The UI SHALL NOT render an editable
partition selector or submit an operator-selected partition value.

#### Scenario: Selected online agent has a current partition
- **GIVEN** an operator with plugin assignment permission selects an online agent
- **AND** the server resolves current control-session evidence for partition `default`
- **WHEN** the assignment form renders its agent context
- **THEN** the UI displays `Authenticated partition: default`
- **AND** it explains that the value will be rechecked on save
- **AND** no editable partition input is present

#### Scenario: Selected agent has no trustworthy partition evidence
- **GIVEN** an operator selects an offline agent or an agent without matching control-session evidence
- **WHEN** the assignment form renders its agent context
- **THEN** the UI identifies the authenticated partition as unavailable
- **AND** it does not imply that a saved or default partition will be used

### Requirement: Legacy recovery is not an operator workflow
The plugin configuration UI SHALL keep disabled partition-unbound history out of
the normal assignment editor and Plugins index. It SHALL NOT render a legacy
candidate queue, repeated recovery warnings, per-row review links, manual
reapproval controls, or policy-reconciliation controls.

#### Scenario: Plugins index has quarantined history
- **GIVEN** one or more legacy assignments remain disabled and partition-unbound
- **WHEN** an operator opens the Plugins index
- **THEN** the page does not render `Legacy recovery candidates`
- **AND** it does not present the history as pending operator review

#### Scenario: Package detail has quarantined history
- **GIVEN** a package has current assignments and disabled partition-unbound historical assignments
- **WHEN** an operator opens the package assignment editor
- **THEN** only current assignments render in the normal assignment list
- **AND** no historical warning card, reapproval button, reconciliation button, update control, or remove control is rendered for the history

#### Scenario: Quarantined history does not block a fresh assignment
- **GIVEN** an agent has only disabled unbound historical rows for a plugin
- **WHEN** an authorized operator submits a normal assignment with current configuration
- **THEN** current-assignment lookup excludes the historical rows
- **AND** the UI submits a fresh create through the ordinary partition-binding path
- **AND** it does not instruct the operator to use a recovery action

### Requirement: Status reports the deployed release
The Settings status card SHALL report the release version of the immutable web-ng
image currently deployed. It SHALL prefer deployment identity over imported
agent-release records, which may lag or describe a different artifact set.

#### Scenario: Deployment version is available
- **GIVEN** web-ng is deployed with image tag `v1.4.23`
- **WHEN** the Settings status cards render
- **THEN** `Latest release` displays `1.4.23`
- **AND** an older imported agent release does not override it

#### Scenario: Local development lacks deployment metadata
- **GIVEN** web-ng has no deployment release environment value
- **WHEN** the Settings status cards render in a local environment
- **THEN** the card may fall back to the latest imported agent-release record
