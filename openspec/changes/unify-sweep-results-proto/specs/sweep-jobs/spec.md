# sweep-jobs Delta

## ADDED Requirements

### Requirement: Large sweeps use deterministic execution shards
The sweep scheduler SHALL split large target sets into deterministic execution
shards sized from agent capacity, result-stream partitioning, configured
duration, and failure blast radius. Each shard assignment attempt SHALL own its
batch sequence and append-only lifecycle. The immutable plan SHALL contain
ranges/checks rather than future attempts; no execution SHALL require broker
arrival ordering. An execution MAY be long-lived, but every result microbatch
SHALL be independently bounded by bytes, records, and time and SHALL be
independently spooled and acknowledged. Plan headers and arbitrary target lists
SHALL use bounded immutable content-addressed range pages; no database value,
compiled config, or assignment command SHALL contain every target of an
unbounded execution.

#### Scenario: Million-target job is compiled
- **WHEN** a sweep job resolves to one million targets
- **THEN** the compiler SHALL assign deterministic bounded shards across
  eligible agents
- **AND** record the expected shards and target counts for later reconciliation
- **AND** represent compact CIDRs/ranges directly or arbitrary targets as
  bounded immutable range pages under one plan digest
- **AND** SHALL NOT assign one whole-run delivery payload to a single core route
- **AND** every assignment SHALL bind authoritative `network_scope_id`/site,
  agent, execution, and immutable scheduler-signed traffic class

#### Scenario: Shard is retried
- **WHEN** an interrupted shard is reassigned or resumed
- **THEN** the scheduler SHALL issue a monotonically increasing assignment epoch
  and fence the prior owner before the replacement owns its target range
- **AND** stable execution/shard/target identity and revision keys SHALL make
  overlapping delivery idempotent
- **AND** completion SHALL distinguish missing target ranges from successful
  unique observations

#### Scenario: Stale owner publishes after reassignment
- **GIVEN** an older assignment emits a late batch or terminal event
- **WHEN** a newer fenced epoch owns that shard range
- **THEN** the late event MAY remain auditable if it was already durable
- **AND** it SHALL NOT change reconciled counts, current state, or terminal
  execution status

#### Scenario: Agent disappears before terminal evidence
- **GIVEN** an assignment lease expires without durable agent terminal evidence
- **WHEN** the scheduler fences the attempt and REASSIGNS ITS COVERAGE
- **THEN** the scheduler SHALL atomically append an authoritative
  lost/expired/superseded terminal state for the old attempt
- **AND** the replacement SHALL receive a new epoch without mutating the
  immutable plan
- **AND** the replacement SHALL cover the WHOLE range window the old attempt held,
  never a partial remainder: an assignment's MTR expectation is ONE CONTIGUOUS
  plan-global ordinal window and its completion proof requires exactly
  `{1..ordinal_count}`, so a sparse remainder is NOT REPRESENTABLE in v1

### Requirement: Scan admission accounts for downstream backlog
The scheduler SHALL consider agent spool pressure, gateway capacity, JetStream
lag/retention risk, consumer drain rate, and database capacity before admitting
or overlapping large jobs. This is a single-customer installation with no
tenant/account/cell fairness axis. The scheduler SHALL apply bounded admission
by network scope/site, agent, execution, and scheduler-selected `bulk` or
`interactive` traffic class. Bulk and interactive results SHALL use mandatory
disjoint physical streams and durable consumers.

#### Scenario: Prior sweep backlog threatens retention
- **GIVEN** a network scope's prior result backlog cannot drain within its
  class-specific configured safety window
- **WHEN** another lower-priority sweep becomes due
- **THEN** the scheduler SHALL defer or reduce the new sweep
- **AND** surface the capacity reason rather than silently dropping results

#### Scenario: Interactive job shares capacity with a bulk job
- **GIVEN** a bulk execution is continuously streaming results
- **WHEN** a permitted interactive scan is submitted
- **THEN** the scheduler SHALL assign the interactive class and provide bounded
  progress through its independently budgeted stream and durable consumer
- **AND** unsigned caller priority SHALL NOT select or change traffic class
- **AND** the interactive job SHALL NOT bypass network-scope/agent admission or
  starve the existing bulk job
- **AND** each eligible agent SHALL retain an unborrowable interactive execution
  floor for probe workers, sockets/file descriptors, ICMP tokens, DNS
  concurrency, CPU, spool bytes, and sender credits before the job is admitted

### Requirement: MTR collection has an explicit capacity budget
Every MTR-enabled job SHALL have per-site and global limits for targets, traces,
probes per second, concurrent traces, expected duration, interval overlap,
result bytes, and retained storage. Deep fleet-wide MTR SHALL require an
operator-approved, benchmark-backed capacity override.

#### Scenario: MTR run would overlap its next interval
- **WHEN** the compiler estimates that configured targets, hops, probes, and
  agent capacity cannot complete before the next interval
- **THEN** it SHALL reject, shard, sample, or require an explicit override
- **AND** display the limiting probe/time/result-storage estimate

#### Scenario: Large fleet uses adaptive trace selection
- **GIVEN** reachability is scheduled for a very large target set
- **WHEN** no fleet-wide deep-trace override exists
- **THEN** MTR SHALL use configured baseline rotation, critical targets, anomaly
  triggers, or incident fan-out
- **AND** SHALL NOT implicitly trace every reachable target at every sweep

#### Scenario: Completed traces are emitted during a long-lived execution
- **GIVEN** an MTR-enabled execution remains active while multiple traces are in
  flight
- **WHEN** any individual trace completes
- **THEN** the source SHALL stream it into a bounded trace microbatch and durable
  spool without waiting for the run or interval to end
- **AND** SHALL NOT accumulate a run-wide or interval-wide trace slice

## MODIFIED Requirements

### Requirement: Sweep Job Compiled Config Output
The system SHALL compile sweep jobs only for agents and gateways satisfying the
configured minimum `edge-records:v1`, retained spool-reader, and output-contract
registry versions; no legacy JSON sender or unpatched-agent compatibility bridge
SHALL be provided. During migration, a cohort barrier SHALL stop new old-path
executions before enabling v1 assignments. Rollback SHALL disable new work while
compatible v1 backlog drains and SHALL NOT select new legacy output. Each v1
assignment SHALL contain a bounded target range, expected target count and
digest, execution and shard IDs, monotonically increasing assignment epoch,
config generation, expiry, versioned availability policy, exact `(mode,
protocol, port)` check set, result format, and a scheduler-signed capability
bound to authoritative `network_scope_id`/site, agent, execution, range/epoch,
and immutable `bulk` or `interactive` traffic class.

#### Scenario: Cohort is enabled for v1 sweep output
- **GIVEN** the agent, gateway, route map, registry, and projector satisfy the v1
  readiness gate
- **WHEN** the cohort barrier enables new sweep work
- **THEN** every new execution SHALL receive the exact v1 result contract and
  signed assignment capability
- **AND** no compiled config SHALL select `legacy_json_v0`

#### Scenario: Agent is below the minimum edge-record version
- **WHEN** an agent or reachable gateway cannot send, retain, and drain the
  selected v1 contract/spool version
- **THEN** the scheduler SHALL assign it no new sweep or MTR execution
- **AND** SHALL require upgrade rather than select legacy output or route it
  through a compatibility bridge

#### Scenario: Compile v1 execution assignment
- **GIVEN** an enabled v1 agent and a scheduler-admitted execution shard
- **WHEN** config/control delivers the assignment
- **THEN** it SHALL include the immutable plan/range identity, expected count and
  digest, network scope, agent, execution, immutable traffic class, attempt
  epoch, expiry, result format, and signed capability
- **AND** the gateway SHALL be able to verify that capability locally without a
  per-frame core or database request

#### Scenario: Device query evaluation at compile time
- **GIVEN** a sweep job with a device query
- **WHEN** the plan is compiled
- **THEN** the query SHALL be evaluated against authoritative current inventory
- **AND** target ranges/counts/digests and required per-device check overrides
  SHALL be recorded without repeating the full target list in every result batch

#### Scenario: Merge multiple sweep jobs
- **GIVEN** multiple sweep jobs assigned to the same agent
- **WHEN** configuration is compiled
- **THEN** each v1 execution SHALL preserve distinct
  network-scope/plan/shard/check-set/class identity
- **AND** merged configuration SHALL NOT merge independent executions into an
  unbounded result payload or an unsigned shared priority lane

#### Scenario: Agent parses device targets with TCP ports
- **GIVEN** a plan contains TCP SYN or TCP connect checks for device targets
- **WHEN** the agent parses the assignment
- **THEN** it SHALL generate the exact `(mode, protocol, port)` checks assigned
  to each target range
- **AND** ICMP and TCP work SHALL both be generated when configured

#### Scenario: Profile ports are preserved for device-targeted sweeps
- **GIVEN** a sweep group targets devices and its profile supplies TCP checks
- **WHEN** the plan is compiled
- **THEN** those checks SHALL be present in the immutable plan
- **AND** its digest SHALL change if their mode/protocol/port semantics change

#### Scenario: TCP mode requires ports
- **GIVEN** a sweep group enables a TCP mode without a port
- **WHEN** configuration is compiled
- **THEN** the compiler SHALL surface a validation error
- **AND** SHALL NOT issue an executable assignment with an empty check set

#### Scenario: Assignment is resumed or replaced
- **WHEN** a target range is resumed by the same agent or reassigned
- **THEN** the scheduler SHALL preserve the execution/shard/range identity,
  issue a new fenced assignment epoch when ownership changes, and identify the
  remaining target coverage
- **AND** the old capability SHALL expire or be revoked before replacement
  ownership becomes authoritative

#### Scenario: Fenced assignment still has immutable spooled bytes
- **GIVEN** a frame was collected under valid authority before its assignment
  was fenced
- **WHEN** the scheduler freshly authorizes that exact event-ID/`record_sha256`
  for delivery after the fence
- **THEN** a delivery-only capability MAY permit replay with the original
  network scope, agent, execution, and traffic class
- **AND** the replay SHALL remain audit-only and SHALL NOT restore domain
  eligibility, current-state authority, execution counts, or completion credit

### Requirement: Sweep Job Execution Tracking
The system SHALL track scan execution, durable delivery, database projection,
MTR projection, and reconciliation as distinct states. Accurate totals SHALL be
derived from unique authoritative target/mode observations and the immutable
execution plan, not from transport delivery attempts or scanner completion
alone.

#### Scenario: Scanner reports assignment-attempt completion
- **GIVEN** an agent has finished probing its assigned range
- **WHEN** its terminal event is committed
- **THEN** the execution SHALL record scanner completion, duration, cumulative
  counts, and terminal batch sequence for that attempt
- **AND** SHALL remain delivery-pending, projection-pending, partial, or
  MTR-pending until required durable evidence reconciles

#### Scenario: Active scan progress updates
- **GIVEN** an in-progress sweep execution
- **WHEN** bounded progress/watermark events are ingested
- **THEN** core SHALL expose unique scanner, durable-delivery, and projection
  progress without incrementing totals on redelivery
- **AND** the Active Scans UI SHALL distinguish those stages and missing ranges

#### Scenario: Long-lived execution emits bounded microbatches
- **GIVEN** an execution remains active across many collection windows
- **WHEN** bounded result and progress microbatches are committed
- **THEN** execution tracking SHALL reconcile each independent sequence range
  without requiring the execution to close
- **AND** scanner, delivery, projection, and MTR state SHALL NOT depend on a
  run-wide accumulated payload

#### Scenario: Reachability is projected before MTR
- **GIVEN** ICMP/TCP observations are queryable but expected correlated MTR
  traces are not all terminally projected
- **WHEN** execution state is displayed
- **THEN** reachability MAY be shown as available
- **AND** MTR SHALL show pending/missing/failed/quarantined counts
- **AND** the execution SHALL NOT claim full reconciliation

#### Scenario: Execution becomes reconciled complete
- **WHEN** every authoritative plan range and assignment attempt is terminal,
  all declared batch ranges have committed, and every expected MTR trace is
  projected or explicitly terminally failed
- **THEN** the execution SHALL record reconciled completion and exact unique
  totals
