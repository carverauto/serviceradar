## ADDED Requirements
### Requirement: Results ingestion uses gRPC/ERTS routing
The system SHALL ingest sync and sweep results through the gRPC/ERTS results pipeline, with agent-gateway forwarding results directly to core without requiring NATS for ingestion.

#### Scenario: Sync results ingestion via gRPC
- **GIVEN** an agent streams sync results through the gateway
- **WHEN** the gateway forwards the results to core
- **THEN** core SHALL enqueue the sync payload through the results ingestion pipeline
- **AND** the ingest SHALL succeed without NATS dependencies

#### Scenario: Sweep results ingestion via gRPC
- **GIVEN** an agent streams sweep results through the gateway
- **WHEN** the gateway forwards the results to core
- **THEN** core SHALL ingest sweep data and update device inventory
- **AND** the ingest SHALL succeed without NATS dependencies

### Requirement: Results routing is explicit by result type
The core results pipeline SHALL route sync and sweep results by type using dedicated handlers instead of relying on generic status handling.

#### Scenario: Results routing selects the correct handler
- **GIVEN** core receives a gRPC results payload tagged as `sync`
- **WHEN** the results pipeline processes the payload
- **THEN** it SHALL dispatch to the sync ingestor
- **AND** sweep payloads SHALL dispatch to the sweep ingestor
