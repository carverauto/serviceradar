## MODIFIED Requirements

### Requirement: Inventory Filters Exclude Deleted Devices By Default
The system SHALL exclude tombstoned devices from default inventory reads unless explicitly requested.

#### Scenario: Default reads hide deleted devices
- **GIVEN** a device with `deleted_at` set
- **WHEN** a default device list read is executed
- **THEN** the deleted device SHALL NOT be included

#### Scenario: Include deleted devices on demand
- **GIVEN** a device with `deleted_at` set
- **WHEN** a device list read is executed with `include_deleted = true`
- **THEN** the deleted device SHALL be included

## ADDED Requirements

### Requirement: Service Check Views Hide Inactive Checks
The UI SHALL hide inactive service checks by default and provide a filter to include inactive checks.

#### Scenario: Default view excludes inactive checks
- **GIVEN** service checks marked inactive
- **WHEN** the service checks list is rendered
- **THEN** inactive checks SHALL NOT be shown

#### Scenario: Show inactive checks on demand
- **GIVEN** service checks marked inactive
- **WHEN** the user enables the "Show inactive" filter
- **THEN** inactive checks SHALL be included in the list

### Requirement: Device Delete Confirmation Shows Linked Resources
The device detail delete confirmation SHALL display linked resource counts and constraints.

#### Scenario: Delete confirmation shows linked resources
- **GIVEN** a device with linked agents or service checks
- **WHEN** the delete confirmation dialog is opened
- **THEN** the dialog SHALL show counts of linked agents and service checks
- **AND** it SHALL warn when deletion is blocked by guardrails
