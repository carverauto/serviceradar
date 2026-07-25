# nats-cross-account-consumption Delta

## MODIFIED Requirements

### Requirement: Tenant Stream Exports

The ServiceRadar runtime SHALL NOT export data streams based on an in-runtime
customer/tenant identity. Each customer installation owns its NATS durability
authority; any future cross-cluster northbound export SHALL use a separately
specified, authenticated, replay-safe integration contract. Authoritative edge
durable-record, recovery, and DLQ subjects SHALL NOT be exported across an
account or cluster boundary by this change.

#### Scenario: Runtime provisioning evaluates a customer-prefixed export

- **WHEN** runtime provisioning receives a request to export a subject using a
  customer/tenant prefix
- **THEN** it SHALL reject the request as outside the installation data-plane
  contract

#### Scenario: Provisioning evaluates an edge record subject

- **WHEN** account configuration is generated for any canonical edge-record,
  recovery, or record-DLQ subject
- **THEN** it SHALL NOT add an export for that subject

### Requirement: Platform Imports for Shared Consumers

The runtime SHALL NOT depend on a shared cross-customer platform account or
imports for persistence consumers. Installation-local consumers SHALL subscribe
directly to their configured authoritative streams. No import, mapping, source,
or cross-account subscription SHALL sit between an authoritative edge record
PubAck and EventWriter.

#### Scenario: Shared platform import is requested

- **WHEN** runtime configuration requests a shared-platform import for an
  installation persistence path
- **THEN** provisioning SHALL reject it
- **AND** the installation SHALL keep its direct consumer authority

#### Scenario: Shared consumer requests a record import

- **WHEN** platform configuration requests an import or subject mapping for a
  canonical edge-record subject
- **THEN** provisioning SHALL reject the configuration
- **AND** the installation-local EventWriter SHALL continue consuming the
  authoritative physical record streams directly

### Requirement: JetStream mirrors for tenant streams

Authoritative installation streams SHALL NOT use a cross-customer JetStream
mirror/source as their persistence or acknowledgement boundary. A separately
specified disaster-recovery replica MAY exist only if its authority, replication
semantics, failover fencing, and RPO are explicit; it SHALL NOT turn mirror
acceptance into the source PubAck.

#### Scenario: Shared customer mirror is requested

- **WHEN** provisioning requests a mirror/source that combines customer
  installations
- **THEN** it SHALL reject the configuration as outside the runtime contract

#### Scenario: Record mirror is requested

- **WHEN** provisioning requests a mirror or source whose filter captures any
  canonical edge-record subject
- **THEN** readiness SHALL fail and no record publisher SHALL be enabled

### Requirement: KV rule stream mirroring

Installation rule KV streams SHALL NOT be mirrored into a shared cross-customer
account. Each runtime SHALL watch its installation-local rule bucket directly;
external control-plane rule delivery requires a separate authenticated command/
configuration contract, not implicit KV mirroring.

#### Scenario: Shared KV mirror is requested

- **WHEN** runtime provisioning requests a cross-customer mirror/source for an
  installation rule bucket
- **THEN** it SHALL reject the configuration
- **AND** the installation-local rule watch SHALL remain authoritative

### Requirement: Tenant Identity from Subject Prefix

Runtime consumers SHALL NOT derive customer/tenant identity or database authority
from a subject prefix. Installation-local record consumers SHALL validate the
authoritative `EdgeRecordV1` and its signed grants and SHALL use `network_scope_id`
only as the site/address-space component of domain identity. They SHALL NOT infer
network scope, agent, traffic class, or authorization context from a subject token.

#### Scenario: Customer-prefixed subject reaches a runtime consumer

- **WHEN** a runtime consumer receives an unexpected customer-prefixed subject
- **THEN** it SHALL reject or quarantine the message according to the migration
  policy
- **AND** SHALL NOT use the prefix to select a database schema or authorization

#### Scenario: Installation-local record is consumed

- **GIVEN** EventWriter receives `telemetry.edge-record.v1.bulk.p07`
- **WHEN** it validates the persisted message
- **THEN** it SHALL derive network scope, authenticated agent, traffic class, and
  authorization from the verified authoritative record and signed grants
- **AND** `network_scope_id` SHALL distinguish sites or overlapping RFC1918
  address spaces without becoming a SaaS customer identity

## ADDED Requirements

### Requirement: Authoritative edge records remain in installation NATS authority

All approved edge durable-record, recovery, and record-DLQ streams SHALL be published and
consumed directly inside the single-customer installation's configured NATS
durability authority. They SHALL use fixed installation-local subjects,
class-separated physical streams and durables, one explicit logical-to-physical
stream map, and installation-level admission. They SHALL NOT require a
per-customer, per-network-scope, per-agent, per-producer-assignment,
per-run/execution, per-output-contract, per-package, or per-logical-partition
account, durable, connection, or process. This change SHALL NOT create a
cross-cluster durable-record aggregation path.

#### Scenario: Many record partitions are active

- **GIVEN** installation-local processing covers many logical partitions,
  network scopes, agents, producer assignments, and runs/executions
- **WHEN** EventWriter replicas scale out
- **THEN** they SHALL share bounded durable, connection, and process pools aligned
  with the class-separated physical stream shards
- **AND** database and stream admission SHALL remain bounded for the whole
  installation

#### Scenario: Gateway publishes through a leaf connection

- **GIVEN** a NATS leaf forwards a result to the configured authoritative
  installation stream
- **WHEN** the gateway publishes the result
- **THEN** only PubAck from that configured authoritative physical stream SHALL
  permit an accepted edge disposition
- **AND** a Core NATS handoff or non-authoritative local/mirrored acceptance SHALL
  NOT acknowledge durability

#### Scenario: Edge-local JetStream is selected as authority

- **WHEN** a deployment explicitly selects an edge-local JetStream durability
  domain
- **THEN** its replication and site-loss RPO SHALL be configured and surfaced
- **AND** no account export, import, mirror, or source SHALL be treated as a
  substitute for authoritative PubAck
