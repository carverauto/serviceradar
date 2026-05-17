## MODIFIED Requirements
### Requirement: Signed agent release catalog
The system SHALL maintain a catalog of publishable agent releases. Each release entry SHALL include signed manifest metadata for every supported platform/package artifact, including version, artifact URL, SHA256 digest, supported platform metadata, and publication timestamp. Operators SHALL be able to publish release metadata either manually or by importing signed manifest assets from a repository-hosted release. The control plane SHALL reject incomplete or unsigned release metadata for rollout use.

The release-management UI SHALL present bounded recent inventory: the latest five published agent releases and the latest five repository releases discovered from the configured repository source. Historical releases may remain stored for audit or rollout protection, but the default operator view SHALL not render an unbounded or paginated repository history.

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

#### Scenario: Browse bounded recent repository releases before import
- **GIVEN** an operator opens the release-management UI for a configured repository host and repo URL
- **WHEN** the page loads repository release metadata
- **THEN** only the latest five repository releases are listed automatically with their tag, publish time, and whether the configured manifest and signature assets are present
- **AND** releases missing those assets are not offered as one-click import candidates
- **AND** the repository release list does not expose pagination in the default view

#### Scenario: Browse bounded published releases
- **GIVEN** more than five agent releases have been published
- **WHEN** an operator opens release management
- **THEN** the published releases list shows the latest five releases by publish time
- **AND** older published releases are omitted from the default view

#### Scenario: Published repository releases are import-ready
- **GIVEN** ServiceRadar publishes an agent-capable GitHub release for version `v1.2.3`
- **WHEN** the release publisher uploads release assets
- **THEN** the release includes the managed agent runtime archive plus `serviceradar-agent-release-manifest.json` and `serviceradar-agent-release-manifest.sig`
- **AND** the release-management UI can import that release without any manual asset backfill

### Requirement: Rollout progress is persisted per agent
The system SHALL persist per-agent rollout state transitions and error details so operators can audit rollout progress and diagnose failures. Transient dispatch or acknowledgement timeouts SHALL be preserved as diagnostic events, but later verified activation success SHALL supersede stale in-flight/error display for the same rollout target.

#### Scenario: Operator inspects rollout state
- **GIVEN** a rollout has targeted multiple agents
- **WHEN** an operator queries rollout progress
- **THEN** each targeted agent shows its current rollout state
- **AND** timestamps and last error details are available for failed or rolled-back targets

#### Scenario: Ack timeout is superseded by activation success
- **GIVEN** an agent target records `command_ack_timeout` after dispatch
- **AND** the agent restarts and later reports the requested version as activated
- **WHEN** rollout progress is recalculated
- **THEN** the target transitions to Healthy
- **AND** the stale ack-timeout is retained only as diagnostic history
- **AND** the current Last Error display is cleared

## ADDED Requirements
### Requirement: Agent release detail derives desired version from active intent
Agent details SHALL derive desired version from current rollout intent or current policy, not from stale historical failed attempts. Historical failed attempts SHALL remain visible in recent rollout attempts but SHALL NOT make an agent that is already running a newer release appear to desire an obsolete version.

#### Scenario: Stale failed attempt does not override current version
- **GIVEN** an agent is currently running version `1.2.63`
- **AND** the agent has an old failed rollout attempt for desired version `1.2.10`
- **WHEN** an operator opens agent details
- **THEN** the Current Version shows `1.2.63`
- **AND** the Desired Version does not show `1.2.10` unless that version is still the active rollout intent
- **AND** the old failed `1.2.10` attempt remains visible only in Recent Rollout Attempts
