## ADDED Requirements

### Requirement: Signed agent release catalog
The system SHALL maintain a catalog of publishable agent releases. Each release entry SHALL include signed manifest metadata for every supported platform/package artifact, including version, artifact URL, SHA256 digest, supported platform metadata, and publication timestamp. The control plane SHALL reject incomplete or unsigned release metadata for rollout use.

#### Scenario: Publish a signed release
- **GIVEN** an operator publishes agent version `v1.2.3` with a complete manifest and valid Ed25519 signature
- **WHEN** the control plane validates the release metadata
- **THEN** the release is stored as eligible for rollout targeting
- **AND** the catalog exposes the version and artifact metadata to rollout workflows

#### Scenario: Reject invalid release metadata
- **GIVEN** an operator attempts to publish a release whose manifest signature is invalid
- **WHEN** the control plane validates the release metadata
- **THEN** the release is rejected
- **AND** it cannot be selected as a desired version

### Requirement: Desired-version rollouts are cohort-based and staged
The system SHALL allow operators to assign a desired agent version to a cohort of agents. Rollouts SHALL support explicit cohort selection, batch limits, inter-batch delays, and pause/resume/cancel controls. Cohort membership SHALL be snapshotted when the rollout starts.

#### Scenario: Start a canary rollout
- **GIVEN** an operator selects 10 agents as a canary cohort for version `v1.2.3`
- **AND** configures a batch size of 5 with a delay between batches
- **WHEN** the rollout is started
- **THEN** the control plane creates rollout targets for the 10 selected agents
- **AND** only the first batch is eligible for immediate delivery

#### Scenario: Pause an in-flight rollout
- **GIVEN** a rollout is active and has pending targets that have not started
- **WHEN** an operator pauses the rollout
- **THEN** no new targets are advanced into delivery
- **AND** already-running targets continue reporting their terminal state

### Requirement: Desired-version reconciliation spans online and offline agents
The system SHALL reconcile desired version against each agent's reported current version. Connected eligible agents SHALL receive update instructions immediately over the control stream. Disconnected eligible agents SHALL remain pending and SHALL be reconciled when they reconnect.

#### Scenario: Connected agent receives update immediately
- **GIVEN** an agent is connected on the control stream
- **AND** its current version differs from the rollout desired version
- **WHEN** the rollout advances that agent's target
- **THEN** the gateway sends an update instruction without waiting for config polling

#### Scenario: Offline agent converges on reconnect
- **GIVEN** an agent target is part of an active rollout but the agent is offline
- **WHEN** the agent reconnects and reports its current version
- **THEN** the control plane reconciles the stored desired version
- **AND** the gateway delivers the pending update instruction if the target is still eligible

### Requirement: Agents verify release provenance before activation
Agents SHALL download release artifacts over HTTPS and SHALL verify both the Ed25519-signed manifest and the artifact SHA256 digest before staging or activating a new version. Agents SHALL reject releases that fail either check.

#### Scenario: Agent accepts a valid signed release
- **GIVEN** the agent receives an update instruction for a release with a valid manifest signature
- **AND** the downloaded artifact matches the published SHA256 digest
- **WHEN** the agent performs verification
- **THEN** the release is staged for activation

#### Scenario: Agent rejects a tampered artifact
- **GIVEN** the agent receives a release whose manifest signature is valid
- **AND** the downloaded artifact digest does not match the manifest
- **WHEN** the agent performs verification
- **THEN** the agent rejects the update
- **AND** the rollout target transitions to a failed state with a verification error

### Requirement: Activation is atomic and rollback is automatic
The system SHALL activate a staged agent release through a separate updater process that can atomically switch the active runtime payload and restart the service. If the updated agent fails to become healthy within the reconnect deadline, the updater SHALL restore the previous payload and restart the agent again.

#### Scenario: Successful activation
- **GIVEN** an agent has verified and staged a new release
- **WHEN** the updater switches the active runtime payload and restarts the service
- **AND** the new agent reconnects healthy before the deadline
- **THEN** the rollout target transitions to `healthy`
- **AND** the previous payload remains available for later rollback if needed

#### Scenario: Failed activation triggers rollback
- **GIVEN** an agent has switched to a new runtime payload
- **WHEN** the updated agent does not reconnect healthy before the rollback deadline
- **THEN** the updater restores the previous payload
- **AND** restarts the previous version
- **AND** the rollout target transitions to `rolled_back`

### Requirement: Rollout progress is persisted per agent
The system SHALL persist per-agent rollout state transitions and error details so operators can audit rollout progress and diagnose failures.

#### Scenario: Operator inspects rollout state
- **GIVEN** a rollout has targeted multiple agents
- **WHEN** an operator queries rollout progress
- **THEN** each targeted agent shows its current rollout state
- **AND** timestamps and last error details are available for failed or rolled-back targets
