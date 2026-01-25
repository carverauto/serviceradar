## ADDED Requirements
### Requirement: SRQL builder query assembly
The SRQL builder SHALL generate a valid SRQL query string for supported entities without raising runtime errors while applying filters, sort, and limit tokens.

#### Scenario: Devices default query includes sort and limit
- **GIVEN** the SRQL builder default state for the devices entity
- **WHEN** the builder generates the query string
- **THEN** the query string includes `in:devices`
- **AND** the query string includes a `sort:last_seen:desc` token
- **AND** the query string includes a `limit:<n>` token

#### Scenario: Logs default query includes sort and limit
- **GIVEN** the SRQL builder default state for the logs entity
- **WHEN** the builder generates the query string
- **THEN** the query string includes `in:logs`
- **AND** the query string includes a `sort:timestamp:desc` token
- **AND** the query string includes a `limit:<n>` token

#### Scenario: Filters preserve sort assembly
- **GIVEN** the SRQL builder state includes a filter row
- **WHEN** the builder generates the query string
- **THEN** the query string includes the filter token
- **AND** the query string includes the configured sort token
- **AND** the query string includes the configured limit token
