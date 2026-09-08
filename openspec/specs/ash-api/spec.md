# ash-api Specification

## Purpose
TBD - created by archiving change integrate-ash-framework. Update Purpose after archive.
## Requirements
### Requirement: JSON:API Compliance
The system SHALL provide JSON:API compliant endpoints via AshJsonApi for all Ash resources.

#### Scenario: JSON:API resource response
- **WHEN** a client requests GET /api/v2/devices/123
- **THEN** the response SHALL conform to JSON:API specification
- **AND** include type, id, attributes, and relationships fields
- **AND** use Content-Type: application/vnd.api+json

#### Scenario: JSON:API pagination
- **WHEN** a client requests a collection with pagination
- **THEN** the response SHALL include pagination links (first, last, prev, next)
- **AND** support both keyset and offset pagination via query parameters

### Requirement: API Versioning
The system SHALL support API versioning with v2 endpoints alongside existing v1.

#### Scenario: V2 API mounting
- **WHEN** the application starts
- **THEN** Ash-powered endpoints SHALL be available at /api/v2/*
- **AND** existing v1 endpoints SHALL remain functional at /api/*

#### Scenario: V1 API deprecation
- **WHEN** a client uses v1 API endpoints
- **THEN** the response SHALL include Deprecation and Sunset headers
- **AND** document migration path to v2

### Requirement: SRQL to Ash Query Translation
The system SHALL translate SRQL queries to Ash.Query operations where applicable.

#### Scenario: SRQL device query via Ash
- **GIVEN** an SRQL query "in:devices hostname:%server% limit:50"
- **WHEN** the query is executed
- **THEN** the system SHALL route through Ash.Query
- **AND** apply tenant isolation policies automatically
- **AND** return results in SRQL response format

#### Scenario: SRQL metrics query via SQL
- **GIVEN** an SRQL query "in:metrics time:last_24h bucket:5m"
- **WHEN** the query is executed
- **THEN** the system SHALL route through the SQL/Rust NIF path
- **AND** apply time bucketing via TimescaleDB functions

### Requirement: AshPhoenix Form Integration
The system SHALL use AshPhoenix.Form for LiveView form handling with Ash resources.

#### Scenario: Device edit form
- **WHEN** a user edits a device in LiveView
- **THEN** the form SHALL use AshPhoenix.Form
- **AND** validation errors SHALL appear in real-time
- **AND** form submission SHALL invoke the Ash update action

### Requirement: API Error Handling
The system SHALL return consistent, informative error responses for API failures.

#### Scenario: Authorization error response
- **WHEN** a user attempts an unauthorized action via API
- **THEN** the response SHALL return 403 Forbidden
- **AND** include a JSON:API error object with title and detail

#### Scenario: Validation error response
- **WHEN** a resource creation/update fails validation
- **THEN** the response SHALL return 422 Unprocessable Entity
- **AND** include JSON:API error objects for each validation failure
- **AND** include source pointer to the invalid field

