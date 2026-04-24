## ADDED Requirements

### Requirement: Bulk MTR Jobs
The system SHALL support submitting a single bulk MTR job that targets at least 2,400 destinations against one connected agent without relying on one independent on-demand `mtr.run` command per destination.

#### Scenario: Operator submits a 2,400-target bulk job
- **WHEN** an operator submits a bulk MTR request with 2,400 valid targets and one connected MTR-capable agent
- **THEN** the system accepts the request as one bulk job
- **AND** the job is associated to the selected agent
- **AND** the control plane persists job-level and target-level state for the submitted targets

### Requirement: Dedicated Bulk Execution Path
The agent SHALL execute bulk MTR jobs through a dedicated queue and worker path that is independent from the interactive ad-hoc `mtr.run` concurrency limit.

#### Scenario: Bulk job does not consume ad-hoc slots
- **WHEN** a bulk MTR job is running on an agent
- **THEN** the agent schedules bulk targets through the bulk executor
- **AND** the existing interactive `mtr.run` safety cap remains available for ad-hoc operator traces

### Requirement: Bounded High-Throughput Bulk Scheduling
The agent SHALL drain accepted bulk MTR targets through bounded worker concurrency, using reusable execution resources where possible so large jobs complete faster than repeating per-target cold-start traces.

#### Scenario: Bulk executor reuses warm resources
- **WHEN** the agent processes a bulk MTR job with many queued targets
- **THEN** the agent uses long-lived worker and probe resources for the job where practical
- **AND** target execution is paced by a configurable bulk concurrency profile
- **AND** the system does not require a fresh control-stream round trip per target before execution begins

### Requirement: Bulk Job Progress And Terminal States
The system SHALL track bulk MTR job lifecycle and per-target lifecycle through explicit queued, running, completed, failed, canceled, and timed-out terminal semantics.

#### Scenario: Bulk job reaches a terminal state
- **WHEN** the final target in a bulk MTR job reaches a terminal state
- **THEN** the control plane marks the job as completed, failed, canceled, or partially completed according to aggregate outcome rules
- **AND** the job no longer appears as active

#### Scenario: Progress is visible while the job is draining
- **WHEN** a bulk MTR job is in progress
- **THEN** the system reports at least queued, running, completed, failed, and total target counts
- **AND** operators can inspect per-target state without waiting for the full job to finish

### Requirement: Bulk Job Fairness And Safety
The system SHALL provide bulk execution controls that bound local resource use and prevent one large bulk MTR job from starving all other diagnostics activity on the same agent.

#### Scenario: Bulk job concurrency is bounded
- **WHEN** the selected agent is executing a bulk MTR job
- **THEN** the bulk executor enforces configured concurrency and pacing limits
- **AND** excess targets remain queued rather than being rejected solely because they exceed immediate worker capacity

### Requirement: Bulk Job Cancellation And Retry
The system SHALL allow operators to cancel bulk MTR jobs and retry failed or incomplete targets without recreating a brand-new job definition by hand.

#### Scenario: Operator cancels a running bulk job
- **WHEN** an operator cancels a running bulk MTR job
- **THEN** queued targets stop starting
- **AND** in-flight targets are driven to a terminal canceled or interrupted outcome according to executor rules
- **AND** the job becomes terminal once all in-flight targets settle

#### Scenario: Operator retries failed targets
- **WHEN** an operator requests retry for failed or timed-out targets from a prior bulk MTR job
- **THEN** the system creates a new execution attempt scoped to the selected subset
- **AND** the original job history remains available for audit and comparison

### Requirement: Recurring Bulk MTR Scheduling
The system SHALL support recurring bulk MTR jobs with default no-overlap behavior so a scheduled full-inventory cycle does not silently start on top of an unfinished prior run.

#### Scenario: Scheduled run would overlap an active prior run
- **WHEN** a recurring bulk MTR schedule reaches its next fire time while the previous run is still active
- **THEN** the system does not start a second overlapping run by default
- **AND** the skipped or deferred execution is surfaced to the operator

### Requirement: First-Run Calibration And Throughput Baseline
The system SHALL measure execution duration and throughput for bulk MTR jobs and use that baseline to recommend safe recurring intervals.

#### Scenario: First completed run establishes interval guidance
- **WHEN** the first bulk MTR run for an agent/profile completes
- **THEN** the system records completion time, effective throughput, and outcome counts
- **AND** the UI presents a recommended minimum recurring interval derived from the measured run characteristics
