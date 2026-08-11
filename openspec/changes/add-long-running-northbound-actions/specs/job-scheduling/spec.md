## ADDED Requirements

### Requirement: Deferred Northbound Poll Scheduling

ServiceRadar SHALL schedule deferred northbound action polls through database-backed jobs with uniqueness per invocation target.

#### Scenario: Deferred action schedules poll
- **GIVEN** an action target returns a deferred result with `next_poll_at`
- **WHEN** the result is persisted
- **THEN** ServiceRadar SHALL enqueue exactly one poll job for that target and due time

#### Scenario: Deferred action waits for webhook
- **GIVEN** an action target returns a deferred result with `poll_mode: webhook`
- **WHEN** the result is persisted
- **THEN** ServiceRadar SHALL keep the target in a non-terminal state
- **AND** ServiceRadar SHALL NOT enqueue a poll job for that target

#### Scenario: Poll worker survives restart
- **GIVEN** a deferred action target exists with a due poll time
- **WHEN** the web-ng/core worker process restarts before polling
- **THEN** the poll SHALL still execute from persisted state
- **AND** duplicate poll workers SHALL NOT run for the same target concurrently

### Requirement: Deferred Action Expiration

ServiceRadar SHALL fail deferred action targets that exceed their configured maximum duration or poll deadline.

#### Scenario: Vendor task never completes
- **GIVEN** a deferred action target has exceeded its deadline
- **WHEN** the poll scheduler evaluates it
- **THEN** the target SHALL be marked failed or expired with a clear error message
- **AND** Action History SHALL show the terminal failure state
