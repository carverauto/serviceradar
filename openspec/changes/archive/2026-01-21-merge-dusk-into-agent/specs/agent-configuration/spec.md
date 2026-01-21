# Agent Configuration - Dusk Checker Integration

## ADDED Requirements

### Requirement: Embedded Dusk Monitoring Service

The agent SHALL provide an embedded Dusk monitoring service that monitors Dusk blockchain nodes via WebSocket connections, following the same architectural pattern as sysmon and SNMP services.

#### Scenario: Dusk service disabled by default
- **GIVEN** an agent without dusk configuration
- **WHEN** the agent starts
- **THEN** the dusk service SHALL NOT start
- **AND** no WebSocket connections to Dusk nodes SHALL be attempted
- **AND** the agent SHALL log that dusk monitoring is disabled

#### Scenario: Dusk service enabled via local config
- **GIVEN** an agent with a valid `dusk.json` config file in the config directory
- **AND** the config has `enabled: true`
- **WHEN** the agent starts
- **THEN** the dusk service SHALL start
- **AND** the service SHALL establish a WebSocket connection to the configured node address
- **AND** the service SHALL subscribe to block events

#### Scenario: Dusk service reports status
- **GIVEN** a running dusk service connected to a Dusk node
- **WHEN** a status request is made for the dusk service
- **THEN** the service SHALL return block data including height, hash, and timestamp
- **AND** the status SHALL be included in the agent's push payload to the gateway

#### Scenario: Dusk service graceful shutdown
- **GIVEN** a running dusk service
- **WHEN** the agent receives a stop signal
- **THEN** the dusk service SHALL close WebSocket connections gracefully
- **AND** the service SHALL stop the event listener goroutine

---

### Requirement: Dusk Configuration Hot Reload

The agent SHALL support hot-reloading of Dusk configuration without requiring a full agent restart.

#### Scenario: Config change detected via hash comparison
- **GIVEN** a running dusk service with known config hash
- **WHEN** the config refresh loop detects a different config hash
- **THEN** the service SHALL reconfigure with the new settings
- **AND** the service SHALL log the config source and hash change

#### Scenario: Config refresh interval with jitter
- **GIVEN** a running dusk service
- **WHEN** the config refresh loop starts
- **THEN** the refresh interval SHALL include random jitter
- **AND** the jitter SHALL prevent thundering herd on config updates

---

### Requirement: Dusk Configuration via Config Compiler

The system SHALL support generating Dusk checker configuration through the config compiler when users enable dusk monitoring via the UI.

#### Scenario: UI enables dusk monitoring
- **GIVEN** a user configuring an agent via the UI
- **WHEN** they enable dusk monitoring and provide node address
- **THEN** the system SHALL create a `DuskCheckerConfig` resource
- **AND** the config compiler SHALL generate the corresponding `dusk.json`
- **AND** the agent SHALL receive the config via the config distribution endpoint

#### Scenario: Config only generated when explicitly enabled
- **GIVEN** a user who has not enabled dusk monitoring
- **WHEN** the config compiler generates agent configuration
- **THEN** no dusk config SHALL be generated
- **AND** the agent SHALL not attempt dusk monitoring

---

## MODIFIED Requirements

### Requirement: Agent Service Initialization

The agent SHALL initialize embedded services (sysmon, SNMP, dusk) during startup, with each service being optional and independently configurable.

#### Scenario: Agent initializes dusk service
- **GIVEN** an agent starting up
- **WHEN** sysmon and SNMP services have been initialized
- **THEN** the agent SHALL attempt to initialize the dusk service
- **AND** dusk initialization failure SHALL be logged as warning
- **AND** the agent SHALL continue without dusk if initialization fails

#### Scenario: Agent stops all embedded services
- **GIVEN** a running agent with dusk service enabled
- **WHEN** the agent receives a stop signal
- **THEN** the agent SHALL stop the sysmon service
- **AND** the agent SHALL stop the SNMP service
- **AND** the agent SHALL stop the dusk service
- **AND** the agent SHALL stop the mapper service
