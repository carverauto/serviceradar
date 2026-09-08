## MODIFIED Requirements
### Requirement: Edge Network Isolation

Edge components (agents, checkers) deployed in customer networks SHALL NOT join the ERTS Erlang cluster. Communication between edge and platform SHALL use gRPC with mTLS only.

#### Scenario: Edge agent cannot execute RPC on core
- **WHEN** an agent is deployed in customer network
- **AND** attempts to call `:rpc.call(core_node, Module, :function, [args])`
- **THEN** the call fails because no ERTS connection exists
- **AND** the agent has no knowledge of core node names

#### Scenario: Edge agent cannot enumerate cluster processes
- **WHEN** an agent is deployed in customer network
- **AND** attempts to query Horde registries
- **THEN** the query fails because agent is not a cluster member
- **AND** the agent cannot discover other tenants' processes

#### Scenario: Edge communicates via gRPC only
- **WHEN** an agent needs to report data to the platform
- **THEN** it initiates a gRPC connection to the gateway endpoint
- **AND** pushes status updates via gRPC
- **AND** no Erlang distribution protocol is used

#### Scenario: Core-ELX camera ingress rejects insecure startup
- **GIVEN** the core-elx camera media ingress service is configured to start
- **AND** the required server certificate, private key, or CA bundle is absent
- **WHEN** the application boots
- **THEN** the camera media ingress service SHALL fail closed instead of starting a plaintext listener

#### Scenario: Core-ELX camera ingress requires client certificates
- **GIVEN** the core-elx camera media ingress service is running
- **WHEN** a caller connects without a valid client certificate from the expected trust chain
- **THEN** the TLS handshake SHALL fail
- **AND** the media ingress gRPC methods SHALL NOT be reachable over plaintext or server-auth-only TLS
