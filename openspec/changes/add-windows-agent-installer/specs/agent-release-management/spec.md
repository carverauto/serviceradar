## ADDED Requirements

### Requirement: Windows agent runs as a managed service
The agent SHALL integrate with the Windows service manager when started as a service: it SHALL report a running state after startup and SHALL perform its normal graceful shutdown when the service manager requests Stop or Shutdown. When started from a console it SHALL keep the existing signal-based behavior. On Windows, default configuration and state paths SHALL be under the ProgramData directory instead of the unix locations.

#### Scenario: Service manager starts the agent
- **GIVEN** the agent is installed as the `ServiceRadarAgent` Windows service
- **WHEN** the service manager starts it
- **THEN** the service reaches the Running state within the service manager's start timeout
- **AND** the agent loads its configuration from `%ProgramData%\ServiceRadar\config\agent.json`

#### Scenario: Service manager stops the agent
- **GIVEN** the agent is running as a Windows service
- **WHEN** an operator stops the service
- **THEN** the agent performs its graceful shutdown and the service reaches the Stopped state

#### Scenario: Agent restarts after an unexpected exit
- **GIVEN** the agent service is running
- **WHEN** the agent process exits without a service Stop request
- **THEN** the service manager restarts it according to the installed recovery actions

### Requirement: Windows MSI installer release artifacts
Agent-capable releases SHALL publish an MSI installer for Windows amd64 and Windows arm64. The installer SHALL install the agent binary and the `ServiceRadarAgent` service, SHALL install a default configuration only when none exists, SHALL replace an older installed version on upgrade, and SHALL preserve configuration and state on uninstall. Until Authenticode signing is configured, the installers and binaries MAY be published unsigned, and the release SHALL still publish provenance recording the version, source commit, architecture, and SHA256 of each MSI.

#### Scenario: Fresh install
- **GIVEN** a Windows host without ServiceRadar installed
- **WHEN** an operator installs `serviceradar-agent_<version>_windows_amd64.msi`
- **THEN** the agent binary is installed under Program Files, a default configuration is written, and the service is started

#### Scenario: Upgrade preserves operator configuration
- **GIVEN** a Windows host running an older agent with an operator-edited configuration
- **WHEN** the operator installs a newer MSI
- **THEN** the older version is replaced and the operator's configuration is unchanged

#### Scenario: Release publishes Windows installers
- **GIVEN** an agent-capable release is published for version `v1.2.3`
- **WHEN** the release workflow completes
- **THEN** the release includes MSIs for Windows amd64 and arm64 whose SHA256 digests match their CI provenance
