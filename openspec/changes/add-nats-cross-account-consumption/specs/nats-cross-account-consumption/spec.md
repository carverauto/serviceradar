# Capability: NATS Cross-Account Consumption

**Status**: Superseded by per-tenant zen consumers in `add-nats-tenant-isolation`.

## ADDED Requirements

### Requirement: Tenant Stream Exports
Tenant NATS accounts SHALL export tenant-prefixed streams for logs, events, and OTEL data so platform consumers can read them.

#### Scenario: Tenant export exposes logs
- **GIVEN** tenant "acme" has a NATS account
- **WHEN** the tenant account is provisioned
- **THEN** the account SHALL export `acme.logs.>`
- **AND** the export SHALL be available for platform imports

#### Scenario: Tenant export exposes events
- **GIVEN** tenant "acme" has a NATS account
- **WHEN** the tenant account is provisioned
- **THEN** the account SHALL export `acme.events.>`
- **AND** the export SHALL be available for platform imports

### Requirement: Platform Imports for Shared Consumers
The platform NATS account SHALL import tenant exports so shared consumers can subscribe to tenant-prefixed subjects.

#### Scenario: Platform imports tenant logs
- **GIVEN** tenant "acme" exports `acme.logs.>`
- **WHEN** the platform account is updated for tenant "acme"
- **THEN** the platform account SHALL import `acme.logs.>`
- **AND** platform consumers SHALL receive messages published to `acme.logs.syslog`

#### Scenario: Platform imports tenant events
- **GIVEN** tenant "acme" exports `acme.events.>`
- **WHEN** the platform account is updated for tenant "acme"
- **THEN** the platform account SHALL import `acme.events.>`
- **AND** platform consumers SHALL receive messages published to `acme.events.poller.health`

### Requirement: JetStream mirrors for tenant streams
The platform account SHALL create JetStream mirror or source streams for each
tenant export so consumers read from PLATFORM-managed JetStream storage.

#### Scenario: Platform mirror receives tenant logs
- **GIVEN** tenant "acme" exports `acme.logs.>`
- **AND** the platform account creates a mirror stream for the export
- **WHEN** a log is published in the tenant account
- **THEN** the mirrored PLATFORM stream SHALL receive the message

### Requirement: KV rule stream mirroring
Tenant KV rule streams SHALL be mirrored into the platform account so zen can
watch rule updates without per-tenant credentials.

#### Scenario: Rule KV update mirrored
- **GIVEN** tenant "acme" updates a rule in its KV bucket
- **WHEN** the KV stream is mirrored into PLATFORM
- **THEN** zen SHALL receive the rule update via the platform mirror

### Requirement: Tenant Identity from Subject Prefix
Shared consumers SHALL derive tenant identity from the subject prefix when processing imported messages.

#### Scenario: Tenant slug extracted from subject
- **GIVEN** a shared consumer receives message subject `acme.logs.syslog`
- **WHEN** the consumer processes the message
- **THEN** the consumer SHALL extract tenant slug `acme`
- **AND** use that slug for downstream routing
