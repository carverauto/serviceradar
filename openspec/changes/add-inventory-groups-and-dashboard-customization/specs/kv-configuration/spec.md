# kv-configuration Specification (Delta): Admin sweep job dispatch

## ADDED Requirements

### Requirement: Admin-triggered sweep jobs are dispatched via KV in a poller-scoped namespace
The system SHALL dispatch admin-triggered on-demand sweep requests by writing a job payload into the KV store under a well-known, poller-scoped namespace so pollers can watch and execute the jobs without `web-ng` directly calling agents.

#### Scenario: Web schedules a sweep by writing a KV job entry
- **GIVEN** an authenticated admin schedules an on-demand sweep from poller `p1`
- **WHEN** the dispatch worker runs
- **THEN** it writes a job payload under a key namespace scoped to `p1` (ex: `jobs/sweeps/p1/<run_id>.json`)
- **AND** the payload includes targets/options, a TTL, and an idempotency key.

### Requirement: Pollers watch for sweep jobs and execute them safely
Pollers SHALL watch their sweep job namespace in KV and execute jobs with bounded concurrency, timeouts, and idempotency.

#### Scenario: Poller executes a sweep job at most once
- **GIVEN** a sweep job is present in the poller’s KV namespace
- **WHEN** the poller processes the job and crashes/restarts mid-run
- **THEN** the poller resumes safely without duplicating the sweep execution
- **AND** it marks job completion/failure in a predictable way (DB and/or KV status key).

