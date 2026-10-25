## MODIFIED Requirements
### Requirement: One owner reconciles each stream shape
Exactly one component SHALL reconcile the shape (`max_bytes`, replicas, retention) of a given stream. For `events`, `flows` and `ARANCINI_CAUSAL`, which the otel log-collector, flow-collector or bmp-collector and EventWriter can each write, the owner SHALL be recorded in the stream's metadata under the key `serviceradar.owner`, with the values `otel-log-collector`, `flow-collector`, `bmp-collector` and `event-writer`.
When its dedicated component runs it SHALL set `serviceradar.owner` to its own name on its stream, creating the stream when absent, and reconcile the shape; that claim SHALL override an `event-writer` claim.
EventWriter SHALL claim only streams it creates. It SHALL create `events`, `flows` and `ARANCINI_CAUSAL` when absent with `serviceradar.owner` set to `event-writer` and the fallback size and replicas from `SERVICERADAR_JS_<STREAM>_FALLBACK_MAX_BYTES` and `_FALLBACK_REPLICAS`, never unlimited, and it SHALL reconcile a stream it claimed. It SHALL merge subjects only, never overriding the claim, when another component holds it.
A stream created before this change has no metadata. EventWriter SHALL merge subjects only on such a stream and SHALL NOT change its shape until the stream has stayed unclaimed for a grace period of 15 minutes by default; only then SHALL it set `serviceradar.owner` to `event-writer` and reconcile the shape.
EventWriter SHALL check this with an ownership reconcile timer, a periodic tick in the coordinator-only consumer reconciler (one per deployment), every 5 minutes by default and configurable, that re-reads each multi-owner stream it consumes, records in process state when it first saw the stream unclaimed, and applies the claim rule. The timer SHALL only issue stream updates and SHALL NOT tear down or resubscribe a consumer, and it SHALL be distinct from the retry of consumers that failed to set up. A restart SHALL reset the recorded time, which can delay convergence but SHALL NOT cause an early claim.
The timer SHALL watch every multi-owner stream the EventWriter consumes for the life of the process. On each tick it SHALL reconcile the shape of a stream claimed by `event-writer` if it drifted, merge subjects only on a stream claimed by a collector, and apply the grace period to an unclaimed stream, so a reclaim takes effect within one tick on a running install. A dedicated component SHALL claim a legacy stream as soon as it starts, without waiting. EventWriter SHALL re-read the stream immediately before its claim update and skip the update if any claim has appeared.
When a collector is disabled after claiming a stream, the claim and the stream size SHALL remain until an operator reclaims it, and the runbook SHALL document the reclaim. The render-time budget and the non-Helm preset budget SHALL count `flows` and `ARANCINI_CAUSAL` at the collector size whether or not the collector is enabled.
An ownership test SHALL exercise the EventWriter claim decision, with an injected clock, for each of `events`, `flows` and `ARANCINI_CAUSAL` with no claim inside and after the grace period, an `event-writer` claim and a collector claim, including a restart that resets the clock, and SHALL fail if EventWriter reconciles the shape of a stream claimed by another component or of a legacy stream inside the grace period. Behaviour of the Go and Rust owners is covered by each owner's own tests.

#### Scenario: Claim on first start
- **GIVEN** `ARANCINI_CAUSAL` does not exist and bmp-collector is enabled
- **WHEN** bmp-collector starts
- **THEN** it SHALL create the stream with `serviceradar.owner` set to `bmp-collector` and its configured size and replicas

#### Scenario: Collector claim overrides an EventWriter claim
- **GIVEN** `flows` exists with `serviceradar.owner` set to `event-writer` and a 1 GiB `max_bytes`
- **WHEN** flow-collector starts
- **THEN** it SHALL set `serviceradar.owner` to `flow-collector`
- **AND** the stream's `max_bytes` and replicas SHALL become its configured values

#### Scenario: EventWriter does not reconcile a collector-claimed stream
- **GIVEN** `events` exists with `serviceradar.owner` set to `otel-log-collector` and a 2 GiB `max_bytes`
- **WHEN** EventWriter starts
- **THEN** the stream's `max_bytes`, replicas and retention SHALL be unchanged
- **AND** EventWriter SHALL only merge its subjects

#### Scenario: Upgrade with a collector, legacy stream, no eviction
- **GIVEN** an install with flow-collector enabled and `flows` with no metadata and a 10 GiB `max_bytes` holding 9 GiB, created earlier by EventWriter
- **WHEN** core and flow-collector restart together and EventWriter's consumers set up first
- **THEN** EventWriter SHALL merge subjects only and SHALL NOT change `max_bytes`, replicas or retention
- **AND** flow-collector SHALL claim the stream and set `max_bytes` to 8 GiB with its configured replicas
- **AND** no message SHALL be evicted by EventWriter

#### Scenario: Upgrade with no collector, legacy stream converges after the grace period
- **GIVEN** an install with no collector and `flows` with no metadata and a 10 GiB `max_bytes`, created earlier by EventWriter
- **WHEN** EventWriter sets up its consumers
- **THEN** it SHALL leave the shape unchanged during the 15 minute grace period
- **AND** after the stream has stayed unclaimed for the grace period it SHALL set `serviceradar.owner` to `event-writer` and reconcile `max_bytes` to the 1 GiB fallback, evicting the oldest messages and logging the values before and after

#### Scenario: The timer converges a stream that set up successfully
- **GIVEN** a collector-less install whose `flows` consumers set up successfully on a legacy 10 GiB stream, merging subjects only
- **WHEN** the ownership reconcile timer ticks after the stream has been observed unclaimed for the grace period
- **THEN** it SHALL claim the stream for `event-writer` and reconcile it to the fallback
- **AND** no consumer SHALL be torn down or resubscribed

#### Scenario: Restart resets the grace clock
- **GIVEN** EventWriter observed a legacy stream unclaimed for 10 minutes and then restarts
- **WHEN** the timer ticks after the restart
- **THEN** the grace period SHALL start again and the stream SHALL NOT be claimed until it has been unclaimed for the full grace period after the restart

#### Scenario: A collector claims inside the grace period
- **GIVEN** a legacy `flows` stream and EventWriter within its grace period
- **WHEN** flow-collector starts and claims the stream before the grace period ends
- **THEN** EventWriter SHALL find the collector claim and SHALL NOT claim or reconcile the stream

#### Scenario: EventWriter re-reads before claiming
- **GIVEN** a legacy stream that has stayed unclaimed for the grace period
- **AND** a collector claims it between EventWriter's check and its update
- **WHEN** EventWriter re-reads the stream immediately before updating
- **THEN** it SHALL skip the update

#### Scenario: EventWriter creates the stream when it is absent
- **GIVEN** `ARANCINI_CAUSAL` does not exist and no bmp-collector is running
- **WHEN** EventWriter starts
- **THEN** it SHALL create the stream with `serviceradar.owner` set to `event-writer` and the 1 GiB fallback `max_bytes`, not unlimited, and claim needs no grace period because EventWriter created it

#### Scenario: Collector disabled after claiming
- **GIVEN** `ARANCINI_CAUSAL` is claimed by `bmp-collector` at 12 GiB and bmp-collector is then disabled
- **WHEN** EventWriter starts and its ownership timer ticks
- **THEN** the stream SHALL remain at 12 GiB
- **AND** the budget SHALL already have counted it at the collector size

#### Scenario: Reclaim by setting the owner
- **GIVEN** `ARANCINI_CAUSAL` is claimed by `bmp-collector` at 12 GiB, bmp-collector is disabled, and EventWriter is running
- **WHEN** an operator sets `serviceradar.owner` to `event-writer` with the runbook command
- **THEN** at the next ownership timer tick, with no grace period and no core restart, EventWriter SHALL reconcile the stream to the fallback

#### Scenario: Reclaim by removing the claim
- **GIVEN** the same stream and an operator who removes `serviceradar.owner`
- **WHEN** the ownership timer ticks
- **THEN** EventWriter SHALL treat the stream as unclaimed and start the grace period, and SHALL claim and reconcile it only after the grace period

#### Scenario: EventWriter claim decision is safe
- **GIVEN** each of `events`, `flows` and `ARANCINI_CAUSAL` with no claim, an `event-writer` claim and a collector claim
- **WHEN** the ownership test runs
- **THEN** EventWriter SHALL reconcile only the unclaimed and `event-writer` cases
