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

### Requirement: Inactive devices are archival-only
ServiceRadar SHALL treat inactive devices as archival inventory records and SHALL exclude them from operational work by default.

#### Scenario: Inactive device remains visible for archival lookup
- **GIVEN** a device has `is_active = false`
- **WHEN** an operator views the device inventory or explicitly queries inactive inventory
- **THEN** the device SHALL remain queryable and visible for record keeping and history
- **AND** overall inventory counts SHALL continue to include inactive and unmanaged records unless the view is explicitly scoped to active managed usage

#### Scenario: Inactive device is not an operational target
- **GIVEN** a device has `is_active = false`
- **WHEN** ServiceRadar compiles targets for polling, sweeping, baseline diagnostics, or live camera relay startup
- **THEN** the device SHALL be excluded unless the operation is explicitly archival and non-invasive
