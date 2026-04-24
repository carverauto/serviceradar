## ADDED Requirements

### Requirement: Device details flows tab uses SRQL
The device details UI SHALL fetch flows via SRQL `in:flows device_id:"<device_uid>"` and SHALL display a `Flows` tab only when SRQL returns flow rows for that device scope.

#### Scenario: Flows tab visible
- **GIVEN** the device has exporter-owned or endpoint-matching flow data in the SRQL `device_id` scope
- **WHEN** the device details page loads
- **THEN** the `Flows` tab is visible
- **AND** the flows tab renders rows from the SRQL response

#### Scenario: Flows tab hidden
- **GIVEN** SRQL returns no flow rows for the current device
- **WHEN** the device details page loads
- **THEN** the `Flows` tab is hidden

### Requirement: Device details flows table supports pagination and drill-in
The device details `Flows` tab SHALL present a paginated flow table and SHALL reuse the existing flow details UI when a row is selected.

#### Scenario: Paginated flow rows
- **GIVEN** SRQL returns more flow rows than fit on one page
- **WHEN** the operator navigates between pages in the `Flows` tab
- **THEN** the UI fetches and renders only the requested page of rows
- **AND** preserves the selected device scope in each query

#### Scenario: Row selection opens flow details
- **GIVEN** a flow row is visible in the `Flows` tab
- **WHEN** the operator selects the row
- **THEN** the existing flow details UI is opened for that flow record
- **AND** the user can return to the device details context without losing selected tab state
