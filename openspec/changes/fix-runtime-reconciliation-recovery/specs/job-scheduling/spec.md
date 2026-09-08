## ADDED Requirements

### Requirement: Stale unique-job conflicts recover atomically
The scheduler SHALL recover a stale executing unique-job conflict through an
atomic, row-locked state transition that respects the database job-state type. It
SHALL retry the requested insert only after the stale row is durably discarded and
SHALL expose a concrete recovery error when that transition fails.

#### Scenario: Stale executing row blocks a recurring job
- **GIVEN** a unique recurring job conflicts with an executing row older than the configured cutoff
- **WHEN** safe insertion evaluates the conflict
- **THEN** the scheduler SHALL lock and recheck the conflicting row
- **AND** it SHALL transition that row to `discarded` using the supported job schema
- **AND** it SHALL retry the original insert exactly once

#### Scenario: Conflict changes before recovery lock
- **GIVEN** a conflicting job no longer matches the stale executing predicate when locked
- **WHEN** recovery rechecks the row
- **THEN** the scheduler SHALL leave the row unchanged
- **AND** it SHALL return an actionable stale-conflict error without retrying the insert
