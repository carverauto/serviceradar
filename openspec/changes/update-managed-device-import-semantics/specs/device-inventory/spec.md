## ADDED Requirements
### Requirement: Managed device import semantics
ServiceRadar SHALL treat `ocsf_devices.is_managed` as managed inventory estate membership and SHALL treat `ocsf_devices.is_active` as current in-service lifecycle state.

#### Scenario: New imported device becomes active managed inventory
- **GIVEN** an authoritative inventory import creates a new device
- **WHEN** the device is persisted
- **THEN** the device SHALL default to `is_managed = true`
- **AND** the device SHALL default to `is_active = true`

#### Scenario: Re-import preserves operator managed state
- **GIVEN** an existing device has `is_managed = false` due to an operator or source-owned update
- **WHEN** an authoritative inventory import observes that device again
- **THEN** the import SHALL NOT force `is_managed` back to true by default
- **AND** other imported enrichment fields MAY still be updated according to existing reconciliation rules

#### Scenario: Re-import preserves inactive lifecycle state
- **GIVEN** an existing device has `is_active = false`
- **WHEN** an authoritative inventory import observes that device again
- **THEN** the import SHALL NOT force `is_active` back to true by default
- **AND** the device SHALL remain visible in inventory history

#### Scenario: Operator active lifecycle does not rewrite managed membership
- **GIVEN** an existing device has a managed membership value
- **WHEN** an authorized operator marks the device active or inactive
- **THEN** only `is_active` SHALL change
- **AND** `is_managed` SHALL remain unchanged
