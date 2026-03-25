## ADDED Requirements
### Requirement: Secret reference fields for plugin credentials
The plugin configuration UI SHALL support secret reference fields for credentials required by camera plugins.

#### Scenario: Save AXIS credentials via secret reference
- **GIVEN** an AXIS plugin config schema that marks password fields as secret references
- **WHEN** an operator saves plugin configuration
- **THEN** the stored config SHALL reference a secret ID/name
- **AND** the raw secret value SHALL NOT be echoed in API responses or UI payloads

### Requirement: Auth metadata and credential linkage validation
The system SHALL validate that stream authentication configuration is internally consistent.

#### Scenario: Auth-required stream without credential reference
- **GIVEN** plugin configuration requiring authenticated stream access
- **WHEN** no credential reference is provided
- **THEN** validation SHALL fail with a field-level error

#### Scenario: Public stream mode without credential reference
- **GIVEN** plugin configuration for unauthenticated stream interrogation only
- **WHEN** no credential reference is provided
- **THEN** validation SHALL succeed
