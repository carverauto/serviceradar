## MODIFIED Requirements
### Requirement: Plugin Package Storage Backends

The system SHALL store plugin packages using a configured backend and expose them through the web-ng API for agent download.

#### Scenario: Filesystem-backed storage
- **GIVEN** the storage backend is configured as filesystem
- **WHEN** a package is uploaded
- **THEN** the package is stored under the configured path
- **AND** the web-ng API serves the package by reference ID

#### Scenario: JetStream object storage
- **GIVEN** the storage backend is configured as NATS JetStream object storage
- **WHEN** a package is uploaded
- **THEN** the package is written to the JetStream object store
- **AND** the web-ng API serves the package by object key

#### Scenario: GitHub repository source
- **GIVEN** a plugin package is configured to be sourced from a GitHub repository
- **WHEN** core fetches the package
- **THEN** core stores the package in the configured backend
- **AND** the web-ng API serves the package by reference ID

#### Scenario: Plugin blob token in header or body
- **GIVEN** a client holds a valid short-lived plugin blob token
- **WHEN** the client uploads or downloads a plugin blob through the public blob API
- **THEN** the token SHALL be accepted only from the explicit plugin-token header or POST body

#### Scenario: Plugin blob query-string token rejected
- **GIVEN** a client supplies a valid plugin blob token only in the URL query string
- **WHEN** the client calls the public plugin blob API
- **THEN** the request SHALL be rejected as unauthorized
- **AND** the query-string token SHALL NOT be treated as a valid credential source
