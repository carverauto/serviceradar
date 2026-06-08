## ADDED Requirements

### Requirement: Plugin and add-on signal display contracts
Any plugin or native add-on package that emits logs or events SHALL declare a display contract for each emitted signal schema as part of the package/version metadata. The display contract SHALL be declarative, versioned, and limited to platform-supported widgets and field mappings; it SHALL NOT include producer-supplied HTML, JavaScript, CSS, SQL, or executable transforms.

#### Scenario: Event-emitting add-on declares display contract
- **GIVEN** a native add-on package emits OCSF events
- **WHEN** the package is validated or registered
- **THEN** the package SHALL include a signal schema entry for that event type
- **AND** the entry SHALL reference a display contract stored with that package version

#### Scenario: Log-emitting plugin declares display contract
- **GIVEN** a plugin package emits OTEL logs
- **WHEN** the package is validated or registered
- **THEN** the package SHALL include a signal schema entry for that log type
- **AND** the entry SHALL reference a display contract stored with that package version

### Requirement: Schema-driven log and event rendering
The web UI SHALL render plugin/add-on generated logs and events using the signal display contract referenced by the stored record when a compatible contract is available, and SHALL fall back to the generic record detail view when no compatible contract is available.

#### Scenario: Event detail uses referenced display contract
- **GIVEN** an OCSF event includes a ServiceRadar signal schema reference
- **AND** the referenced package/version display contract is available
- **WHEN** a user opens the event detail view
- **THEN** the UI SHALL render the event using platform-owned widgets described by the display contract
- **AND** the UI SHALL NOT require a producer-specific event component

#### Scenario: Missing display contract falls back safely
- **GIVEN** an event includes a schema reference that cannot be resolved
- **WHEN** a user opens the event detail view
- **THEN** the UI SHALL render the generic event detail view
- **AND** raw JSON MAY be shown in a collapsible fallback section

### Requirement: Safe display contract widget subset
The web UI SHALL support a bounded set of display widgets for log/event contracts, including summary, facts, badges, timeline, and selected JSON sections. Unknown widgets SHALL be skipped and reported through UI/server telemetry without preventing the rest of the record from rendering.

#### Scenario: Unsupported widget is skipped
- **GIVEN** a display contract contains a widget type the current UI does not support
- **WHEN** the UI renders a log or event with that contract
- **THEN** the unsupported widget SHALL be skipped
- **AND** supported widgets in the same contract SHALL still render
