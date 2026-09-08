## ADDED Requirements

### Requirement: Long-running Action History UX

The device and interface Action History UI SHALL make long-running northbound action progress understandable after launch.

#### Scenario: User launches deferred action
- **GIVEN** a user launches a northbound action that returns a deferred result
- **WHEN** the launch succeeds
- **THEN** the page SHALL tell the user that results will appear in Action History
- **AND** Action History SHALL show the invocation target as queued, polling, result-fetching, succeeded, failed, or expired as state changes arrive

#### Scenario: Deferred action has no final result yet
- **GIVEN** a deferred action is still running in an external system
- **WHEN** the user opens Action History
- **THEN** the row SHALL show the external correlation ID or short invocation ID
- **AND** it SHALL NOT render placeholder text such as `nil` or `null` as a result summary
