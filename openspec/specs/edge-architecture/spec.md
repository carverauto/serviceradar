# edge-architecture Specification

## Purpose
TBD - created by archiving change remove-elixir-edge-agent. Update Purpose after archive.
## Requirements
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
- **THEN** it waits for gateway to initiate gRPC connection
- **AND** responds to gRPC requests with collected data
- **AND** no Erlang distribution protocol is used

### Requirement: Gateway-Initiated Communication

Gateways deployed in the platform Kubernetes cluster SHALL initiate all connections to edge agents. Edge agents SHALL NOT initiate connections to platform services.

#### Scenario: Gateway polls agent on schedule
- **WHEN** a gateway is assigned an agent
- **THEN** the gateway initiates gRPC connection to agent endpoint
- **AND** requests current monitoring data
- **AND** agent responds with collected metrics

#### Scenario: Agent registration via platform API
- **WHEN** an edge agent starts up
- **THEN** the agent's connection details are configured via onboarding
- **AND** the platform knows agent endpoint from onboarding registration
- **AND** assigned gateway queries platform for agent list

#### Scenario: Agent unreachable handling
- **WHEN** a gateway cannot reach an agent via gRPC
- **THEN** the gateway retries with exponential backoff
- **AND** marks agent as unreachable after timeout
- **AND** alerts are generated for unreachable agents

### Requirement: Internal ERTS Cluster

Platform services (core, gateways, web-ng) running in Kubernetes SHALL form an ERTS Erlang cluster for distributed coordination. This cluster SHALL NOT include edge components.

#### Scenario: Horde registry for gateways
- **WHEN** gateways need to coordinate work distribution
- **THEN** they use Horde distributed registry
- **AND** only platform nodes participate in Horde

#### Scenario: Oban job scheduling across nodes
- **WHEN** scheduled jobs need to run
- **THEN** Oban coordinates via ERTS cluster
- **AND** jobs run on available platform nodes

#### Scenario: Phoenix PubSub for real-time updates
- **WHEN** real-time updates need to broadcast
- **THEN** Phoenix PubSub uses ERTS cluster
- **AND** web-ng receives updates from core/gateways

### Requirement: mTLS Agent Authentication

Edge agents SHALL authenticate using mTLS client certificates. Certificates SHALL encode tenant identity for multi-tenant isolation.

#### Scenario: Agent presents tenant certificate
- **WHEN** a gateway connects to an agent
- **THEN** mTLS handshake requires client certificate from gateway
- **AND** agent verifies gateway certificate is from platform CA

#### Scenario: Gateway verifies agent tenant
- **WHEN** a gateway receives data from an agent
- **THEN** the gateway extracts tenant ID from agent certificate
- **AND** verifies agent belongs to expected tenant
- **AND** rejects cross-tenant data

#### Scenario: Certificate encodes tenant identity
- **WHEN** an agent certificate is issued during onboarding
- **THEN** the certificate CN contains tenant slug
- **AND** SPIFFE ID encodes tenant workload identity
- **AND** certificate is signed by tenant-specific intermediate CA

