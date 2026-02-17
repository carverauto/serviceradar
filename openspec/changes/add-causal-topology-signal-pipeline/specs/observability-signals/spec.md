## ADDED Requirements
### Requirement: External Causal Signal Normalization
The system SHALL normalize external SIEM and BMP/BGP routing events into a common causal signal envelope with source provenance and replay-safe identity.

#### Scenario: BMP event normalized for causal evaluation
- **GIVEN** a BMP routing event is received from the external BMP collector path
- **WHEN** the event enters the observability pipeline
- **THEN** the system SHALL normalize it into the causal envelope with signal type, severity, source, and event identity fields
- **AND** the normalized event SHALL be eligible for topology causal overlay evaluation

#### Scenario: SIEM alert normalized with provenance
- **GIVEN** a SIEM alert event is received from an external source
- **WHEN** the event is normalized
- **THEN** the causal envelope SHALL include source provenance, detection timestamp, and normalized severity

### Requirement: BMP Causal Ingestion Path
BMP routing events SHALL enter ServiceRadar through `BMP collector (risotto) -> NATS JetStream -> Elixir Broadway consumer` and SHALL NOT require agent-originated gRPC payloads.

#### Scenario: BMP event consumed through JetStream and Broadway
- **GIVEN** risotto publishes a BMP routing event to JetStream
- **WHEN** the Broadway consumer processes the event
- **THEN** the event SHALL be persisted/forwarded through the causal signal pipeline
- **AND** causal overlay updates SHALL proceed without requiring agent stream delivery

#### Scenario: Agent stream remains scoped to agent-originated payloads
- **GIVEN** an agent gRPC stream is connected
- **WHEN** external BMP events are processed
- **THEN** the system SHALL process BMP events through the JetStream/Broadway path
- **AND** the agent stream contract SHALL remain unchanged for agent-originated data
