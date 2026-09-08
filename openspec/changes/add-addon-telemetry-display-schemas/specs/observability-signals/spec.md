## ADDED Requirements

### Requirement: Observability records preserve signal schema references
Logs and events emitted by package-backed plugins or native add-ons SHALL preserve a bounded ServiceRadar signal schema reference in storage. The reference SHALL include producer id, producer version, schema id, schema version, display contract id or path, display contract version, signal type, and payload kind when available.

#### Scenario: Add-on event stores schema reference
- **GIVEN** a native add-on emits an OCSF event with a signal schema reference
- **WHEN** the event is persisted
- **THEN** the stored event SHALL include the signal schema reference in bounded ServiceRadar metadata
- **AND** the reference SHALL be retrievable by the event detail UI

#### Scenario: Plugin log stores schema reference
- **GIVEN** a plugin emits an OTEL log with a signal schema reference
- **WHEN** the log is persisted
- **THEN** the stored log SHALL include the signal schema reference in bounded ServiceRadar metadata
- **AND** the reference SHALL be retrievable by the log detail UI

### Requirement: Wasm plugins emit first-class telemetry
Wasm plugins that declare the telemetry capability SHALL be able to emit OCSF events and OTEL-style logs through a dedicated host function without coupling those signals to `serviceradar.plugin_result.v1`.

#### Scenario: Plugin emits telemetry outside check result
- **GIVEN** a Wasm plugin package declares the telemetry host capability
- **WHEN** the plugin emits an OCSF event telemetry batch
- **THEN** the agent SHALL forward the batch as plugin telemetry
- **AND** core SHALL publish the event to the generic event ingestion stream with agent-attested provenance

### Requirement: Signal schemas describe presentation without changing canonical payloads
Signal schemas and display contracts SHALL describe the producer payload and presentation mapping without replacing canonical OCSF or OTEL storage semantics. OCSF events SHALL remain valid OCSF payloads, and OTEL logs SHALL preserve OTEL log fields.

#### Scenario: OCSF event keeps canonical shape
- **GIVEN** a package emits an OCSF event with a display contract
- **WHEN** the event is stored
- **THEN** the event SHALL retain its canonical OCSF fields
- **AND** display metadata SHALL NOT be used to redefine tenant scope, severity classification, or storage destination

### Requirement: Historical records remain viewable without schemas
The observability UI SHALL continue to support logs and events that do not include signal schema references.

#### Scenario: Older event has no schema reference
- **GIVEN** an existing OCSF event was stored before signal schema references existed
- **WHEN** a user opens the event detail view
- **THEN** the UI SHALL render the generic detail view
- **AND** the missing schema reference SHALL NOT prevent querying or viewing the event
