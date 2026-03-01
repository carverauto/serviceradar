## ADDED Requirements
### Requirement: Docker Compose agent can reach the gateway
The Docker Compose stack SHALL configure the agent and agent-gateway services so that the agent can resolve and connect to the gateway gRPC endpoint without manual edits.

#### Scenario: Agent enrollment on clean boot
- **GIVEN** a user removes compose volumes and runs `docker compose up -d`
- **WHEN** the agent container starts
- **THEN** the agent connects to the agent-gateway gRPC endpoint using the compose DNS alias
- **AND** the gateway logs show a successful agent enrollment
