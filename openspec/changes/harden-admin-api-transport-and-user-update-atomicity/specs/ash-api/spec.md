## ADDED Requirements
### Requirement: Admin API Path Parameters Are Safely Encoded
The system SHALL URL-encode admin API path parameters before issuing internal HTTP requests so opaque identifiers cannot alter request routing.

#### Scenario: Encoded user ID in admin API request
- **GIVEN** an admin API HTTP adapter call with a user ID containing reserved URL path characters
- **WHEN** the internal request path is built
- **THEN** the ID SHALL be URL-encoded as a path segment
- **AND** the request SHALL remain scoped to the intended admin API endpoint

### Requirement: Admin User Listing Uses Bounded Limits
The system SHALL clamp admin user listing limits to a safe maximum and SHALL accept integer limit values without crashing.

#### Scenario: Oversized list limit is clamped
- **GIVEN** an admin user list request with an excessively large `limit`
- **WHEN** the query is built
- **THEN** the applied limit SHALL be capped to a configured safe maximum

#### Scenario: Integer list limit is accepted
- **GIVEN** an admin user list request where `limit` is already an integer
- **WHEN** the query is built
- **THEN** the system SHALL use the integer value safely
- **AND** SHALL NOT raise a function clause error
