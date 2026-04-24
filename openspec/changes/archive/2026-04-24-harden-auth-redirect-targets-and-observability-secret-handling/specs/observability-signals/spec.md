## ADDED Requirements
### Requirement: Observability external feed secrets are not exposed through routine logging
Background observability refresh workflows MUST avoid exposing secret-bearing threat-intel feed URLs or tokens through routine logs.

#### Scenario: Threat-intel feed URL contains credentials
- **GIVEN** a configured threat-intel feed URL contains query-string credentials or userinfo
- **WHEN** the refresh worker logs a start or failure event
- **THEN** the system SHALL redact the sensitive URL components
- **AND** SHALL preserve only bounded non-sensitive context needed for diagnosis
