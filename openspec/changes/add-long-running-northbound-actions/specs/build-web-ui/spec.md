## ADDED Requirements

### Requirement: Long-running Task History UX

The device and interface Task History UI SHALL make long-running northbound action progress understandable after launch.

#### Scenario: User launches deferred task
- **GIVEN** a user launches a northbound action that returns a deferred result
- **WHEN** the launch succeeds
- **THEN** the page SHALL tell the user that results will appear in Task History
- **AND** Task History SHALL show the invocation target as queued, polling, result-fetching, succeeded, failed, or expired as state changes arrive

#### Scenario: Deferred task has no final result yet
- **GIVEN** a deferred task is still running in an external system
- **WHEN** the user opens Task History
- **THEN** the row SHALL show the external correlation ID or short invocation ID
- **AND** it SHALL NOT render placeholder text such as `nil` or `null` as a result summary
