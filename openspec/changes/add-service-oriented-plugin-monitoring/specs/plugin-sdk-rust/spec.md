## ADDED Requirements

### Requirement: Rust SDK check descriptor APIs
The Rust plugin SDK SHALL provide APIs equivalent to the Go SDK for declaring check capability descriptors with target kinds, required fields, credential requirements, schedule bounds, threshold schema, and result schema version.

#### Scenario: Rust plugin declares database availability check
- **GIVEN** a Rust Wasm plugin uses the SDK to declare `postgres.availability`
- **WHEN** the descriptor fixture is serialized
- **THEN** it SHALL match the shared descriptor schema used by Go SDK fixtures

### Requirement: Rust SDK normalized target input APIs
The Rust plugin SDK SHALL provide helpers to decode descriptor-aware target batches from plugin input payloads.

#### Scenario: Rust plugin reads service and device context
- **GIVEN** a target payload includes a service associated with a device
- **WHEN** the Rust plugin decodes the payload
- **THEN** it can access monitored service ID, check instance ID, device UID, endpoint fields, thresholds, and credential grant references without manual JSON traversal

### Requirement: Rust SDK target-scoped result APIs
The Rust plugin SDK SHALL provide helpers for emitting one result per target with status, metrics, response time, event candidates, and redacted details.

#### Scenario: Rust plugin emits target-scoped result
- **GIVEN** a Rust plugin completes a database availability check
- **WHEN** it builds the result through the SDK
- **THEN** the serialized payload SHALL include the check instance ID, monitored service ID, status, response time, and metrics in the shared target-scoped result schema

### Requirement: Cross-SDK fixture parity
The Go and Rust SDKs SHALL share descriptor, input, and result fixture files for service-oriented monitoring contracts.

#### Scenario: Fixture parity test passes
- **GIVEN** equivalent Go and Rust descriptor definitions
- **WHEN** their fixture outputs are compared
- **THEN** the normalized JSON SHALL match aside from explicitly ignored ordering differences

