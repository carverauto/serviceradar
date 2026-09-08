## ADDED Requirements
### Requirement: Tenant-Scoped Ingestion Workers
The system SHALL route sync result chunks to a tenant-scoped ingestion worker registered in the ERTS cluster so that ingestion ownership is explicit and redistributable.

#### Scenario: Chunk routed to tenant worker
- **WHEN** a sync results chunk arrives for tenant A
- **THEN** the agent-gateway routes the chunk to tenant A's ingestion worker
- **AND** the worker processes the chunk without blocking other tenants

#### Scenario: Worker redistribution on node failure
- **GIVEN** tenant A's ingestion worker is running on node X
- **WHEN** node X disconnects from the cluster
- **THEN** Horde reassigns the worker to another node
- **AND** subsequent chunks are routed to the new owner

### Requirement: Per-Tenant Backpressure
The system SHALL bound the number of in-flight chunks per tenant and queue or defer excess chunks to protect shared resources.

#### Scenario: Tenant exceeds concurrency limit
- **GIVEN** tenant A has reached the in-flight chunk limit
- **WHEN** another sync chunk arrives for tenant A
- **THEN** the system queues or defers the chunk
- **AND** emits metrics/logs for queue depth and delay

### Requirement: Automatic Worker Lifecycle
The system SHALL start tenant ingestion workers automatically without requiring additional Kubernetes workloads.

#### Scenario: First sync chunk for new tenant
- **WHEN** the first sync results chunk arrives for a newly onboarded tenant
- **THEN** the core cluster starts the tenant worker automatically
- **AND** no manual k8s changes are required

#### Scenario: Horizontal scale adds capacity
- **GIVEN** multiple core-elx pods are running
- **WHEN** a new pod joins the cluster
- **THEN** ingestion workers MAY be redistributed to balance load
- **AND** ingestion continues without service interruption

### Requirement: Broker-Free Large Payload Handling
The system SHALL continue to process large sync results via streaming gRPC chunking and MUST NOT require NATS for sync ingestion.

#### Scenario: Large sync payload delivered via chunks
- **WHEN** a sync results payload exceeds single-message limits
- **THEN** it is delivered as multiple gRPC chunks
- **AND** ingestion proceeds through tenant workers without NATS involvement
