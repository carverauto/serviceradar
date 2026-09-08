## ADDED Requirements

### Requirement: Action Launch Schema Rendering
The plugin configuration UI schema renderer SHALL support action launch forms using the same documented schema subset as plugin configuration, plus read-only target context preview fields.

#### Scenario: Launch form renders with target preview
- **GIVEN** an action descriptor includes an input schema and required target fields
- **WHEN** a user opens the action launch modal for selected devices
- **THEN** the UI renders editable fields from the input schema
- **AND** renders read-only target context preview fields owned by ServiceRadar

### Requirement: No Provider-Owned UI Code
Action descriptors SHALL NOT include executable UI code, raw HTML, JavaScript, LiveView components, or remote component references.

#### Scenario: Descriptor contains raw UI code
- **GIVEN** a plugin action descriptor includes a raw HTML or JavaScript field
- **WHEN** the descriptor is validated
- **THEN** validation fails
- **AND** the action is not launchable
