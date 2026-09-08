## ADDED Requirements

### Requirement: Package-managed onboarding does not distribute release trust anchors
Edge onboarding for package-managed agents SHALL NOT persist `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY` into `/etc/serviceradar/kv-overrides.env` or any other generic environment override file used by the packaged agent service.

#### Scenario: Agent onboarding bundle omits release key override
- **GIVEN** the deployment configures `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY` for control-plane release validation
- **WHEN** the system generates a package-managed agent onboarding bundle
- **THEN** the bundle SHALL NOT include `config/agent-env-overrides.env` content that sets `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY`
- **AND** package-managed agent trust anchors SHALL remain package-owned instead of bundle-provided

#### Scenario: Enrollment preserves unrelated overrides without writing release key state
- **GIVEN** a host already has unrelated entries in `/etc/serviceradar/kv-overrides.env`
- **WHEN** `serviceradar-cli enroll` installs a package-managed agent bundle generated after this hardening change
- **THEN** enrollment SHALL preserve unrelated existing override entries
- **AND** it SHALL NOT add or update `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY`
