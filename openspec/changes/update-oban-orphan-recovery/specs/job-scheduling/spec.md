## ADDED Requirements
### Requirement: System-wide Oban orphan recovery
The system MUST recover Oban jobs that remain in `executing` beyond a configured stale threshold across all queues and workers, without requiring each subsystem to register a bespoke reaper.

#### Scenario: Orphaned executing job is recovered
- **GIVEN** an Oban job remains in `executing` after its owning node exits or loses execution state
- **WHEN** the configured stale threshold elapses and orphan recovery runs
- **THEN** the job SHALL be transitioned out of `executing`
- **AND** future scheduled or manual enqueue attempts SHALL NOT remain blocked solely by that stale executing row

#### Scenario: Exhausted orphaned job is discarded
- **GIVEN** an orphaned Oban job has reached its maximum attempts
- **WHEN** system-wide orphan recovery processes the job
- **THEN** the job SHALL be marked `discarded`
- **AND** the discard SHALL be visible through Oban job history or telemetry

#### Scenario: Recovery threshold is configurable
- **GIVEN** an operator sets the stale recovery threshold in deployment configuration
- **WHEN** the Oban coordinator starts
- **THEN** orphan recovery SHALL use the configured threshold

### Requirement: Manual enqueue paths do not report false success on stale conflicts
Manual job enqueue workflows MUST NOT report that a job was queued when Oban only returned a stale `executing` uniqueness conflict that could not be cleared.

#### Scenario: Stale conflict is cleared and enqueue retries
- **GIVEN** a manual enqueue attempt receives an Oban conflict for a stale `executing` job
- **WHEN** the stale conflict can be cleared synchronously
- **THEN** the enqueue workflow SHALL retry once
- **AND** the user-facing result SHALL reflect the retried enqueue result

#### Scenario: Stale conflict cannot be cleared
- **GIVEN** a manual enqueue attempt receives an Oban conflict for a stale `executing` job
- **WHEN** the stale conflict cannot be cleared synchronously
- **THEN** the enqueue workflow SHALL return an explicit error
- **AND** the UI or caller SHALL NOT claim that a new run was queued
