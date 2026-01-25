## ADDED Requirements

### Requirement: Plugin result display contract
The system SHALL accept a plugin-defined display contract that describes how to render plugin check results in the Services UI.

#### Scenario: Display contract stored
- **WHEN** a plugin package version includes a display contract
- **THEN** the contract is stored and retrievable with that package version

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
