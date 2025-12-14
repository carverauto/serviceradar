## ADDED Requirements

### Requirement: UI-managed mapper discovery configuration
ServiceRadar MUST provide an admin UI workflow to configure mapper discovery inputs (including seed routers) and persist them via the Core API as the authoritative source of truth.

#### Scenario: Admin configures seed routers for discovery
- **GIVEN** an authenticated admin user
- **WHEN** the admin adds or removes seed router addresses from Network → Discovery
- **THEN** Core SHALL persist the updated mapper discovery configuration (via the mapper configuration API surface)
- **AND** the persisted configuration SHALL be used as the source of truth for mapper discovery runs
- **AND** sensitive fields (credentials, API keys, secrets) SHALL be redacted in any API response returned to the browser

### Requirement: Per-interface SNMP metric polling control
ServiceRadar MUST allow an authenticated admin to enable or disable SNMP metric polling for a discovered interface via the UI.

#### Scenario: Enable SNMP polling for a discovered interface
- **GIVEN** an authenticated admin user viewing Network → Discovery
- **AND** an interface is present in discovery results with a stable identifier (e.g., `device_id` + `if_index`)
- **WHEN** the admin enables SNMP polling for that interface
- **THEN** Core SHALL persist an “SNMP polling enabled” preference for that interface in KV
- **AND** the effective SNMP polling configuration SHALL be updated to include that interface for polling

#### Scenario: Disable SNMP polling for a discovered interface
- **GIVEN** an authenticated admin user viewing Network → Discovery
- **AND** SNMP polling is enabled for a discovered interface
- **WHEN** the admin disables SNMP polling for that interface
- **THEN** Core SHALL persist an “SNMP polling disabled” preference for that interface in KV
- **AND** the effective SNMP polling configuration SHALL be updated to exclude that interface from polling

### Requirement: Configuration propagation visibility
ServiceRadar MUST make it observable whether configuration changes have been applied by the running mapper and SNMP checker services.

#### Scenario: UI indicates restart requirement
- **GIVEN** a configuration change has been persisted by Core
- **AND** the running mapper and/or SNMP checker has not applied the latest config
- **WHEN** an admin views the relevant configuration surfaces in the UI
- **THEN** the UI SHALL indicate that a restart is required (or that the change is pending application)
