## ADDED Requirements

### Requirement: Bulk payload streaming pipeline
The platform SHALL provide a reusable bulk payload streaming pipeline for gRPC-enabled edge services. Agents SHALL stream chunked payloads to gateways, gateways SHALL forward payload chunks without decoding, and core SHALL reassemble and dispatch payloads by type.

#### Scenario: Agent streams a large payload
- **GIVEN** an agent produces a payload that exceeds the max single-message size
- **WHEN** the agent streams the payload using the bulk payload envelope
- **THEN** the payload is split into ordered chunks with metadata
- **AND** each chunk is sent over gRPC to the gateway

#### Scenario: Gateway forwards opaque chunks
- **WHEN** the gateway receives bulk payload chunks from an agent
- **THEN** it forwards the chunks to the core without decoding the payload
- **AND** it enforces configured size limits on each chunk

#### Scenario: Core reassembles and dispatches payloads
- **GIVEN** the core receives all chunks for a payload
- **WHEN** the core reassembles the payload
- **THEN** it validates the content hash
- **AND** dispatches the payload to the handler registered for that payload type

### Requirement: Bulk payload buffering on gateway
Gateways SHALL buffer bulk payload chunks in memory when core processing is unavailable, and SHALL retry forwarding when core connectivity returns.

#### Scenario: Gateway buffers during core outage
- **GIVEN** the gateway cannot reach the core for bulk payload forwarding
- **WHEN** bulk payload chunks arrive from an agent
- **THEN** the gateway buffers the payload in memory
- **AND** retries forwarding when core connectivity is restored
