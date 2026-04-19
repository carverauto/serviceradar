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

### Requirement: JetStream-backed workers support replicated pull-consumer workers
The system SHALL support running JetStream-backed observability workers with multiple replicas when they share one durable pull consumer and do not depend on shared node-local durable state.

#### Scenario: Replicated durable pull-consumer workers share one work queue
- **GIVEN** `zen` or `db-event-writer` are configured with more than one replica
- **AND** each replica binds to the same durable pull consumer for its JetStream stream
- **WHEN** messages are available on the consumer
- **THEN** the replicas SHALL compete for pull batches from the same durable consumer
- **AND** each message SHALL be processed by only one healthy worker replica at a time

#### Scenario: Worker replicas do not require shared ReadWriteOnce storage
- **GIVEN** `zen` or `db-event-writer` run with more than one replica in `demo`
- **WHEN** each replica starts
- **THEN** each replica SHALL be able to use pod-local scratch storage instead of a single shared PVC
- **AND** scaling the deployment SHALL NOT require all replicas to mount the same ReadWriteOnce claim
