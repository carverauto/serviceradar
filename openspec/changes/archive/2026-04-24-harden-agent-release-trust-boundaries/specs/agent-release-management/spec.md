## ADDED Requirements

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
