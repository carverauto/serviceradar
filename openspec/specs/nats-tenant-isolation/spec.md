# nats-tenant-isolation Specification

## Purpose
TBD - created by archiving change add-nats-tenant-isolation. Update Purpose after archive.
## Requirements
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

- **GIVEN** tenant "acme-corp" publishes to "acme-corp.logs.syslog.processed"
- **AND** tenant "xyz-inc" subscribes to "xyz-inc.logs.syslog.processed"
- **WHEN** the message is published
- **THEN** tenant "xyz-inc" SHALL NOT receive tenant "acme-corp" messages

### Requirement: NATS Account Isolation

Enterprise tenants with collector deployments SHALL receive dedicated NATS accounts for message isolation.

Each tenant account SHALL:
- Have unique credentials (NKey or JWT)
- Be limited to publishing/subscribing to their prefixed subjects
- Support leaf node connections from customer networks
- Reject signed imports, exports, subject mappings, or user permission overrides that escape the tenant or approved platform scope
- Use finite JetStream resource limits instead of unlimited default quotas

#### Scenario: Cross-tenant authority widening is rejected
- **GIVEN** a caller requests a signed account JWT or user credential override for tenant `acme-corp`
- **WHEN** the request includes publish, subscribe, import, export, or mapping subjects outside `acme-corp` or approved platform subjects
- **THEN** the signing request SHALL be rejected
- **AND** no JWT with widened cross-tenant authority is returned

#### Scenario: New account receives bounded JetStream quotas
- **GIVEN** the platform signs a new tenant account without explicit JetStream quota overrides
- **WHEN** the account JWT is created
- **THEN** the JetStream limits in the account claims SHALL be finite
- **AND** the account SHALL NOT receive unlimited memory, disk, stream, or consumer quotas by default

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

### Requirement: Per-tenant zen consumers

Zen consumers SHALL authenticate with tenant NATS accounts and process tenant
streams directly without cross-account stream mirroring.

#### Scenario: Tenant zen consumes directly

- **GIVEN** tenant "acme-corp" has a zen consumer with tenant credentials
- **WHEN** a log is published to "acme-corp.logs.syslog"
- **THEN** the tenant zen consumer SHALL process the message
- **AND** write processed output back to the tenant account

#### Scenario: Tenant zen HA

- **GIVEN** tenant "acme-corp" has multiple zen consumer instances
- **WHEN** one instance becomes unavailable
- **THEN** remaining instances SHALL continue processing tenant messages
- **AND** no cross-tenant consumers are used as fallbacks

### Requirement: Per-tenant db-event-writer ingestion

The db-event-writer SHALL run per tenant using tenant credentials and write
processed events/logs directly into the tenant schema in CNPG.

#### Scenario: Tenant writer inserts into tenant schema

- **GIVEN** tenant "acme-corp" has a db-event-writer with tenant creds
- **WHEN** a processed log is published to the tenant account
- **THEN** the db-event-writer SHALL write to the tenant schema tables

### Requirement: Rule distribution via KV with tenant isolation

Log promotion rules SHALL be stored in the tenant schema and pushed to the
tenant account KV bucket so zen can hot-reload rules via KV watches.

#### Scenario: Rule update propagates to KV

- **GIVEN** a tenant admin updates a promotion rule in the UI
- **WHEN** the change is saved in CNPG
- **THEN** the system SHALL write the updated rule to the tenant KV bucket
- **AND** zen SHALL receive the KV watch update for that tenant

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

