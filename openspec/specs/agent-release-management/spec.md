# agent-release-management Specification

## Purpose
TBD - created by archiving change harden-agent-updater-exec-arguments. Update Purpose after archive.
## Requirements
### Requirement: Managed release updater arguments are validated before exec
Before a package-managed agent spawns the updater for managed release activation, it SHALL validate every updater-bound activation argument derived from network command metadata. The staged release version SHALL match the managed release version token format, the command identifier SHALL be a UUID, the command type SHALL be an allowed managed release activation command type, and none of those values SHALL contain control characters or NUL bytes. If any validation fails, the agent SHALL reject activation and report a validation error instead of executing the updater.

#### Scenario: Managed release activation rejects malformed command metadata
- **GIVEN** a staged managed release is ready for activation
- **AND** the received release command has a malformed `command_id`, an unexpected `command_type`, or control characters in updater-bound metadata
- **WHEN** the agent prepares updater activation
- **THEN** the agent SHALL reject the activation attempt before spawning the updater
- **AND** the rollout target SHALL surface an activation validation error

#### Scenario: Managed release activation rejects non-canonical version tokens
- **GIVEN** a staged managed release is ready for activation
- **AND** the release `version` contains characters outside the managed release token format
- **WHEN** the agent prepares updater activation
- **THEN** the agent SHALL reject the activation attempt before spawning the updater
- **AND** the updater SHALL NOT receive the invalid version string

#### Scenario: Managed release activation accepts canonical updater arguments
- **GIVEN** a staged managed release is ready for activation
- **AND** the release `version` uses the managed release token format
- **AND** the release `command_id` is a UUID
- **AND** the release `command_type` is `agent.update_release`
- **WHEN** the agent prepares updater activation
- **THEN** the agent SHALL invoke the updater with those canonicalized values

### Requirement: Package-managed agent trust anchors are package-owned
Package-managed agents SHALL use only package-owned trust anchors and package-owned execution paths for managed release verification and activation. The release verification key SHALL come only from the build-time embedded `ReleaseSigningPublicKey`. The updater binary path, seed binary path, and managed runtime root SHALL use package-owned defaults rather than host-local environment overrides.

#### Scenario: Stale local release key override is ignored
- **GIVEN** a package-managed agent binary embeds the active release verification public key
- **AND** the host still has `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY` set to an older or different value in `/etc/serviceradar/kv-overrides.env`
- **WHEN** the agent verifies a managed release manifest
- **THEN** it SHALL use the embedded verification key
- **AND** the stale local override SHALL NOT redefine the trust anchor

#### Scenario: Runtime path overrides are ignored
- **GIVEN** a package-managed agent host sets `SERVICERADAR_AGENT_UPDATER`, `SERVICERADAR_AGENT_RUNTIME_ROOT`, or `SERVICERADAR_AGENT_SEED_BINARY`
- **WHEN** the managed release activation flow runs
- **THEN** the agent SHALL use the package-owned updater path, runtime root, and seed binary path
- **AND** the environment overrides SHALL NOT redirect execution or runtime staging

### Requirement: Package-managed updater execution fails closed on unsafe binaries
Before a package-managed agent executes the updater during managed release activation, it SHALL validate that the updater path resolves to a regular file owned by `root` and not writable by group or other users. If validation fails, the agent SHALL reject activation and report a specific failure.

#### Scenario: Unsafe updater ownership blocks activation
- **GIVEN** the package-managed updater path exists
- **AND** the file is not owned by `root` or is writable by group or other users
- **WHEN** the agent prepares managed release activation
- **THEN** the agent SHALL reject the activation attempt
- **AND** the rollout target SHALL surface an updater validation error instead of executing the file

### Requirement: Release artifacts are mirrored into internal distribution storage
The system SHALL mirror rollout artifact payloads into ServiceRadar-managed internal object storage when a release is published or imported. A release SHALL not become rollout-eligible until every required artifact has been staged successfully in internal storage.

#### Scenario: Imported release becomes internally distributable
- **GIVEN** an operator imports a signed repository-hosted release for version `v1.2.3`
- **WHEN** the control plane validates the signed manifest and mirrors each artifact into internal object storage
- **THEN** the release is stored as rollout-eligible
- **AND** the catalog records internal storage references for each supported artifact

#### Scenario: Mirroring failure blocks publication
- **GIVEN** an operator publishes or imports a release whose external artifact cannot be mirrored into internal storage
- **WHEN** the release publication workflow runs
- **THEN** the release is rejected for rollout use
- **AND** the operator receives an error indicating internal artifact staging failed

### Requirement: Manual release publication remains available for developer workflows
The system SHALL preserve a manual release publication path for developer and local validation workflows, even when production rollouts normally use repository-hosted release imports.

#### Scenario: Developer publishes a local validation release
- **GIVEN** a developer wants to test agent release management without pushing a production-style release to the repository host
- **WHEN** the developer manually publishes signed release metadata and artifact source details
- **THEN** the control plane mirrors the artifact into internal storage
- **AND** the release can be rolled out through the same gateway-served delivery path as production releases

### Requirement: Signed agent release catalog
The system SHALL maintain a catalog of publishable agent releases. Each release entry SHALL include signed manifest metadata for every supported platform/package artifact, including version, artifact URL, SHA256 digest, supported platform metadata, and publication timestamp. Operators SHALL be able to publish release metadata either manually or by importing signed manifest assets from a repository-hosted release. The control plane SHALL reject incomplete or unsigned release metadata for rollout use.

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

#### Scenario: Import a signed repository release
- **GIVEN** a repository-hosted release exposes a signed manifest asset and matching signature asset for version `v1.2.3`
- **WHEN** an operator imports that release from the release-management UI
- **THEN** the control plane fetches the manifest assets, validates the signature, and stores the release as eligible for rollout targeting
- **AND** the imported release retains source metadata identifying the repository release it came from

#### Scenario: Browse recent repository releases before import
- **GIVEN** an operator opens the release-management UI for a configured repository host and repo URL
- **WHEN** the page loads repository release metadata
- **THEN** the latest repository releases are listed automatically with their tag, publish time, and whether the configured manifest and signature assets are present
- **AND** releases missing those assets are not offered as one-click import candidates

#### Scenario: Published repository releases are import-ready
- **GIVEN** ServiceRadar publishes an agent-capable GitHub release for version `v1.2.3`
- **WHEN** the release publisher uploads release assets
- **THEN** the release includes the managed agent runtime archive plus `serviceradar-agent-release-manifest.json` and `serviceradar-agent-release-manifest.sig`
- **AND** the release-management UI can import that release without any manual asset backfill

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
Agents SHALL download release artifacts over HTTPS and SHALL verify both the Ed25519-signed manifest and the artifact SHA256 digest before staging or activating a new version. Agents SHALL allow HTTPS redirect chains when downloading release artifacts from repository-hosted release infrastructure, but SHALL reject redirects that downgrade transport security. Agents SHALL reject releases that fail either check.

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

#### Scenario: Agent follows a secure repository redirect
- **GIVEN** the agent receives a release artifact URL that redirects over HTTPS to repository-backed object storage
- **WHEN** the agent downloads the artifact
- **THEN** the agent follows the HTTPS redirect chain
- **AND** still verifies the Ed25519-signed manifest and artifact SHA256 digest before staging the release

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
