## ADDED Requirements

### Requirement: Agent onboarding bundles distribute the release verification key
When `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY` is configured for the deployment, the system SHALL include that public key in agent-capable onboarding bundles using the standard packaged-agent environment overrides path so enrolled agents can verify signed release manifests without manual host edits.

#### Scenario: Agent bundle carries the configured release verification key
- **GIVEN** the deployment configures `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY`
- **AND** an operator creates an onboarding package for an agent-capable component
- **WHEN** the onboarding bundle is generated
- **THEN** the bundle includes the packaged-agent overrides content with `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY`
- **AND** the generated `agent.json` remains limited to bootstrap connectivity settings

#### Scenario: Bundle omits the override when release management is not configured
- **GIVEN** the deployment does not configure `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY`
- **WHEN** an operator creates an onboarding package for an agent-capable component
- **THEN** bundle generation still succeeds
- **AND** no release verification override is added to the bundle

### Requirement: Agent enrollment persists the release verification key safely
The agent enrollment workflow SHALL install the onboarding bundle's release verification override into the standard packaged-agent overrides file without removing unrelated existing override entries.

#### Scenario: Enrollment writes the release verification key
- **GIVEN** an onboarding bundle includes `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY`
- **WHEN** `serviceradar-cli enroll --token ...` installs the bundle on the target host
- **THEN** the enrollment workflow writes the key to the packaged-agent overrides file
- **AND** the packaged agent restarts with the new verification key available in its environment

#### Scenario: Enrollment preserves unrelated overrides
- **GIVEN** the target host already has other entries in the packaged-agent overrides file
- **AND** the onboarding bundle includes `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY`
- **WHEN** the enrollment workflow installs the new override
- **THEN** unrelated override entries remain present
- **AND** only the release verification key entry is added or updated
