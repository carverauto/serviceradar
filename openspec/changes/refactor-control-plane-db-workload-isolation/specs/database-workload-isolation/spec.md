## ADDED Requirements

### Requirement: Control-plane critical workflows retain reserved database capacity
The system SHALL reserve database capacity for control-plane critical workflows so that background jobs, maintenance loops, enrichment refreshes, and reconciliation work cannot starve operator-facing or agent-facing persistence paths.

#### Scenario: Bulk MTR result persistence under background load
- **GIVEN** background maintenance, enrichment, and reconciliation jobs are actively using their assigned database budget
- **WHEN** an agent reports completion for a bulk MTR command
- **THEN** the control plane persists the command result and per-target updates without remaining stuck in `ACKNOWLEDGED`
- **AND** the background workload does not consume the reserved capacity needed for that write path

#### Scenario: Agent heartbeat and status updates remain available during maintenance churn
- **GIVEN** recurring schedulers and background jobs are executing
- **WHEN** connected agents push heartbeats and status updates
- **THEN** those updates are persisted within the control-plane latency budget
- **AND** the system does not report the core as unavailable solely because background work saturated its own budget

### Requirement: Background workload concurrency is governed by explicit database budgets
The system SHALL size background job execution, scheduler fan-out, and queue concurrency against explicit database budgets rather than configuring them independently from the available pool capacity.

#### Scenario: Queue configuration cannot exceed supported background budget
- **GIVEN** a deployment profile defines the background database budget for job execution
- **WHEN** Oban queues and scheduler-owned workers are configured
- **THEN** the effective concurrency is bounded by that background budget
- **AND** the system does not permit effective background execution widths that predictably cause checkout or queue collapse

#### Scenario: Larger deployments scale by explicit budget changes
- **GIVEN** an operator increases deployment size for a larger fleet
- **WHEN** they tune the system for additional throughput
- **THEN** they adjust explicit workload budgets and queue limits
- **AND** the system does not rely on one shared default budget for all workload classes
