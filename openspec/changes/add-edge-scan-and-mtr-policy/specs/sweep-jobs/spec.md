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

