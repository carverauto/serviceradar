# Cluster Coordination Capability

## ADDED Requirements

### Requirement: CoordinatorCandidate participates in leader election

Eligible nodes SHALL run a CoordinatorCandidate GenServer that participates in leader election using Erlang's `:global` registry.

#### Scenario: CoordinatorCandidate starts on eligible node

**Given** the node is configured with `COORDINATOR_ELIGIBLE=true`
**When** the application starts
**Then** the CoordinatorCandidate GenServer SHALL be started
**And** it SHALL attempt to register as the global coordinator

#### Scenario: CoordinatorCandidate skipped on ineligible node

**Given** the node is configured with `COORDINATOR_ELIGIBLE=false`
**When** the application starts
**Then** the CoordinatorCandidate GenServer SHALL NOT be started
**And** no leader election attempts SHALL be made

#### Scenario: CoordinatorCandidate becomes leader when no leader exists

**Given** the CoordinatorCandidate is running
**And** no coordinator is currently registered globally
**When** the candidate attempts `:global.register_name`
**Then** it SHALL successfully register as coordinator
**And** start the CoordinatorSupervisor with coordination processes

#### Scenario: CoordinatorCandidate becomes standby when leader exists

**Given** the CoordinatorCandidate is running
**And** another node is already registered as coordinator
**When** the candidate attempts `:global.register_name`
**Then** registration SHALL fail
**And** the candidate SHALL monitor the current leader
**And** periodically check for leader availability

### Requirement: Coordinator manages coordination processes

The elected coordinator SHALL manage coordination processes including ClusterHealth and PollOrchestrator.

#### Scenario: Coordinator starts coordination processes

**Given** a node has won leader election
**When** it becomes the coordinator
**Then** it SHALL start the CoordinatorSupervisor
**And** the CoordinatorSupervisor SHALL start ClusterHealth
**And** the CoordinatorSupervisor SHALL start PollOrchestrator

#### Scenario: Coordinator stops coordination processes on shutdown

**Given** a node is the current coordinator
**When** the node begins graceful shutdown
**Then** it SHALL stop the CoordinatorSupervisor
**And** release the global coordinator registration
**And** emit a telemetry event for leadership release

### Requirement: Automatic failover when coordinator fails

When the current coordinator becomes unavailable, another eligible node SHALL take over coordination responsibilities.

#### Scenario: Failover on coordinator crash

**Given** Node A is the current coordinator
**And** Node B is a standby candidate
**When** Node A crashes unexpectedly
**Then** Node B SHALL detect the coordinator is unavailable within 10 seconds
**And** Node B SHALL register as the new coordinator
**And** Node B SHALL start coordination processes

#### Scenario: Failover on coordinator restart

**Given** Node A is the current coordinator
**And** Node B is a standby candidate
**When** Node A begins a graceful restart
**Then** Node A SHALL release the coordinator registration
**And** Node B SHALL become the new coordinator within 5 seconds
**And** coordination SHALL continue without interruption

#### Scenario: Original coordinator becomes standby after failover

**Given** Node A was the coordinator and restarted
**And** Node B took over as coordinator during restart
**When** Node A starts again
**Then** Node A SHALL detect Node B is already coordinator
**And** Node A SHALL become a standby candidate
**And** Node B SHALL remain as coordinator

### Requirement: Only one coordinator exists at any time

The system SHALL ensure exactly one coordinator is active across the cluster.

#### Scenario: No split-brain during normal operation

**Given** multiple eligible nodes are running
**When** all nodes attempt to become coordinator
**Then** exactly one node SHALL succeed in registering
**And** all other nodes SHALL fail registration
**And** all other nodes SHALL monitor the successful coordinator

#### Scenario: Split-brain resolution after network partition

**Given** a network partition occurred separating nodes
**And** each partition may have elected a local leader
**When** the partition heals
**Then** `:global` SHALL resolve the conflict
**And** exactly one coordinator SHALL remain
**And** the other coordinator SHALL become standby

### Requirement: Takeover delay prevents rapid leader changes

The system SHALL include a configurable delay before attempting to take over leadership.

#### Scenario: Takeover delay prevents flapping

**Given** the takeover delay is configured to 1000ms
**And** the current coordinator experiences a brief network hiccup
**When** the standby node detects the coordinator unavailable
**Then** it SHALL wait 1000ms before attempting takeover
**And** if the coordinator recovers within 1000ms, no takeover occurs

#### Scenario: Configurable takeover delay

**Given** `COORDINATOR_TAKEOVER_DELAY=2000`
**When** the application starts
**Then** the CoordinatorCandidate SHALL use 2000ms as the takeover delay

### Requirement: Coordinator election emits telemetry events

The coordinator election system SHALL emit telemetry events for observability.

#### Scenario: Telemetry on becoming leader

**Given** a node wins leader election
**Then** it SHALL emit `[:serviceradar, :coordinator, :became_leader]` telemetry
**With** measurements including `time`
**And** metadata including `node`

#### Scenario: Telemetry on losing leadership

**Given** a node is the current coordinator
**When** it loses leadership (shutdown, crash, partition)
**Then** it SHALL emit `[:serviceradar, :coordinator, :lost_leadership]` telemetry
**With** measurements including `time`
**And** metadata including `node` and `reason`

#### Scenario: Telemetry on leader change detection

**Given** a standby node detects the coordinator has changed
**Then** it SHALL emit `[:serviceradar, :coordinator, :leader_changed]` telemetry
**With** metadata including `previous_leader` and `new_leader`

## MODIFIED Requirements

### Requirement: Application supervision tree includes CoordinatorCandidate

The application supervisor SHALL conditionally include the CoordinatorCandidate based on eligibility.

#### Scenario: CoordinatorCandidate added to supervision tree

**Given** the node is eligible to be a coordinator
**When** the Application starts
**Then** `ServiceRadar.Cluster.CoordinatorCandidate` SHALL be in the supervision tree
**And** it SHALL be supervised with restart strategy `:permanent`

#### Scenario: Static cluster_coordinator config removed

**Given** a node previously used `cluster_coordinator: true` config
**When** upgraded to use leader election
**Then** the static `cluster_coordinator` config SHALL be ignored
**And** leader election SHALL determine the coordinator

## REMOVED Requirements

### Requirement: Static cluster coordinator assignment

The static `cluster_coordinator: true/false` configuration SHALL be removed in favor of dynamic leader election.

#### Scenario: Remove cluster_coordinator from config

**Given** the cluster uses leader election
**Then** `cluster_coordinator` config option SHALL NOT be used
**And** any existing `cluster_coordinator` config SHALL be deprecated
