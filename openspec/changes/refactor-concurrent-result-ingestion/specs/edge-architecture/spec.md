## ADDED Requirements

### Requirement: Core result routing runs no database work in a singleton callback
Core SHALL classify and admit statuses and results in the `StatusHandler` and `ResultsRouter` coordinator processes without executing Repo, Ash, or other database work inside any of their `handle_call`, `handle_cast`, or `handle_info` callbacks. Ingestion, service-state upserts, workload identity snapshot persistence, add-on status ingestion, and endpoint inventory decoding SHALL run in supervised tasks owned by bounded queues or admission lanes.

#### Scenario: A slow ingest does not delay an unrelated acknowledgement
- **GIVEN** a sweep result whose ingestion is held open in the database
- **WHEN** an endpoint inventory result or a capability-retained plugin result for another agent reaches core
- **THEN** that result SHALL be admitted and acknowledged after its own commit
- **AND** its acknowledgement SHALL NOT wait for the held sweep ingestion

#### Scenario: Singleton callbacks issue no queries
- **GIVEN** core is ingesting every supported result class
- **WHEN** the Repo query telemetry is attributed to the issuing process
- **THEN** no query SHALL be issued by the `StatusHandler` or `ResultsRouter` process

### Requirement: Result classes are ingested by bounded per-class queues
Core SHALL ingest each asynchronous result class (sweep, mapper interfaces, mapper topology, bumblebee, and non-retained plugin results) through its own supervised queue that bounds pending plus in-flight items and bytes in total and per ordering key, runs at most one job per ordering key at a time, interleaves keys fairly, and runs jobs concurrently across keys up to a configured worker count with a per-job timeout. A class's ordering key SHALL preserve the arrival order of results whose order matters (sweep results per agent and sweep group; mapper, bumblebee, and plugin results per agent). Admission beyond a bound SHALL reject the newest item with an explicit, counted reason.

#### Scenario: Results for one key apply in arrival order
- **GIVEN** two sweep results for the same agent and sweep group arrive in order
- **WHEN** the sweep queue ingests them
- **THEN** the second SHALL start only after the first has finished

#### Scenario: Different keys ingest concurrently
- **GIVEN** sweep results for two different agents are pending and the sweep queue has a free worker for each
- **WHEN** the queue dispatches work
- **THEN** both results SHALL be ingested concurrently

#### Scenario: A full class queue rejects visibly
- **GIVEN** a class queue is at its item or byte bound
- **WHEN** another result of that class is admitted
- **THEN** the queue SHALL reject it with a bound-specific reason
- **AND** it SHALL count the rejection in its telemetry
- **AND** other classes' queues SHALL be unaffected

#### Scenario: Snapshot reports coalesce per agent
- **GIVEN** a workload identity snapshot or add-on status report for an agent is pending and not yet started
- **WHEN** a newer report for the same agent arrives
- **THEN** the newer report SHALL replace the pending one instead of queueing behind it

### Requirement: Capability-retained plugin results are admitted by the retained-plugin lane by default
Core SHALL route every `plugin-result` status that carries the `plugin-result-retained:v1` delivery capability through the retained-plugin admission lane unless the `retained_plugin_admission_enabled` compatibility flag is explicitly set to false. With the flag set to false, core SHALL use the previous synchronous path. The agent-facing retained-delivery contract SHALL be unchanged: a result the lane cannot admit or commit SHALL be negatively acknowledged with `received: false` and the agent keeps its exact pending set.

#### Scenario: Default configuration uses the lane
- **GIVEN** a deployment that does not set `retained_plugin_admission_enabled`
- **WHEN** a capability-retained plugin result reaches core
- **THEN** it SHALL be admitted by the retained-plugin lane
- **AND** it SHALL NOT be ingested inside the `StatusHandler` or `ResultsRouter` process

#### Scenario: A full lane negatively acknowledges at once
- **GIVEN** the retained-plugin lane is at its admitted-item limit
- **WHEN** another capability-retained plugin result reaches core
- **THEN** core SHALL reply with the lane's admission error without waiting for queued work
- **AND** the gateway SHALL return `received: false` to the agent

#### Scenario: Kill switch restores the previous path
- **GIVEN** `retained_plugin_admission_enabled` is set to false
- **WHEN** a capability-retained plugin result reaches core
- **THEN** core SHALL ingest it through the previous synchronous path

### Requirement: Service-state batching cannot multiply its flush timer
Core SHALL coalesce service-state upserts for asynchronous results into batches flushed after a configured interval or item count, SHALL perform each flush outside the router process, SHALL arm the flush timer only while items are pending, and SHALL ignore any flush tick that does not match the currently armed timer.

#### Scenario: A tick that fired before its cancel is ignored
- **GIVEN** the item-count threshold forces a flush and re-arms the timer while the previous tick is already queued
- **WHEN** the stale tick is processed
- **THEN** it SHALL NOT start another timer
- **AND** exactly one flush timer SHALL remain armed

#### Scenario: An idle router does not wake
- **GIVEN** no service-state updates are pending
- **WHEN** the flush interval elapses
- **THEN** no flush timer SHALL be armed

### Requirement: Result ingestion backlog is observable
Every result ingestion queue SHALL report pending and in-flight item counts and bytes, admission wait, execution duration, completion result, rejection reason, timeout, and task exit, tagged by result class with bounded cardinality, using the same export path as the admission-lane telemetry.

#### Scenario: Gauges return to zero after work drains
- **GIVEN** results of a class were admitted, executed, rejected, or timed out
- **WHEN** the class queue drains
- **THEN** its pending and in-flight count and byte gauges SHALL report zero
