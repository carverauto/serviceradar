## ADDED Requirements
### Requirement: Kubernetes deployments support clustered NATS for ServiceRadar
The system SHALL support running NATS as a clustered Kubernetes deployment for ServiceRadar instead of a single broker pod.

#### Scenario: Three-node NATS cluster forms in Kubernetes
- **GIVEN** the Helm deployment configures NATS with three replicas
- **WHEN** the pods start
- **THEN** the NATS peers SHALL discover each other and form one cluster
- **AND** ServiceRadar clients SHALL connect through the cluster service endpoint without manual per-pod configuration

### Requirement: JetStream remains available after one NATS pod loss
The system SHALL preserve ServiceRadar messaging availability after the loss of one healthy NATS pod in a clustered deployment.

#### Scenario: Single NATS pod loss does not take the message bus offline
- **GIVEN** a healthy three-node NATS cluster with JetStream enabled
- **WHEN** one NATS pod becomes unavailable
- **THEN** the remaining NATS peers SHALL continue serving client traffic
- **AND** JetStream-backed ServiceRadar workloads SHALL continue operating within the configured quorum guarantees

### Requirement: Clustered NATS uses stable peer identity and durable storage
The system SHALL use a Kubernetes deployment topology for NATS that provides stable peer identity and per-peer durable storage.

#### Scenario: Restarted NATS peer rejoins with its durable state
- **GIVEN** a clustered NATS deployment with durable per-peer storage
- **WHEN** one NATS pod is restarted
- **THEN** the restarted peer SHALL rejoin the cluster using its stable identity
- **AND** its durable state SHALL remain available after the restart
