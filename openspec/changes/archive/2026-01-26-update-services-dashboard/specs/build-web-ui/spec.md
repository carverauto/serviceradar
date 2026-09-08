## MODIFIED Requirements

### Requirement: Services dashboard shows latest health per service
The `/services` dashboard SHALL compute summary counts from the **latest status per service identity** instead of aggregating all historical status entries.

#### Scenario: Summary reflects latest status per service
- **GIVEN** multiple service status entries for the same service identity
- **WHEN** the `/services` dashboard renders
- **THEN** the summary counts include only the latest status per service identity

### Requirement: Services dashboard live updates
The `/services` dashboard SHALL refresh its summary and lists when new service status events arrive.

#### Scenario: Live updates without manual refresh
- **GIVEN** the `/services` dashboard is open
- **WHEN** a new service status is ingested
- **THEN** the dashboard updates the summary metrics automatically

## REMOVED Requirements

### Requirement: Gateways section on Services dashboard
The `/services` dashboard SHALL NOT include a gateways list/section.

#### Scenario: Gateways section removed
- **WHEN** the `/services` dashboard renders
- **THEN** no gateways section is displayed

## ADDED Requirements

### Requirement: Status distribution by check replaces service-type card
The `/services` dashboard SHALL show a status distribution by check in place of the service-type summary.

#### Scenario: Status distribution by check
- **GIVEN** multiple services with varying statuses
- **WHEN** the dashboard renders
- **THEN** the widget groups counts by check/service name and status
