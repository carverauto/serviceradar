## ADDED Requirements

### Requirement: Versioned OpenAPI Artifact Publishing
The system SHALL publish a versioned OpenAPI artifact for supported ServiceRadar API surfaces so external documentation consumers can use ServiceRadar as the source of truth.

#### Scenario: Canonical OpenAPI artifact is published
- **WHEN** a supported ServiceRadar version is built or prepared for publication
- **THEN** a machine-readable OpenAPI artifact exists at the defined stable path for that version
- **AND** external documentation consumers do not need to reconstruct the API contract manually

### Requirement: OpenAPI Artifact Is Suitable For Developer Portal Consumption
The system SHALL make the published OpenAPI artifact available through a stable consumption path that the developer portal can fetch.

#### Scenario: Developer portal fetches canonical API spec
- **WHEN** the developer portal fetches the configured OpenAPI artifact for a supported ServiceRadar version
- **THEN** the artifact is retrievable from the defined stable source
- **AND** the artifact does not require an interactive admin session to be consumed for docs presentation

### Requirement: Published OpenAPI Artifact Is Validated
The system SHALL validate the published OpenAPI artifact in automated checks.

#### Scenario: CI validates OpenAPI artifact
- **WHEN** CI runs for a change that affects the published OpenAPI contract or its publication path
- **THEN** CI fails if the artifact is missing, malformed, or inconsistent with the defined publishing contract
