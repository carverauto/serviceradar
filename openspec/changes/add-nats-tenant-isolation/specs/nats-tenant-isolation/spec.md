# Capability: NATS Tenant Isolation

## ADDED Requirements

### Requirement: Tenant Channel Prefixing

All NATS event subjects SHALL be prefixed with the tenant slug to ensure message isolation between tenants.

The subject format SHALL be: `<tenant-slug>.<original-subject>`

Publishers SHALL extract tenant context from:
- gRPC metadata (for service-to-service calls)
- Configuration (for edge components)
- Certificate CN (for mTLS-authenticated connections)

#### Scenario: Event publishing with tenant prefix

- **GIVEN** a poller publishing health events for tenant "acme-corp"
- **WHEN** the poller publishes to subject "events.poller.health"
- **THEN** the message SHALL be published to "acme-corp.events.poller.health"

#### Scenario: Consumer receives prefixed messages

- **GIVEN** a db-event-writer consumer subscribed to "*.events.poller.health"
- **WHEN** a message is published to "acme-corp.events.poller.health"
- **THEN** the consumer SHALL receive the message
- **AND** the consumer SHALL extract "acme-corp" as the tenant slug from the subject

#### Scenario: Cross-tenant message isolation

- **GIVEN** tenant "acme-corp" publishes to "acme-corp.events.syslog.processed"
- **AND** tenant "xyz-inc" subscribes to "xyz-inc.events.syslog.processed"
- **WHEN** the message is published
- **THEN** tenant "xyz-inc" SHALL NOT receive tenant "acme-corp" messages

### Requirement: NATS Account Isolation

Enterprise tenants with collector deployments SHALL receive dedicated NATS accounts for message isolation.

Each tenant account SHALL:
- Have unique credentials (NKey or JWT)
- Be limited to publishing/subscribing to their prefixed subjects
- Support leaf node connections from customer networks

#### Scenario: Tenant account creation

- **GIVEN** an enterprise tenant "acme-corp" requires collector deployment
- **WHEN** the operator provisions NATS access for the tenant
- **THEN** a NATS account "acme-corp" SHALL be created
- **AND** the account SHALL have publish permissions for "acme-corp.>"
- **AND** the account SHALL have subscribe permissions for "acme-corp.>"

#### Scenario: Account isolation enforcement

- **GIVEN** tenant "acme-corp" has a NATS account
- **WHEN** a client authenticates with "acme-corp" credentials
- **AND** the client attempts to publish to "xyz-inc.events.syslog"
- **THEN** the publish SHALL be rejected with a permissions error

#### Scenario: Leaf node connection

- **GIVEN** a customer deploys a NATS leaf node with "acme-corp" credentials
- **WHEN** a collector publishes to "acme-corp.events.otel.logs"
- **THEN** the message SHALL route through the leaf node to the platform cluster
- **AND** the message SHALL be available to platform consumers

### Requirement: JetStream Tenant Streams

JetStream streams SHALL support tenant-prefixed subjects for message persistence and replay.

#### Scenario: Stream subject configuration

- **GIVEN** the "events" stream is configured with subjects "*.events.>"
- **WHEN** a message is published to "acme-corp.events.poller.health"
- **THEN** the message SHALL be persisted to the "events" stream
- **AND** the message SHALL be available for replay

#### Scenario: Consumer subject filtering

- **GIVEN** a durable consumer with filter "acme-corp.events.>"
- **WHEN** messages are published for multiple tenants
- **THEN** the consumer SHALL only receive messages for "acme-corp"

### Requirement: Backward Compatibility

During migration, the system SHALL support both prefixed and non-prefixed subjects.

#### Scenario: Legacy message handling

- **GIVEN** the feature flag "NATS_TENANT_PREFIX_ENABLED" is false
- **WHEN** a publisher sends an event
- **THEN** the message SHALL be published without tenant prefix
- **AND** consumers SHALL process the message normally

#### Scenario: Mixed mode operation

- **GIVEN** the feature flag "NATS_TENANT_PREFIX_ENABLED" is true
- **AND** consumers are configured for "*.events.>" patterns
- **WHEN** both prefixed and non-prefixed messages exist
- **THEN** consumers SHALL handle both message formats
- **AND** non-prefixed messages SHALL be associated with "default" tenant
