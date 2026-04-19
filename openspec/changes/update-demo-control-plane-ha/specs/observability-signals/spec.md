## ADDED Requirements
### Requirement: Stateless observability ingress services support replicated deployments
The system SHALL support running stateless observability ingest services with multiple replicas when they only accept network traffic and publish into shared NATS streams without requiring shared node-local durable state.

#### Scenario: Replicated trap and syslog ingestion remain routable
- **GIVEN** `trapd`, `log-collector`, or `log-collector-tcp` are configured with more than one replica
- **WHEN** ingress traffic arrives through their Kubernetes service
- **THEN** any healthy replica MAY accept the traffic
- **AND** the service SHALL continue publishing events into the shared platform NATS streams without requiring a single owning pod

#### Scenario: Replicated flow collectors use pod-local scratch storage
- **GIVEN** `flow-collector` runs with more than one replica in `demo`
- **WHEN** each replica starts
- **THEN** each replica SHALL be able to use pod-local scratch storage instead of a single shared PVC
- **AND** scaling the deployment SHALL NOT require all replicas to mount the same ReadWriteOnce claim

### Requirement: Singleton ingest-adjacent services remain explicit
The system SHALL keep ingest-adjacent services with singleton storage or durable-consumer ownership explicit until a replica-safe ownership contract exists.

#### Scenario: Singleton datasvc, zen, and db-event-writer remain intentional
- **GIVEN** `datasvc`, `zen`, or `db-event-writer` still depend on single-claim storage or a fixed durable consumer identity
- **WHEN** the demo HA topology is updated
- **THEN** those services SHALL remain explicitly singleton
- **AND** their replica count SHALL NOT be increased as part of the stateless ingress scaling step
