## MODIFIED Requirements
### Requirement: Downloadable Installation Bundle

The system SHALL provide a downloadable bundle containing all files needed to deploy an edge component, eliminating the need for manual file assembly.

The bundle SHALL include:
1. Component certificate (PEM format)
2. Component private key (PEM format)
3. CA chain certificate (for trust verification)
4. Component configuration file
5. Platform-detecting installation script

For agent packages, the component configuration file SHALL include the gateway endpoint, agent_id, partition, and a host_ip placeholder value that is replaced during enrollment.

#### Scenario: Download bundle as archive

- **GIVEN** a package has been successfully created
- **WHEN** the admin clicks "Download Bundle"
- **THEN** the system delivers a compressed archive file
- **AND** the archive contains certs/, config/, and install.sh
- **AND** all certificate files are in PEM format

#### Scenario: Bundle includes install script

- **GIVEN** a bundle is downloaded
- **WHEN** the admin inspects the bundle contents
- **THEN** the bundle contains an install.sh script
- **AND** the script detects available platforms (Docker, systemd)
- **AND** the script provides usage instructions if manual install is required

#### Scenario: Agent bundle includes bootstrap config
- **GIVEN** an agent onboarding package is created
- **WHEN** the bundle is downloaded
- **THEN** the config includes gateway endpoint, agent_id, and partition values
- **AND** the host_ip field is a placeholder that the enrollment flow replaces

## ADDED Requirements
### Requirement: Agent enrollment command
The serviceradar-agent CLI SHALL support an enrollment mode that accepts an edgepkg token, downloads the onboarding package, and writes the agent bootstrap configuration and mTLS assets to standard locations.

#### Scenario: Agent enrolls from token
- **GIVEN** an operator has an edgepkg token for an agent package
- **WHEN** they run `serviceradar-agent --enroll --token <edgepkg>`
- **THEN** the agent downloads the package from the core API
- **AND** writes certificates to the configured cert directory
- **AND** writes agent.json with gateway endpoint, agent_id, and partition

#### Scenario: Host IP placeholder is resolved
- **GIVEN** an agent enrollment package with host_ip placeholder
- **WHEN** enrollment completes
- **THEN** the placeholder is replaced with a detected host IP or an explicit CLI override
- **AND** the resolved host_ip is stored in agent.json

#### Scenario: Invalid token does not overwrite config
- **GIVEN** an invalid or expired token
- **WHEN** enrollment is attempted
- **THEN** the agent returns an actionable error
- **AND** no existing config or certs are overwritten

### Requirement: Edge onboarding UI flow is stable
The edge onboarding package creation UI SHALL render without runtime errors and SHALL provide a consistent flow from both admin and settings entry points.

#### Scenario: Admin edge packages page renders
- **GIVEN** an admin navigates to /admin/edge-packages
- **WHEN** they open the create package modal
- **THEN** the form renders successfully
- **AND** the page does not raise runtime errors

#### Scenario: Settings deploy entry point renders
- **GIVEN** an admin navigates to /settings/agents/deploy
- **WHEN** they open the edge onboarding flow
- **THEN** the same package creation form is rendered
- **AND** submissions create a package successfully
