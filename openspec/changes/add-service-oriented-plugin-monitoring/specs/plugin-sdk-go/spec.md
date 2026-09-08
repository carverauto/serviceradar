## ADDED Requirements

### Requirement: Go SDK check descriptor APIs
The Go plugin SDK SHALL provide APIs for declaring check capability descriptors with target kinds, required target fields, credential requirements, schedule bounds, threshold schema, and result schema version.

#### Scenario: Go plugin declares URL availability check
- **GIVEN** a Go Wasm plugin uses the SDK to declare `http.url.availability`
- **WHEN** the package manifest or descriptor fixture is generated
- **THEN** the descriptor SHALL include service target kind, required URL field, HTTP host capability, timeout bounds, and target-scoped result schema version

### Requirement: Go SDK normalized target input APIs
The Go plugin SDK SHALL provide helpers to decode descriptor-aware target batches from plugin input payloads.

#### Scenario: Go plugin iterates target contexts
- **GIVEN** the agent invokes a Go plugin with a descriptor-aware payload
- **WHEN** the plugin decodes inputs through the SDK
- **THEN** it can iterate target contexts containing check instance ID, monitored service ID, optional device UID, endpoint fields, thresholds, and credential grant references

### Requirement: Go SDK target-scoped result APIs
The Go plugin SDK SHALL provide helpers for emitting one result per target with status, metrics, response time, event candidates, and redacted details.

#### Scenario: Go plugin returns mixed batch statuses
- **GIVEN** a Go plugin checks three URL services in one execution
- **WHEN** one URL is critical and two are OK
- **THEN** the SDK SHALL serialize three target-scoped results
- **AND** each result SHALL carry the corresponding check instance ID

