## ADDED Requirements

### Requirement: Package-contributed EventWriter processors
The ingestion pipeline SHALL allow approved package-backed plugins, native add-ons, and
sidecars to request output contracts and bounded EventWriter projector definitions
through package metadata. Core EventWriter dispatch SHALL use approved output-contract
bundles, processor contributions, and core platform defaults, not producer-specific
aliases or subject clauses for integrations such as PowerDNS, Falco, Trivy, Bumblebee,
or endpoint inventory. The platform registry SHALL own route profiles, subjects,
traffic classes, partitions, physical streams, cost models, and persistence
destinations.

#### Scenario: Add-on package contributes a processor
- **GIVEN** a native add-on package includes a valid EventWriter processor contribution
- **AND** the package version is approved
- **WHEN** EventWriter builds its routing snapshot
- **THEN** the processor contribution SHALL be included in the active routes
- **AND** records bearing its exact trusted contract id, version, bundle digest, and
  registry epoch SHALL be processed by the declared platform processor engine

#### Scenario: Unapproved contribution is inert
- **GIVEN** a package includes a valid EventWriter processor contribution
- **AND** the package version has not been approved
- **WHEN** EventWriter builds its routing snapshot
- **THEN** the processor contribution SHALL NOT be included in active routes

#### Scenario: Core has no producer-specific alias
- **GIVEN** a PowerDNS package contributes an OCSF DNS Activity processor
- **WHEN** EventWriter processes a record with the approved PowerDNS output-contract
  identity
- **THEN** routing SHALL resolve through the approved processor registry entry
- **AND** core pipeline code SHALL NOT require a `ServiceRadar.EventWriter.Processors.PowerDNS`
  alias or producer-specific batcher clause

### Requirement: Processor contracts are submitted before runtime processing
The system SHALL collect EventWriter processor contracts during package import,
installation, or add-on registration and persist approved contracts in CNPG. Core SHALL
NOT call a running add-on at event-processing time to fetch processor definitions,
mapping logic, catalogs, or executable code.

#### Scenario: Add-on is installed on a remote agent
- **GIVEN** an add-on package is installed or assigned to an agent
- **AND** the package includes a processor contribution contract
- **WHEN** the package is approved or registered
- **THEN** core SHALL validate and persist the effective processor contract
- **AND** EventWriter SHALL use the persisted contract for later matching messages

#### Scenario: Running add-on is unreachable
- **GIVEN** a running add-on is offline or only reachable through agent-gateway command bus
- **WHEN** EventWriter processes an `EdgeRecordV1` carrying that add-on's exact
  approved contract ID, version, bundle digest, and registry epoch
- **THEN** EventWriter SHALL process the message using the persisted contract
- **AND** SHALL NOT attempt to call the add-on to retrieve processor details

### Requirement: Processor contribution registry snapshots
EventWriter SHALL consume a versioned registry snapshot containing approved processor
contributions, exact output-contract identities and immutable bundle digests,
platform-assigned route/subject slots, processor engine ids, approved destination
metadata, cost models, schema/display references, and device-correlation mappings.
Snapshot refresh SHALL be atomic and coordinated with agent/gateway readiness; if a new
snapshot is invalid, EventWriter SHALL keep the previous valid snapshot. Historical
bundles SHALL remain readable through the maximum agent-spool, broker-retention, retry,
DLQ, and redrive horizon.

#### Scenario: Registry refresh succeeds
- **GIVEN** a newly approved package processor contribution has no conflicts
- **WHEN** the registry snapshot refreshes
- **THEN** EventWriter SHALL atomically activate the new snapshot
- **AND** subsequent matching messages SHALL use the new route

#### Scenario: Registry refresh fails validation
- **GIVEN** a newly staged processor contribution conflicts with an existing route
- **WHEN** EventWriter validates a refreshed registry snapshot
- **THEN** the refreshed snapshot SHALL be rejected
- **AND** EventWriter SHALL continue processing with the previous valid snapshot
- **AND** the conflict SHALL be visible to operators

### Requirement: Processor output authority is validated
The system SHALL validate requested output contracts and projector engines against
package ownership and platform policy before activation. Processor contributions SHALL
NOT select or claim subjects, streams, traffic class, partition rules, database
destinations, SQL, DDL, internal health routes, unrelated producer contracts, or
cross-scope authority.

#### Scenario: Package claims reserved routing authority
- **GIVEN** a package processor contribution requests an internal subject, physical
  stream, traffic-class promotion, or database destination
- **WHEN** the package is validated for approval
- **THEN** validation SHALL fail with an output-authority error
- **AND** the contribution SHALL NOT become active

### Requirement: Processor contributions use platform-owned engines
Package processor contributions SHALL select platform-owned processor engines and
bounded declarative mappings. They SHALL NOT upload arbitrary Elixir modules, SQL,
JavaScript, native code, or database DDL for EventWriter execution.

#### Scenario: Package attempts executable processor upload
- **GIVEN** a package includes an EventWriter processor contribution that references
  arbitrary executable code
- **WHEN** the package is validated
- **THEN** validation SHALL reject the contribution
- **AND** EventWriter SHALL NOT execute package-supplied code

### Requirement: Broadway-backed package ingestion
Package-contributed records SHALL be consumed from the finite platform-owned JetStream
route map through shared Broadway-backed EventWriter producers and pipelines so
back-pressure, batching, acknowledgement, retries, and telemetry remain consistent with
core EventWriter ingestion. A new package or contract SHALL NOT create a dedicated
physical stream, consumer, connection, lane, or Broadway producer.

#### Scenario: Package route is activated
- **GIVEN** an approved processor contribution adds a new output-contract dispatch entry
- **WHEN** EventWriter refreshes its registry snapshot
- **THEN** matching trusted records SHALL be dispatched through the shared EventWriter
  Broadway pipeline
- **AND** no separate ad hoc receive loop SHALL be required for that package route

### Requirement: Package-contributed catalog refresh contracts
The system SHALL allow packages to contribute catalog or artifact refresh contracts
through package metadata. Core SHALL persist approved catalog contracts and execute them
with platform-owned fetch, parser, validator, object-store staging, and promotion
engines rather than integration-specific core workers.

#### Scenario: Bumblebee package contributes a catalog contract
- **GIVEN** the Bumblebee add-on package includes a catalog refresh contract
- **WHEN** the package is approved
- **THEN** core SHALL persist the catalog contract as a package-owned contribution
- **AND** a generic catalog refresh worker SHALL refresh and promote snapshots
- **AND** no Bumblebee-specific catalog refresh worker SHALL be required

#### Scenario: Catalog is assigned to an agent
- **GIVEN** a generic catalog refresh contribution has promoted a snapshot
- **WHEN** an assigned agent receives config for the contributing add-on
- **THEN** the config SHALL include an agent-gateway retrievable artifact reference
- **AND** the agent SHALL NOT need direct NATS object-store access
