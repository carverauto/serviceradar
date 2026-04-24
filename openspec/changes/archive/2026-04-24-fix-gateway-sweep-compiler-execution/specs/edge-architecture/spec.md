## MODIFIED Requirements

### Requirement: Edge Network Isolation

Edge components (agents, checkers) deployed in customer networks SHALL NOT join the ERTS Erlang cluster. Communication between edge and platform SHALL use gRPC with mTLS only.

The agent-gateway SHALL NOT have database access. All database-dependent operations (config compilation, device queries, agent records) SHALL be executed on core-elx nodes via RPC.

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
- **THEN** it initiates a gRPC connection to the gateway
- **AND** pushes status updates via gRPC
- **AND** no Erlang distribution protocol is used

#### Scenario: Gateway forwards config requests to core
- **WHEN** an agent requests configuration from the gateway
- **THEN** the gateway forwards the request to core-elx via RPC
- **AND** the gateway does NOT attempt to compile configs locally
- **AND** config compilation (including SRQL queries) runs only on core-elx

#### Scenario: Gateway does not start database components
- **WHEN** the agent-gateway application starts
- **THEN** it SHALL NOT start ServiceRadar.Repo
- **AND** it SHALL NOT attempt any database connections
- **AND** all database-dependent operations are forwarded to core via RPC
