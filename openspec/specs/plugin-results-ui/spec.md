# plugin-results-ui Specification

## Purpose
TBD - created by archiving change add-plugin-config-ui. Update Purpose after archive.
## Requirements
### Requirement: Plugin result display contract
The system SHALL accept a plugin-defined display contract (declared on the plugin package/version) that describes the supported result widgets and their schema version.

#### Scenario: Display contract stored
- **WHEN** a plugin package version includes a display contract
- **THEN** the contract is stored and retrievable with that package version

### Requirement: Runtime result instructions
The system SHALL accept plugin result payloads that include runtime display instructions with data for supported widgets.

#### Scenario: Dynamic widget instructions
- **WHEN** a plugin result payload includes display instructions
- **THEN** the Services UI renders widgets based on those instructions using the stored display contract and schema version

### Requirement: Widget instruction rendering
The Services UI SHALL render plugin results using a registry of supported widgets driven by plugin-provided display instructions, without executing plugin-supplied HTML or JavaScript.

#### Scenario: Safe widget rendering
- **WHEN** plugin results include display instructions for supported widgets
- **THEN** the UI renders the corresponding widgets using server-owned templates

#### Scenario: Unknown widget ignored
- **WHEN** plugin results include an unsupported widget type
- **THEN** the UI skips that widget and logs a warning

### Requirement: Services page custom result rendering
The Services page SHALL render plugin check results using the stored display contract when present, and fall back to the generic view otherwise.

#### Scenario: Custom result view
- **WHEN** a user opens a service check whose plugin package includes a display contract
- **THEN** the UI renders the results using the specified widgets and mappings

#### Scenario: Fallback result view
- **WHEN** a user opens a service check whose plugin package has no display contract
- **THEN** the UI renders the generic result view

