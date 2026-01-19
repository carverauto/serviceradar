## ADDED Requirements

### Requirement: Mapper discovery runs inside the agent
The system SHALL run mapper discovery jobs inside `serviceradar-agent` and SHALL NOT deploy a standalone mapper service in default deployments.

#### Scenario: Deployment excludes mapper workload
- **GIVEN** a standard deployment (Helm or Compose)
- **WHEN** workloads are rendered or started
- **THEN** no `serviceradar-mapper` deployment or container is created
- **AND** mapper discovery is executed by the agent runtime

#### Scenario: Agent executes mapper discovery job
- **GIVEN** an agent with mapper config assigned
- **WHEN** the scheduled mapper job interval elapses
- **THEN** the agent executes mapper discovery locally
- **AND** records job status for reporting

### Requirement: Mapper discovery results ingestion via gRPC
Mapper discovery results SHALL be submitted by agents to the gateway via gRPC and forwarded to core ingestion without requiring a standalone mapper service.

#### Scenario: Agent pushes mapper discovery results
- **GIVEN** an agent completes a mapper discovery job
- **WHEN** it calls `PushResults` (or equivalent) with `result_type = mapper_discovery`
- **THEN** the gateway SHALL forward the results to core
- **AND** core SHALL ingest the discovery results into device inventory streams

#### Scenario: Mapper results routing is explicit
- **GIVEN** core receives a mapper discovery results payload
- **WHEN** the results pipeline processes the payload
- **THEN** it SHALL dispatch to the mapper discovery handler
- **AND** results SHALL not be treated as generic status updates
