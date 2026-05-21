## ADDED Requirements

### Requirement: Device monitoring tab exposes eligible checks
The device details UI SHALL provide a monitoring workflow that shows eligible built-in and plugin check capabilities for the current device.

#### Scenario: Add database check from device details
- **GIVEN** a device is tagged `role=db`
- **AND** a PostgreSQL availability capability is approved
- **WHEN** an authorized operator opens the device Monitoring tab
- **THEN** the UI SHALL show the eligible database check capability
- **AND** creating the check SHALL use the current device context without requiring the operator to type or paste the device identifier

### Requirement: Service inventory supports operator-scale monitoring
The web UI SHALL provide a service inventory for monitored services with dense filtering, grouping, status, tags, associated device, check count, and bulk actions.

#### Scenario: Filter service inventory by group and state
- **GIVEN** monitored services exist across several groups and states
- **WHEN** an operator filters by group `noc-critical` and state `critical`
- **THEN** the service inventory SHALL show only matching services
- **AND** bulk actions SHALL operate on the filtered/selected service set

### Requirement: Target selection uses searchable modal pickers
The web UI SHALL use searchable modal pickers for large device and service selections instead of limited dropdowns or free-form text fields.

#### Scenario: Search for device target
- **GIVEN** the deployment has thousands of devices
- **WHEN** an operator adds explicit device targets to a binding
- **THEN** the UI SHALL open a searchable picker with filters, pagination, selected-count state, and preview details
- **AND** it SHALL not cap the usable selection set to the first 200 devices

### Requirement: Monitoring binding form includes event and alert policy
The monitoring binding form SHALL let operators configure result-to-event and event-to-alert behavior in the same workflow as target, schedule, threshold, and credential selection.

#### Scenario: Configure alert promotion while creating check
- **GIVEN** an operator creates an HTTP service binding
- **WHEN** they select "alert after 3 critical results in 5 minutes"
- **THEN** the saved binding SHALL include event emission and alert promotion policy
- **AND** check results SHALL use that policy after assignment materialization

