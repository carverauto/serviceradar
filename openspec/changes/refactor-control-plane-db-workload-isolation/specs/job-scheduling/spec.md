## MODIFIED Requirements

### Requirement: ServiceRadar provides Oban-backed job scheduling
The system MUST run Oban with CNPG as the persisted job storage backend so background jobs are observable and durable. Oban-backed background execution MUST use an explicit background database budget that is isolated from control-plane critical workflows. Other Elixir nodes MAY join the Oban cluster as peers to share job execution within that background budget.

#### Scenario: Oban tables exist after migration
- **GIVEN** web-ng has applied database migrations
- **WHEN** `\dt oban_jobs` is executed in the CNPG database
- **THEN** the `oban_jobs` table exists.

#### Scenario: Background jobs cannot starve control-plane persistence
- **GIVEN** Oban queues are active and background jobs are executing
- **WHEN** control-plane critical workflows persist command status, heartbeats, or operator-triggered mutations
- **THEN** those workflows continue to make forward progress using reserved database capacity
- **AND** background job execution remains constrained to its assigned budget
