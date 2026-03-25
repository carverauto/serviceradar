# plugin-configuration-ui Specification

## Purpose
TBD - created by archiving change add-plugin-config-ui. Update Purpose after archive.
## Requirements
### Requirement: Plugin configuration schema
The system SHALL accept a plugin `config_schema` document (JSON Schema) as part of a plugin package version and persist it for use by the UI.

#### Scenario: Schema stored with package
- **WHEN** a plugin package version includes a `config_schema`
- **THEN** the schema is stored and retrievable with that package version

### Requirement: Dynamic configuration form
The web UI SHALL render plugin configuration forms from the stored `config_schema` using a documented schema subset.

#### Scenario: Schema-driven form rendering
- **WHEN** an operator opens the configuration UI for a plugin package version that has a `config_schema`
- **THEN** the UI renders input fields that match the schema definition and required fields

### Requirement: Schema validation on save
The system SHALL validate submitted configuration values against the `config_schema` in the Ash layer and reject invalid inputs with field-level errors.

#### Scenario: Invalid input rejected
- **WHEN** a user submits configuration values that violate the schema
- **THEN** the save is rejected and validation errors are displayed

### Requirement: Backward-compatible fallback
The system SHALL allow configuration for plugin package versions without a `config_schema` using the generic key/value editor.

#### Scenario: No schema present
- **WHEN** a plugin package version lacks a `config_schema`
- **THEN** the UI falls back to the generic configuration editor

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

