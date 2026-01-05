# ash-observability Specification

## Purpose
TBD - created by archiving change integrate-ash-framework. Update Purpose after archive.
## Requirements
### Requirement: OpenTelemetry Integration
The system SHALL integrate OpenTelemetry tracing with Ash actions via open_telemetry_ash.

#### Scenario: Action tracing
- **WHEN** an Ash action is executed
- **THEN** a trace span SHALL be created
- **AND** the span SHALL include action name, resource, and actor

#### Scenario: Policy evaluation tracing
- **WHEN** authorization policies are evaluated
- **THEN** the trace SHALL include policy evaluation time
- **AND** record which policies passed or failed

### Requirement: AshAdmin Development Interface
The system SHALL provide AshAdmin for resource management in development/staging environments.

#### Scenario: Admin dashboard access
- **GIVEN** the application running in dev or staging environment
- **WHEN** an admin navigates to /admin/ash
- **THEN** the AshAdmin interface SHALL be displayed
- **AND** all configured resources SHALL be browsable

#### Scenario: Admin tenant context
- **WHEN** an admin uses AshAdmin to query resources
- **THEN** the admin's tenant context SHALL be respected
- **AND** multi-tenant isolation SHALL be enforced

### Requirement: Metrics Export
The system SHALL export Ash-related metrics for monitoring.

#### Scenario: Action execution metrics
- **WHEN** Ash actions are executed
- **THEN** the following metrics SHALL be exported:
  - Action execution count by resource and action
  - Action execution duration histogram
  - Authorization failure count

#### Scenario: Job scheduling metrics
- **WHEN** AshOban jobs are scheduled and executed
- **THEN** the following metrics SHALL be exported:
  - Job queue depth by queue name
  - Job execution duration histogram
  - Job failure count by worker

### Requirement: Health Checks
The system SHALL expose health check endpoints for Ash-related services.

#### Scenario: Database connectivity check
- **WHEN** /health/ready is requested
- **THEN** the system SHALL verify AshPostgres repo connectivity
- **AND** return 503 if the database is unreachable

#### Scenario: Cluster health check
- **WHEN** /health/cluster is requested
- **THEN** the system SHALL verify ERTS cluster connectivity
- **AND** report the number of connected poller nodes

### Requirement: Horde Cluster Admin Dashboard
The system SHALL provide a LiveView admin dashboard for monitoring and managing the distributed Horde cluster.

#### Scenario: Cluster overview
- **WHEN** an admin navigates to /admin/cluster
- **THEN** the dashboard SHALL display:
  - Number of connected ERTS nodes
  - Node names and status (connected/disconnected)
  - Cluster topology visualization

#### Scenario: Poller registry view
- **WHEN** an admin navigates to /admin/cluster/pollers
- **THEN** the dashboard SHALL display all registered pollers with:
  - Node name and partition
  - Domain and capabilities
  - Status (available/busy/offline)
  - Last heartbeat timestamp
  - Current workload (active jobs)

#### Scenario: Agent registry view
- **WHEN** an admin navigates to /admin/cluster/agents
- **THEN** the dashboard SHALL display all registered agents with:
  - Agent ID and SPIFFE identity
  - Connected poller node
  - Capabilities
  - Connection status and duration

#### Scenario: Process supervisor view
- **WHEN** an admin navigates to /admin/cluster/processes
- **THEN** the dashboard SHALL display Horde.DynamicSupervisor state:
  - Child processes across cluster
  - Process distribution per node
  - Memory usage per process

#### Scenario: Node disconnect alert
- **GIVEN** a poller node is connected to the cluster
- **WHEN** the node disconnects unexpectedly
- **THEN** the dashboard SHALL show a real-time alert
- **AND** the node status SHALL update to "disconnected"
- **AND** an event SHALL be logged

#### Scenario: Manual poller status control
- **GIVEN** an admin viewing a poller in the dashboard
- **WHEN** the admin clicks "Mark Unavailable"
- **THEN** the poller status SHALL change to :unavailable
- **AND** new jobs SHALL NOT be routed to that poller
- **AND** an audit event SHALL be recorded

