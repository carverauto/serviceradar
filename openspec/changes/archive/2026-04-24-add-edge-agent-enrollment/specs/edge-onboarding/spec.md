## MODIFIED Requirements
### Requirement: Downloadable Installation Bundle

The system SHALL provide a downloadable bundle containing all files needed to deploy an edge component, eliminating the need for manual file assembly.

The bundle SHALL include:
1. Component certificate (PEM format)
2. Component private key (PEM format)
3. CA chain certificate (for trust verification)
4. Component configuration file
5. Installation script (enroll-only for agents, platform-detecting for other components)

For agent packages, the component configuration file SHALL include the gateway endpoint, agent_id, partition, and a host_ip placeholder value that is replaced during enrollment.
For agent packages, the certificate bundle SHALL be issued by the agent-gateway and returned to web-ng during package creation.

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
- **AND** agent bundles provide an enroll-only script
- **AND** non-agent bundles detect available platforms (Docker, systemd)

#### Scenario: Agent bundle includes bootstrap config
- **GIVEN** an agent onboarding package is created
- **WHEN** the bundle is downloaded
- **THEN** the config includes gateway endpoint, agent_id, and partition values
- **AND** the host_ip field is a placeholder that the enrollment flow replaces
- **AND** the mTLS bundle is signed by the agent-gateway CA

## ADDED Requirements
### Requirement: Enrollment command
The serviceradar-cli SHALL support an enrollment mode that accepts an edgepkg token, downloads the onboarding package, and writes the bootstrap configuration and mTLS assets to standard locations.

#### Scenario: Agent enrolls from token
- **GIVEN** an operator has an edgepkg token for an agent package
- **WHEN** they run `serviceradar-cli enroll --token <edgepkg>`
- **THEN** the CLI downloads the package from the core API
- **AND** writes certificates to the configured cert directory
- **AND** writes agent.json with gateway endpoint, agent_id, and partition
- **AND** backs up any existing agent.json and certs before overwriting
- **AND** restarts the serviceradar-agent service after enrollment

#### Scenario: Host IP placeholder is resolved
- **GIVEN** an agent enrollment package with host_ip placeholder
- **WHEN** enrollment completes
- **THEN** the placeholder is replaced with a detected host IP or an explicit CLI override
- **AND** the resolved host_ip is stored in agent.json

### Requirement: Agent package UI captures optional host IP
The edge onboarding UI SHALL prompt for an optional host IP when creating an agent package and persist that value in the package metadata.

#### Scenario: Optional host IP is provided
- **GIVEN** an admin is creating an agent package
- **WHEN** they enter a host IP value
- **THEN** the package metadata stores the host IP value

#### Scenario: Optional host IP is omitted
- **GIVEN** an admin is creating an agent package
- **WHEN** they leave host IP blank
- **THEN** the package metadata stores a host IP placeholder

#### Scenario: Invalid token does not overwrite config
- **GIVEN** an invalid or expired token
- **WHEN** enrollment is attempted
- **THEN** the agent returns an actionable error
- **AND** no existing config or certs are overwritten

### Requirement: Collector enrollment command
Collector services SHALL be enrolled via `serviceradar-cli enroll --token <token>` which downloads the collector bundle and installs credentials and configuration without manual edits.

#### Scenario: Collector enrolls from token
- **GIVEN** an operator has a collector enrollment token
- **WHEN** they run `serviceradar-cli enroll --token <token>`
- **THEN** the CLI downloads the collector bundle
- **AND** writes NATS credentials and collector config to standard locations

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

### Requirement: Edge onboarding entry points are consolidated
The Settings UI SHALL present a single primary entry point for agent onboarding under Settings → Agents → Deploy and SHALL remove redundant Edge Ops navigation for components.

#### Scenario: Settings deploy is the primary entry point
- **GIVEN** an admin navigates to Settings → Agents → Deploy
- **WHEN** they click Create Agent Package
- **THEN** the flow navigates directly to the agent package creation form
- **AND** no secondary Edge Ops navigation is required

#### Scenario: Edge Ops navigation omits components
- **GIVEN** an admin is viewing the Edge Ops navigation
- **WHEN** the tabs are rendered
- **THEN** no Components tab is displayed

### Requirement: Gateway-issued mTLS bundles
Web-ng SHALL request agent mTLS bundles from the agent-gateway during package creation and SHALL NOT rely on SPIFFE/SPIRE for edge agent issuance.

#### Scenario: Package creation requests gateway-issued certs
- **GIVEN** an admin creates an agent onboarding package
- **WHEN** the package is issued
- **THEN** web-ng requests an mTLS bundle from the agent-gateway
- **AND** the returned bundle is stored with the package tokens

#### Scenario: Gateway issuance is required
- **GIVEN** an agent onboarding package is requested
- **WHEN** the agent-gateway is unavailable
- **THEN** the package creation fails with a certificate issuance error
