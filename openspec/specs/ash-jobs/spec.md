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
The system SHALL coordinate polling jobs across distributed gateway nodes using Horde.

#### Scenario: Gateway discovery
- **GIVEN** multiple gateway nodes in the ERTS cluster
- **WHEN** a polling job needs execution
- **THEN** the system SHALL query Horde.Registry for available gateways
- **AND** select a gateway matching the required partition

#### Scenario: Gateway failover
- **GIVEN** a polling job assigned to gateway node P1
- **WHEN** gateway P1 becomes unavailable mid-execution
- **THEN** Horde SHALL detect the failure
- **AND** the job SHALL be reassigned to another available gateway

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

