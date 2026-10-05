## ADDED Requirements

### Requirement: Dgraph calls hold no BEAM scheduler
The system SHALL run every Dgraph NIF operation without blocking a BEAM scheduler. The NIF SHALL return a submission on a normal scheduler, run the operation on the native runtime, and deliver the result to the caller as a message.

#### Scenario: Stalled Dgraph
- **WHEN** Dgraph accepts connections but never answers
- **AND** more Dgraph calls are in flight than there are dirty-IO schedulers
- **THEN** file I/O and other dirty-IO work on the node still complete
- **AND** each stalled call ends with `{:error, _}` by its deadline

#### Scenario: Panic inside a call
- **WHEN** a Dgraph operation panics in native code
- **THEN** the caller receives `{:error, _}`
- **AND** the call's in-flight slot is released

### Requirement: Bounded Dgraph call deadlines
The system SHALL bound every Dgraph call by a deadline: 10 seconds to connect, 30 seconds for single-item reads and writes, and 300 seconds for whole-graph reads, pruning, and the canonical rebuild. Time spent waiting for an in-flight slot SHALL count against the deadline.

#### Scenario: Deadline passes
- **WHEN** a call has not completed by its deadline
- **THEN** the caller receives `{:error, reason}` naming the timeout

#### Scenario: Queued past the deadline
- **WHEN** a call waits for an in-flight slot until its deadline passes
- **THEN** the call fails as a timeout without contacting Dgraph

### Requirement: Dgraph call backpressure
The system SHALL limit concurrent in-flight Dgraph calls, and SHALL make calls beyond the limit wait for a slot rather than refusing them.

#### Scenario: Burst above the limit
- **WHEN** more calls are submitted than the in-flight limit
- **THEN** the excess calls wait and run as slots free
- **AND** no call is rejected for being over the limit

#### Scenario: Stalled bulk calls
- **WHEN** whole-graph reads, pruning or canonical rebuilds stall in numbers above every limit
- **THEN** a single-item call still obtains a slot from its own pool

### Requirement: Cancelled calls leave no reply
The system SHALL cancel a Dgraph call whose caller stops waiting, and SHALL ensure that a cancelled call never delivers a reply to the caller's mailbox.

#### Scenario: Caller gives up first
- **WHEN** the caller's wait ends before the reply arrives
- **THEN** the native task is cancelled
- **AND** no reply for that call arrives afterwards

#### Scenario: Reply already in flight
- **WHEN** the caller cancels after the native task has claimed its reply
- **THEN** the caller collects that reply before returning

#### Scenario: Caller exits while waiting
- **WHEN** the calling process exits before its call replies
- **THEN** the native task is cancelled and its in-flight slot is released immediately

### Requirement: Retry only idempotent Dgraph writes
The system SHALL retry a Dgraph call after a timeout or transient failure only when the operation is an idempotent keyed upsert, with a bounded number of attempts and jittered backoff, and SHALL return the final failure to the caller as `{:error, _}`.

#### Scenario: Idempotent upsert during an outage
- **WHEN** a device upsert fails because the cluster is unreachable
- **THEN** it is retried up to the attempt limit
- **AND** the caller receives `{:error, _}` when every attempt fails

#### Scenario: Operation whose repeat is unsafe
- **WHEN** pruning, hosted-edge replacement or retirement, the canonical rebuild, or a read fails transiently
- **THEN** it is not retried
- **AND** the caller receives `{:error, _}`

### Requirement: Dgraph call telemetry
The system SHALL emit telemetry for each Dgraph call attempt's queue wait and latency, for each call cancelled at the caller's deadline, and for each retry.

#### Scenario: Observed call
- **WHEN** a Dgraph call attempt completes
- **THEN** a `[:serviceradar, :dgraph, :call, :stop]` event carries its duration and queue wait

#### Scenario: Retried call
- **WHEN** a call is retried
- **THEN** a `[:serviceradar, :dgraph, :call, :retry]` event carries the failed attempt and its backoff

### Requirement: Native panics unwind in every NIF build
The system SHALL compile every NIF with the unwind panic strategy, and SHALL fail the build when a NIF is compiled with `panic=abort`.

#### Scenario: Abort strategy selected
- **WHEN** a NIF crate is compiled with `panic=abort`
- **THEN** compilation fails
