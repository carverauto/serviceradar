## ADDED Requirements

### Requirement: Updater self-description
The privileged agent updater SHALL report its version, platform and supported operations as a machine-readable document through an invocation that performs no privileged change. When the updater answers that invocation, the agent SHALL use the document, not usage text, to decide whether a privileged operation is available. Only when an updater that passes the safety checks does not answer MAY the agent take the operation list from the updater's usage text, and that updater SHALL remain `package_upgrade_required`.

#### Scenario: Agent reads the updater's operations
- **GIVEN** an installed updater that supports self-description
- **WHEN** the agent inspects it
- **THEN** the agent SHALL obtain the updater's version and the named operations it supports
- **AND** SHALL NOT execute any privileged change to obtain them

#### Scenario: Updater predates self-description
- **GIVEN** an installed updater that is present, a regular file, root-owned, not writable by group or others, and setuid
- **AND** it does not answer the self-description invocation
- **WHEN** the agent inspects it
- **THEN** the agent SHALL classify the updater as `package_upgrade_required`
- **AND** SHALL report the installed updater version as unknown
- **AND** the reason SHALL name the release's required updater version
- **AND** SHALL take that updater's operations from its usage text and still be able to use them
- **AND** operations found that way SHALL NOT make the agent eligible for a privileged add-on or managed certificate rollout

### Requirement: Agent releases declare the updater they need
Each agent release SHALL declare the minimum updater version it requires and the updater operation each privileged feature uses. The agent SHALL classify the installed updater in this order: `not_applicable` when the platform provides no privileged updater; otherwise `unavailable` when the updater fails any safety check (it must be present, a regular file, root-owned, not writable by group or others, and setuid), whether or not it answers self-description; otherwise `package_upgrade_required` when it does not answer self-description or is below the release's minimum version; otherwise `current`. The agent SHALL report the result with the updater's version, the required version, operations, a reason, the host's package family and installed package version, and the time of observation.

#### Scenario: Updater meets the release's requirement
- **GIVEN** an installed updater that is present, a regular file, root-owned, not writable by group or others, and setuid
- **AND** it answers self-description at or above the release's minimum version
- **WHEN** the agent reports its capability status
- **THEN** the updater state SHALL be `current`

#### Scenario: Updater is older than the release requires
- **GIVEN** an installed updater that is present, a regular file, root-owned, not writable by group or others, and setuid
- **AND** it answers self-description below the release's minimum version
- **WHEN** the agent reports its capability status
- **THEN** the updater state SHALL be `package_upgrade_required`
- **AND** the reason SHALL name the installed and the required version

#### Scenario: Updater is missing or unsafe to execute
- **WHEN** the updater is absent, not a regular file, not root-owned, writable by group or others, or lacks the setuid bit
- **THEN** the updater state SHALL be `unavailable` with a reason that says which check failed
- **AND** this SHALL hold whether or not the updater answers self-description and whatever version it reports

#### Scenario: Agent release does not raise the minimum
- **GIVEN** a new agent release whose minimum updater version equals the previous release's
- **WHEN** a host with a `current` updater activates it
- **THEN** the updater state SHALL remain `current`

### Requirement: Privileged features are gated by updater operation
The agent SHALL require privileged operations by name and SHALL NOT invoke the updater with a flag the installed updater does not define.

#### Scenario: Agent needs an operation the updater lacks
- **GIVEN** an agent feature that needs a named updater operation
- **AND** the installed updater does not list it
- **WHEN** the feature is requested
- **THEN** the agent SHALL report the feature blocked with the missing operation
- **AND** SHALL NOT invoke the updater

### Requirement: The privileged updater is changed only by the operating system package
The system SHALL NOT replace, patch or reconfigure the installed privileged updater through a control-plane command, an agent release or an add-on. The operating system package, installed by a root operator or by automation acting as root on that host, SHALL be the only writer of the updater.

#### Scenario: Agent activates a newer release
- **WHEN** an agent stages and activates a newer agent release
- **THEN** the installed updater SHALL be byte-for-byte unchanged

#### Scenario: Control plane sees an old updater
- **GIVEN** an agent whose updater state is `package_upgrade_required`
- **WHEN** the control plane reconciles that agent
- **THEN** it SHALL dispatch no command that writes the updater path
- **AND** SHALL report the package upgrade as the remedy

### Requirement: Hosts needing a package upgrade are identified
The system SHALL identify every agent whose installed updater does not meet its agent release's requirement, SHALL report why, and SHALL present the exact remedy for that host.

#### Scenario: Host needs a package upgrade
- **GIVEN** an agent classified `package_upgrade_required`
- **WHEN** an operator views the agent or a rollout that excluded it
- **THEN** the system SHALL state that a package upgrade is required
- **AND** SHALL show the package command built from the host's reported package family and the release's required updater version

#### Scenario: Host is upgraded
- **WHEN** the upgraded updater is present, a regular file, root-owned, not writable by group or others, and setuid, and answers self-description at or above the required version
- **THEN** the agent's updater state SHALL become `current` without operator action in ServiceRadar

### Requirement: Rollout eligibility follows updater state
The control plane SHALL decide whether an agent can receive a privileged add-on or managed certificate from the updater state and operations the agent reports, and SHALL exclude an ineligible agent before dispatch.

#### Scenario: Updater needs a package upgrade
- **GIVEN** an agent whose updater is `package_upgrade_required`
- **WHEN** a privileged add-on rollout selects its targets
- **THEN** the agent SHALL be ineligible and SHALL receive no install command
- **AND** the recorded reason SHALL name the agent, the package upgrade and the required updater version

#### Scenario: Updater is unavailable
- **GIVEN** an agent whose updater is `unavailable`
- **WHEN** a privileged add-on rollout selects its targets
- **THEN** the agent SHALL be ineligible and SHALL receive no install command
- **AND** the recorded reason SHALL name the agent and the safety check that failed
- **AND** SHALL give a package reinstall or repair of the updater as the remedy

#### Scenario: Excluded host does not pause the rollout
- **GIVEN** a rollout whose scope contains eligible agents and agents excluded for their updater
- **WHEN** the rollout runs
- **THEN** it SHALL proceed on the eligible agents
- **AND** the excluded agents SHALL NOT count as candidate failures

#### Scenario: Agent reports no updater status
- **GIVEN** an agent release that predates updater status reporting
- **WHEN** a privileged add-on rollout selects its targets
- **THEN** the legacy updater capability string SHALL decide that agent's eligibility
