## ADDED Requirements

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
The system SHALL validate submitted configuration values against the `config_schema` and reject invalid inputs with field-level errors.

#### Scenario: Invalid input rejected
- **WHEN** a user submits configuration values that violate the schema
- **THEN** the save is rejected and validation errors are displayed

### Requirement: Backward-compatible fallback
The system SHALL allow configuration for plugin package versions without a `config_schema` using the generic key/value editor.

#### Scenario: No schema present
- **WHEN** a plugin package version lacks a `config_schema`
- **THEN** the UI falls back to the generic configuration editor
