## ADDED Requirements
### Requirement: Core-elx Control Plane Responsibilities
The core-elx control plane SHALL host the Device Identity and Reconciliation Engine (DIRE), internal event routing, and status/result ingestion for edge workloads. core-elx SHALL communicate with agent-gateway and web-ng over mTLS-secured Erlang distribution (ERTS RPC).

#### Scenario: core-elx routes ingestion updates
- **WHEN** the platform receives status or collection data from an edge agent via agent-gateway
- **THEN** core-elx processes the payload through DIRE and ingestion pipelines
- **AND** publishes internal events for downstream consumers

#### Scenario: core-elx uses ERTS RPC for internal coordination
- **WHEN** core-elx needs to coordinate with web-ng or agent-gateway
- **THEN** it uses ERTS RPC over mTLS
- **AND** no plaintext or unauthenticated internal RPC is permitted

### Requirement: Agent-Gateway Ingest Modes
The agent-gateway SHALL expose gRPC endpoints that support both unary status pushes and streaming/chunked payload ingestion for large payloads (sync, sweeps, sysmon, discovery, and plugin results). The agent-gateway SHALL forward edge payloads into the control plane over mTLS-secured ERTS/RPC/PubSub (not “gateway -> core” gRPC forwarding).

#### Scenario: Unary status push
- **WHEN** an agent sends a small status update
- **THEN** it calls the unary `PushStatus` endpoint
- **AND** the gateway forwards the payload into the control plane

#### Scenario: Streaming payload ingestion
- **WHEN** an agent sends a large payload (e.g., sync or sysmon)
- **THEN** it uses the streaming `StreamStatus` endpoint with chunked messages
- **AND** the gateway reassembles and forwards the payload into the control plane

#### Scenario: Gateway uses ERTS forwarding
- **WHEN** the gateway forwards an edge payload to the control plane
- **THEN** it delivers the payload over ERTS/RPC/PubSub to core-elx ingestion handlers
- **AND** it does not require a separate gRPC hop from gateway to core-elx for ingestion

## MODIFIED Requirements
### Requirement: mTLS Agent Authentication
Edge agents SHALL authenticate using mTLS client certificates. Certificates SHALL encode workload identity and partition scope for isolation. Gateways SHALL validate the client certificate chain against the platform root/intermediate CA and MUST reject connections from unknown issuers.

#### Scenario: Agent presents workload certificate
- **WHEN** a gateway receives a connection from an agent
- **THEN** the mTLS handshake requires a valid client certificate
- **AND** the gateway validates the certificate chain against the platform CA

#### Scenario: Gateway verifies agent scope
- **WHEN** a gateway receives data from an agent
- **THEN** it extracts workload identity and partition scope from the certificate
- **AND** rejects data that does not match the expected scope

#### Scenario: Certificate encodes workload identity
- **WHEN** an agent certificate is issued during onboarding
- **THEN** the certificate CN encodes component identity and partition scope
- **AND** the SPIFFE ID encodes workload identity
- **AND** the certificate is signed by a platform-issued intermediate CA
