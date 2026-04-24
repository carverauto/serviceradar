## ADDED Requirements

### Requirement: Bulk MTR Submission Workflow
The web UI SHALL provide a bulk MTR submission workflow that lets operators launch a large target set from one selected agent.

#### Scenario: Operator launches a bulk MTR job
- **WHEN** the operator opens MTR diagnostics and submits a large target list with a selected source agent
- **THEN** the UI creates one bulk MTR job
- **AND** the UI shows the new job in the diagnostics view with aggregate counts and lifecycle status

### Requirement: Bulk MTR Job Progress View
The web UI SHALL expose bulk MTR job progress with explicit queued, running, completed, failed, canceled, and total target counts plus per-target drill-down.

#### Scenario: Operator monitors a running bulk job
- **WHEN** a bulk MTR job is draining on an agent
- **THEN** the diagnostics UI updates aggregate counts and job status as target states change
- **AND** the operator can inspect individual target outcomes from the same workflow

### Requirement: Terminal Bulk Jobs Render As Terminal
The web UI SHALL render bulk MTR jobs according to their terminal state and SHALL NOT continue offering active-job controls after the job is terminal.

#### Scenario: Failed job no longer shows active actions
- **WHEN** a bulk MTR job reaches a failed or otherwise terminal outcome
- **THEN** the UI renders the job as terminal
- **AND** active-only actions such as cancel are no longer shown

### Requirement: Recurring Bulk MTR Interval Guidance
The web UI SHALL warn operators when a configured recurring bulk MTR cadence is tighter than measured execution time or recommended minimum interval.

#### Scenario: Operator configures an interval that is too aggressive
- **WHEN** a recurring bulk MTR configuration uses an interval shorter than the measured first-run baseline or recommended minimum
- **THEN** the UI warns that overlap or backlog is likely
- **AND** the UI presents the measured baseline and recommended interval
