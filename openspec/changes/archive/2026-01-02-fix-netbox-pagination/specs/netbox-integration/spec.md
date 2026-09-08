## ADDED Requirements

### Requirement: Paginated device discovery
The NetBox integration SHALL fetch and process all devices returned by the NetBox API, following pagination links until all pages are retrieved.

#### Scenario: Multiple pages returned
- **GIVEN** the NetBox API response includes a non-empty `next` URL
- **WHEN** the sync service runs NetBox discovery
- **THEN** it SHALL request each subsequent page until `next` is empty
- **AND** it SHALL process devices from all pages as discovery output

#### Scenario: Single page returned
- **GIVEN** the NetBox API response includes an empty `next` URL
- **WHEN** the sync service runs NetBox discovery
- **THEN** it SHALL process the returned page and complete successfully

### Requirement: Pagination failures do not produce partial output
The NetBox integration SHALL fail the discovery or reconciliation operation if any paginated request fails, rather than producing partial results.

#### Scenario: Page fetch fails during discovery
- **GIVEN** at least one page of devices has been retrieved and `next` is non-empty
- **WHEN** requesting a subsequent page fails (non-200 response or decode error)
- **THEN** the discovery operation SHALL return an error
- **AND** it SHALL NOT emit partial discovery results

#### Scenario: Page fetch fails during reconciliation
- **GIVEN** at least one page of devices has been retrieved and `next` is non-empty
- **WHEN** requesting a subsequent page fails (non-200 response or decode error)
- **THEN** the reconciliation operation SHALL return an error
- **AND** it SHALL NOT submit retraction events

### Requirement: Reconciliation uses complete NetBox inventory
The reconciliation operation SHALL use the complete current device set from NetBox (across all pages) when determining retractions.

#### Scenario: Paginated inventory during reconciliation
- **GIVEN** NetBox device inventory spans multiple pages
- **WHEN** reconciliation runs after sweep completion
- **THEN** it SHALL include devices from all pages when determining which devices still exist
- **AND** it SHALL only retract devices absent from the complete set

### Requirement: Pagination telemetry is accurate
The NetBox integration SHALL report discovery and reconciliation counts based on the total devices processed across all pages.

#### Scenario: Discovery logs total devices
- **GIVEN** NetBox returns device inventory over multiple pages
- **WHEN** discovery completes successfully
- **THEN** the integration SHALL log the total devices processed (not just the first page)

