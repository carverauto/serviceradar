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
- **GIVEN** a complete replaceable workload identity snapshot or add-on status snapshot for an agent is pending and not yet started
- **WHEN** a newer report for the same agent arrives
- **THEN** the newer complete snapshot SHALL replace the pending one instead of queueing behind it
- **AND** deltas and irreversible lifecycle transitions SHALL NOT be coalesced

### Requirement: Capability-retained plugin results are admitted by the retained-plugin lane by default
Core SHALL route every supported plugin-result status carrying plugin-result-retained:v1 through the retained-plugin admission lane by default, using explicit source/capability classification. With retained_plugin_admission_enabled explicitly false, core SHALL use a bounded commit-confirming compatibility worker without executing database work in either dispatcher. The agent-facing retained-delivery contract SHALL remain unchanged: a result that cannot reach its existing durable terminal outcome SHALL receive not-accepted / received:false and the agent SHALL retain its exact pending payload set. A durably committed handler-domain failure marker SHALL retain its existing terminal acceptance semantics; in-memory admission alone SHALL NOT count as success.

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

#### Scenario: Flag-off compatibility stays bounded
- **GIVEN** retained_plugin_admission_enabled is false
- **WHEN** a capability-retained plugin result reaches core
- **THEN** a bounded compatibility worker SHALL perform the existing ingestion
- **AND** its reply SHALL require the same durable terminal outcome
- **AND** neither dispatcher SHALL run database work
- **AND** unavailable capacity SHALL return not-accepted rather than falling back inline

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

### Requirement: Result ingestion backlog is observable through JetStream
Every result ingestion queue SHALL publish pending/in-flight counts and bytes, admission/execution latency, completions, rejection reasons, timeouts, and worker exits through canonical metric envelopes on JetStream with PubAck and EventWriter persistence in the configured telemetry backend. Local telemetry and Prometheus SHALL be supplementary; no metric producer SHALL write directly to CNPG or StarRocks. Publisher work, outage buffering, and label cardinality SHALL be bounded and independent of ingestion acknowledgements.

#### Scenario: Queue metrics reach the telemetry backend
- **GIVEN** admitted, rejected, completed, or timed-out queue work
- **WHEN** the bounded metric publisher receives JetStream acknowledgement
- **THEN** EventWriter SHALL persist the canonical gauge and delta metric samples
- **AND** metric labels SHALL exclude agent/device/run identities

#### Scenario: Gauges return to zero after drain
- **GIVEN** results were admitted, rejected, completed, or cancelled
- **WHEN** the queue drains and its metric samples are consumed
- **THEN** pending/in-flight item and byte gauges SHALL be zero

#### Scenario: Metrics publishing fails
- **GIVEN** JetStream is unavailable to the metrics publisher
- **WHEN** the bounded buffer reaches capacity
- **THEN** it SHALL account for dropped health samples visibly without recursive publication
- **AND** a healthy ingestion lane SHALL still complete its own acknowledgements

### Requirement: Acknowledged result deadlines preserve the retained contract
Core SHALL hand acknowledged statuses to independent bounded workers with a remaining deadline that fits inside the gateway forwarding budget and the existing 30-second agent PushStatus deadline. Dispatchers SHALL return to their mailbox after bounded admission, and the worker SHALL reply only after the existing durable terminal outcome is confirmed. Failure, rejection, timeout, or lost completion SHALL return not-accepted, preserve replay identity, and leave the exact pending payload with the agent. A later commit after a lost response SHALL be reconciled by idempotent replay, not converted into an invented successful acknowledgement.

#### Scenario: Unrelated slow ingestion does not delay an ack
- **GIVEN** one result class has a deliberately blocked ingestion worker
- **WHEN** an acknowledged status enters a different class with available capacity
- **THEN** it SHALL finish its own durable work and reply within its remaining deadline
- **AND** it SHALL NOT wait for the blocked class or its database writes

#### Scenario: Worker admission is not an ack
- **GIVEN** a retained plugin result has been admitted but its persistence is blocked
- **WHEN** its deadline expires or worker exits
- **THEN** the gateway SHALL return not-accepted / received:false before the agent deadline
- **AND** the agent SHALL retain the exact pending payload for replay

#### Scenario: Invalid budgets are rejected
- **WHEN** queue wait plus worker timeout and cancellation/reply reserve exceed the coordinated core forwarding budget
- **THEN** configuration SHALL fail validation before that route is enabled

### Requirement: Result ingestion ingress and compatibility are bounded
Core SHALL bound payload ingress, pending and in-flight item/byte reservations, and supervised task execution for each result class and acknowledged lane. Limits SHALL count work waiting to enter the worker and SHALL NOT rely only on a queued-item count behind an unbounded mailbox. Capacity exhaustion or unavailable workers SHALL reject explicitly, including compatibility/rollback paths, without fallback database work in singleton callbacks.

#### Scenario: Payload ingress is saturated
- **GIVEN** a class has used its configured ingress or byte credit
- **WHEN** another producer attempts admission
- **THEN** admission SHALL reject before growing an intermediary payload mailbox
- **AND** other result classes with their own capacity SHALL remain admissible

#### Scenario: Cancelled tasks release capacity safely
- **GIVEN** a worker must be cancelled after timeout
- **WHEN** its reservation is released
- **THEN** task termination SHALL already have been observed
- **AND** the credit SHALL be released exactly once

### Requirement: Result ingestion backlog is observable
Every result ingestion queue and admission lane SHALL report pending and in-flight item counts and bytes, admission wait, execution duration, completion result, rejection reason, timeout, and task exit through `:telemetry`, tagged by lane or result class with bounded cardinality and never by agent, using the same export path as the admission-lane telemetry.

#### Scenario: Gauges return to zero after work drains
- **GIVEN** results of a class were admitted, executed, rejected, or timed out
- **WHEN** the class queue drains
- **THEN** its pending and in-flight count and byte gauges SHALL report zero

### Requirement: Ingestion lane metrics are published on JetStream
Core SHALL publish ingestion lane metrics (per lane or class: queue depth and bytes, and for the interval the admitted, rejected by reason, negatively acknowledged, and timed-out counts, plus incomplete sync runs) as one `serviceradar.metric.v1` MetricBatch per publish interval on the `metrics.ingestion_lanes` JetStream subject, persisted by the EventWriter `Metrics` processor to the active telemetry backend. Core MUST NOT write these metrics to the database directly, MUST NOT publish them per ingested message, and a failed publish SHALL be logged without affecting ingestion. The metrics SHALL be queryable through `timeseries_metrics`; no alert or dashboard is required to consume them by this requirement.

#### Scenario: Published lane metrics are persisted by the Metrics processor
- **GIVEN** a lane admitted and rejected results during a publish interval
- **WHEN** the interval's MetricBatch is published and consumed by the EventWriter `Metrics` processor
- **THEN** the lane's depth and interval counts SHALL be persisted as timeseries metrics

#### Scenario: A publish failure does not affect ingestion
- **GIVEN** the JetStream publish of a lane MetricBatch fails
- **WHEN** results continue to arrive
- **THEN** the failure SHALL be logged
- **AND** admission and ingestion SHALL proceed unchanged

#### Scenario: Publishing is per interval
- **GIVEN** many results are admitted within one publish interval
- **WHEN** the interval ends
- **THEN** core SHALL publish one MetricBatch for that interval

### Requirement: Ingestion lane metrics are visible to operators
Ingestion lane metrics SHALL be available on three surfaces: Prometheus metrics in the core-elx scrape with panels in the chart's Grafana ingestion dashboards; a seeded ServiceRadar dashboard charting the persisted lane metrics from `timeseries_metrics`; and an Ingestion card on Settings -> Cluster Status showing current per-lane depth and capacity and recent rejections and negative acknowledgements. The Cluster Status card SHALL read live values from a lane-stats call rather than a database query and SHALL show an unavailable state when lane stats cannot be read.

#### Scenario: Cluster Status shows lane depth
- **GIVEN** the retained-plugin lane holds queued work
- **WHEN** an operator opens Settings -> Cluster Status
- **THEN** the Ingestion card SHALL show that lane's depth against its capacity

#### Scenario: Lane stats unavailable
- **GIVEN** core cannot return lane stats
- **WHEN** an operator opens Settings -> Cluster Status
- **THEN** the Ingestion card SHALL show an unavailable state instead of failing the page
