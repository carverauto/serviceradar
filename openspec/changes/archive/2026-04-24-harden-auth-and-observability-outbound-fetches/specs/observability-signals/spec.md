## ADDED Requirements
### Requirement: Observability feed refreshes use bounded outbound fetch policy
Background refreshes for observability reference datasets and feeds MUST validate configured remote source URLs before any network fetch. Refresh workers MUST allow only documented HTTPS sources and MUST reject invalid, loopback, link-local, private, or otherwise disallowed destinations.

#### Scenario: Threat intel feed URL targets a private address
- **GIVEN** observability settings contain a threat-intel feed URL that resolves to a private address
- **WHEN** the refresh worker attempts to fetch the feed
- **THEN** the system SHALL reject the fetch before issuing the HTTP request
- **AND** SHALL log an explicit bounded failure reason

#### Scenario: Dataset refresh source uses a documented public HTTPS endpoint
- **GIVEN** a dataset refresh worker is configured with its documented public HTTPS source
- **WHEN** the refresh runs
- **THEN** the system SHALL allow the fetch to proceed
- **AND** SHALL continue processing the dataset normally
