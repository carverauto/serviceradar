## ADDED Requirements

### Requirement: Plugin check configuration uses selectors instead of free-form target entry
The plugin configuration UI SHALL prefer service, device, group, tag, and SRQL selectors over free-form target entry when configuring check-style plugins.

#### Scenario: Configure plugin check from service selector
- **GIVEN** an approved plugin exposes a service-scoped check descriptor
- **WHEN** an operator configures monitoring for that descriptor
- **THEN** the UI SHALL offer service groups, service tags, explicit service selection, and SRQL-backed selectors
- **AND** it SHALL NOT require typing service IDs or device IDs in the default path

#### Scenario: Device picker handles large inventories
- **GIVEN** inventory contains more than 200 devices
- **WHEN** an operator selects explicit device targets
- **THEN** the UI SHALL open a searchable, filterable, paginated modal picker
- **AND** it SHALL NOT silently limit selection to the first 200 devices

### Requirement: Plugin capability catalog is operator-facing
The UI SHALL show approved plugin check capabilities with human-readable names, target kinds, credential needs, compatible service types, and unavailable reasons.

#### Scenario: Capability unavailable due to credentials
- **GIVEN** a database availability descriptor requires credentials
- **WHEN** no compatible credential rule or override exists for selected targets
- **THEN** the UI SHALL show the capability as needing credentials
- **AND** provide a path to create or select a compatible unified credential

### Requirement: Bulk target workflows are first-class
The UI SHALL provide bulk workflows for creating and binding large numbers of service targets.

#### Scenario: Paste many URLs into service import
- **GIVEN** an operator pastes 200 URLs into a bulk import flow
- **WHEN** validation completes
- **THEN** the UI SHALL show a review table with validation results and proposed tags/groups
- **AND** the operator SHALL be able to create the services and bind a selected HTTP check in one guided flow

