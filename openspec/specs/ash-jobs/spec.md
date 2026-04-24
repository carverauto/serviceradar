# ash-jobs Specification

## Purpose
TBD - created by archiving change integrate-ash-framework. Update Purpose after archive.
## Requirements
### Requirement: AshOban Job Scheduling
The system SHALL use AshOban for declarative job scheduling tied to Ash resource actions.

#### Scenario: Scheduled action execution
- **GIVEN** a resource action configured with AshOban trigger
- **WHEN** the schedule interval elapses
- **THEN** the action SHALL be enqueued as an Oban job
- **AND** the job SHALL execute with the configured actor and arguments

#### Scenario: Job state tracking
- **WHEN** an AshOban job executes
- **THEN** the system SHALL update the resource state
- **AND** record success or failure in the job history

### Requirement: Distributed Gateway Coordination
The system SHALL coordinate polling jobs across distributed gateway nodes using Horde, and selection SHALL be tenant-scoped.

#### Scenario: Gateway discovery
- **GIVEN** multiple gateway nodes in the ERTS cluster for tenant "acme"
- **WHEN** a polling job needs execution for tenant "acme"
- **THEN** the system SHALL query Horde.Registry for available gateways in tenant "acme"
- **AND** select a gateway matching the required partition

#### Scenario: Gateway failover
- **GIVEN** a polling job assigned to gateway node P1 for tenant "acme"
- **WHEN** gateway P1 becomes unavailable mid-execution
- **THEN** Horde SHALL detect the failure
- **AND** the job SHALL be reassigned to another available gateway for tenant "acme"

### Requirement: Edge Domain Job Routing
The system SHALL route jobs to edge-deployed gateways based on endpoint domain.

#### Scenario: Edge gateway selection
- **GIVEN** a job targeting endpoint domain "site-a"
- **WHEN** the job is dispatched
- **THEN** the system SHALL find gateways registered for domain "site-a"
- **AND** dispatch the task via ERTS distribution

#### Scenario: Partition-aware routing
- **GIVEN** overlapping IP spaces in partitions P1 and P2
- **WHEN** a job targets a device in partition P1
- **THEN** only gateways registered for partition P1 SHALL be candidates
- **AND** the job SHALL NOT be routed to partition P2 gateways

### Requirement: Job Migration from Custom Scheduler
The system SHALL migrate existing custom Oban jobs to AshOban triggers.

#### Scenario: Trace summaries job migration
- **GIVEN** the existing refresh_trace_summaries job
- **WHEN** migrated to AshOban
- **THEN** the job SHALL be defined as an action trigger
- **AND** existing scheduling behavior SHALL be preserved

### Requirement: State Machine Transitions via Jobs
The system SHALL support timed state transitions using AshOban triggers.

#### Scenario: Alert escalation timeout
- **GIVEN** an alert in "pending" state for more than 30 minutes
- **WHEN** the escalation job executes
- **THEN** the alert SHALL transition to "escalated" state
- **AND** a notification SHALL be sent

#### Scenario: Package expiration
- **GIVEN** an edge package past its expiration time
- **WHEN** the expire_packages job executes
- **THEN** the package state SHALL transition to "expired"
- **AND** the download token SHALL be invalidated

### Requirement: Daily cloud-provider CIDR refresh job
The system SHALL run a daily AshOban job that fetches the configured cloud-provider CIDR dataset (including the rezmoss source), validates and normalizes entries, and promotes a new active snapshot for ingestion enrichment.

#### Scenario: Daily refresh succeeds
- **GIVEN** the external dataset source is reachable and valid
- **WHEN** the daily refresh job runs
- **THEN** a new normalized provider CIDR snapshot is stored
- **AND** that snapshot becomes the active version used by flow ingestion enrichment

#### Scenario: Refresh failure preserves last-known-good snapshot
- **GIVEN** the external dataset source is unavailable or invalid
- **WHEN** the refresh job runs
- **THEN** the active provider CIDR snapshot remains unchanged
- **AND** the job records failure telemetry/logging without breaking ingestion

### Requirement: Weekly IEEE OUI refresh job
The system SHALL run a weekly AshOban job that fetches IEEE `oui.txt`, parses and normalizes OUI prefixes, and promotes a new active OUI snapshot used for MAC vendor enrichment.

#### Scenario: Weekly OUI refresh succeeds
- **GIVEN** the IEEE OUI source is reachable and parseable
- **WHEN** the weekly OUI refresh job runs
- **THEN** a new normalized OUI snapshot is stored in CNPG
- **AND** that snapshot becomes the active version used by ingestion enrichment

#### Scenario: OUI refresh failure preserves last-known-good snapshot
- **GIVEN** the IEEE OUI source is unavailable or malformed
- **WHEN** the weekly OUI refresh job runs
- **THEN** the active OUI snapshot remains unchanged
- **AND** the job records failure telemetry/logging without breaking ingestion

