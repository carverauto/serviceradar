## MODIFIED Requirements
### Requirement: Results ingestion uses gRPC/ERTS routing
The system SHALL ingest sync and sweep results through the standard gRPC results pipeline. The agent-gateway SHALL accept results via the existing `PushStatus` and `StreamStatus` methods and SHALL forward results to core without introducing sync-specific routing, handlers, or gateway-only behaviors.

#### Scenario: Sync results ingestion via gRPC stream
- **GIVEN** an agent emits sync results that exceed single-message limits
- **WHEN** the agent streams the results via `StreamStatus`
- **THEN** the agent-gateway forwards the chunked payload to core through the standard results pipeline
- **AND** no sync-specific handler or routing branch is applied in the gateway

#### Scenario: Status and results use standard methods
- **GIVEN** an agent emits regular status updates and smaller results payloads
- **WHEN** the agent calls `PushStatus`
- **THEN** the agent-gateway forwards the payload to core using the normal status/results routing
- **AND** the same routing logic applies regardless of whether the result is `sync` or `sweep`
