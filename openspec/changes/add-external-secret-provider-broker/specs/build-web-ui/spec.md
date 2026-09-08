## ADDED Requirements

### Requirement: Credentials UI supports external providers
The credentials settings UI SHALL include external secret providers, external secret references, reference tests, health, and consumer visibility without exposing secret values.

#### Scenario: Create external reference
- **GIVEN** an authorized admin has configured an external provider
- **WHEN** they create a credential reference
- **THEN** the form SHALL ask for provider, object/path, field mapping, credential kind, version policy, and cache/lease policy
- **AND** it SHALL not display the resolved secret value after save or test

#### Scenario: Test reference through agent
- **GIVEN** a provider is configured for agent-side resolution
- **WHEN** an admin tests a reference
- **THEN** the UI SHALL require selecting or deriving an eligible agent/site
- **AND** it SHALL show only redacted status, error class, and timing metadata

### Requirement: Credential consumers show source type
Credential consumer views SHALL show whether a credential is internally stored or externally referenced while preserving sensitive provider metadata.

#### Scenario: Plugin consumer uses external reference
- **GIVEN** a plugin assignment uses an external credential reference
- **WHEN** an admin views credential consumers
- **THEN** the UI SHALL show the plugin/binding consumer and source type `external_reference`
- **AND** it SHALL not expose resolved secret values or provider bootstrap credentials

