# Device Discovery Flow

## MODIFIED Requirements

### Requirement: Device data stored in CNPG via DIRE
Discovered devices MUST be written via DIRE into the tenant schema in CNPG. No separate discovered_devices staging table is required for this change.

#### Scenario: Agent sync sends device updates
- **GIVEN** a tenant agent discovers devices from an integration
- **WHEN** the agent streams results via StreamStatus
- **THEN** the updates are routed through DIRE
- **AND** canonical device records are stored in the tenant schema

## REMOVED Requirements

### Requirement: Discovered device staging table
**Reason**: DIRE is the source of truth for canonical device records and staging is out of scope.
**Migration**: Remove reliance on discovered_devices for sync processing.

#### Scenario: No discovered_devices staging required
- **GIVEN** a sync device update
- **WHEN** it is ingested
- **THEN** it is processed directly through DIRE
- **AND** no discovered_devices staging write is required

### Requirement: Sweep config generation from discovered devices
**Reason**: Sweep configuration is out of scope for this change.
**Migration**: Continue existing sweep behavior until a dedicated sweep proposal is approved.

#### Scenario: GetConfig does not include sweep targets from sync
- **GIVEN** device updates from sync
- **WHEN** an agent calls GetConfig
- **THEN** sweep config is not generated from sync results in this change

### Requirement: Agent sweep config application
**Reason**: Sweep configuration is out of scope for this change.
**Migration**: Keep existing sweep configuration behavior unchanged.

#### Scenario: Agent does not alter sweep behavior
- **GIVEN** an agent with existing sweep configuration
- **WHEN** sync updates are processed
- **THEN** sweep configuration behavior remains unchanged
