# sweeper Delta

## MODIFIED Requirements

### Requirement: Sweep Results Push to Agent-Gateway
The agent's producer adapter SHALL encode each sweep observation once as a
bounded `SweepObservationBatchV1` contract payload; the agent-owned sink SHALL
construct and encode the versioned, byte-bounded `EdgeRecordV1` and carry those
exact bytes to the agent-gateway inside `EdgeDeliveryFrameV1` while a sweep is
running. It SHALL durably spool each
record plus its delivery binding before transmission, retain it through restart
until cumulatively acknowledged, and SHALL NOT require full-scan result
materialization. An
execution MAY be long-lived, but every start, data, progress, trace, and terminal
record SHALL remain an independently bounded microbatch with its own durable
delivery and acknowledgement lifecycle.

#### Scenario: Agent starts a sweep execution stream
- **GIVEN** an enabled agent starts a sweep execution shard
- **WHEN** result production begins
- **THEN** the agent SHALL spool and send a start event carrying authoritative
  `network_scope_id`/site, agent, execution, shard, assignment attempt,
  immutable scheduler-signed traffic class, plan/range digest, and
  expected-count metadata
- **AND** the event SHALL not contain the complete target result set

#### Scenario: Agent streams completed host windows
- **GIVEN** a large sweep is still processing later targets
- **WHEN** an earlier bounded window has terminal ICMP/TCP outcomes
- **THEN** the agent SHALL encode and spool independently decodable host batches
- **AND** send them without waiting for the entire sweep to finish
- **AND** release delivery-owned host/port memory after durable spooling

#### Scenario: Execution remains active for an extended interval
- **GIVEN** one execution remains active across many target windows or polling
  intervals
- **WHEN** each window becomes independently complete
- **THEN** the agent SHALL flush it under the configured frame byte/count/time
  bounds
- **AND** SHALL NOT grow a run-wide result accumulator or defer acknowledgement
  until the execution ends

#### Scenario: MTR finishes after reachability
- **GIVEN** ICMP/TCP has reached a terminal state while a configured MTR phase is
  still running
- **WHEN** the base host fragment is ready
- **THEN** the agent SHALL stream the ICMP/TCP fragment without waiting for MTR
- **AND** later emit a separately revisioned MTR-mode fragment carrying the
  correlated summary and trace ID
- **AND** consumers SHALL merge revisions independently for only the modes
  declared by each fragment

#### Scenario: One MTR trace completes
- **GIVEN** later traces in the same execution are still running
- **WHEN** a source finishes one complete MTR trace
- **THEN** it SHALL immediately pass that trace to the bounded trace-frame
  builder and durable spool
- **AND** SHALL release per-trace producer memory after durable spooling
- **AND** SHALL NOT retain a run-wide or interval-wide slice of completed traces

#### Scenario: Agent reports bounded progress
- **GIVEN** a sweep is in progress
- **WHEN** the configured count or time threshold is reached
- **THEN** the agent SHALL emit a rate-limited progress/watermark event with
  cumulative counts and the highest closed batch sequence
- **AND** SHALL NOT emit one progress event per host

#### Scenario: Concurrent builders allocate data batches
- **GIVEN** multiple mode/window builders flush for one assignment attempt
- **WHEN** their frames become durable
- **THEN** they SHALL share one contiguous sweep-data batch sequence beginning at
  one, with no intentional gaps
- **AND** progress/terminal evidence SHALL close only a prefix from that sequence

#### Scenario: Agent completes or aborts an execution
- **WHEN** every target window in a shard reaches a terminal state or the shard
  is aborted
- **THEN** the agent SHALL emit one stable terminal evidence event for the
  assignment attempt containing terminal sequence, cumulative result counts,
  and expected/emitted MTR summary and trace reconciliation data
- **AND** durable delivery completion SHALL remain distinct from scan execution
  completion until required frames are acknowledged

#### Scenario: No sweep activity occurs
- **WHEN** no sweep has executed and no retained spool frame needs retry
- **THEN** the agent SHALL NOT emit periodic sweep result frames

### Requirement: Gateway Forwards Sweep Results to Core
The agent-gateway SHALL authenticate and validate sweep `EdgeDeliveryFrameV1`
messages, then publish their exact `EdgeRecordV1` bytes to the installation-local,
partitioned shared JetStream edge-record route
selected by the platform profile and immutable scheduler-signed traffic class.
Bulk and interactive frames SHALL use
disjoint physical streams and durable consumers. The gateway SHALL preserve the
exact `EdgeRecordV1` bytes carried by `EdgeDeliveryFrameV1`, publish those bytes
unchanged with transport-minimal broker headers, wait for a valid PubAck, and
only then return an accepted disposition.

#### Scenario: Gateway receives a valid sweep frame
- **GIVEN** the gateway authenticates an agent and validates a supported delivery
  frame and its contained record
- **WHEN** it routes the frame
- **THEN** it SHALL compute the partition from trusted network scope, agent,
  execution, immutable traffic class, and stable shard keys
- **AND** publish the exact `record_bytes` to the expected class-specific
  edge-record stream without re-encoding or semantic broker headers
- **AND** advance the contiguous resolved watermark only after an
  authoritative-stream PubAck (accept) or an audit/DLQ PubAck (permanent reject);
  a retryable/transient publication failure SHALL leave the sequence unresolved
  and SHALL NOT advance the watermark

#### Scenario: JetStream or its consumer is unavailable
- **GIVEN** a frame cannot be durably accepted because the stream is unavailable
  or full
- **WHEN** publication fails or times out
- **THEN** the gateway SHALL withhold the edge ACK and apply bounded
  backpressure
- **AND** SHALL NOT place the frame in the volatile `StatusBuffer`, drop its
  oldest result, or route it directly to a database writer

#### Scenario: Gateway receives spoofed routing metadata
- **WHEN** decoded record metadata conflicts with the authoritative network scope,
  authenticated agent, execution assignment, or signed traffic class
- **THEN** the gateway SHALL reject it without publishing
- **AND** record an attributable protocol/security error

#### Scenario: Sweep frame enters quarantine or DLQ
- **WHEN** a sweep frame is quarantined, moved to a poison DLQ, or later
  authorized for redrive
- **THEN** its original signed traffic class SHALL remain immutable and
  auditable
- **AND** redrive SHALL use the same class-specific stream and SHALL NOT promote
  bulk work into the interactive path

### Requirement: Core Processes Sweep Results via DIRE
Partitioned event-writer consumers SHALL decode independently durable sweep
micro-batches and apply replay-safe, bounded database transactions. DIRE SHALL
resolve devices through bounded bulk authoritative CNPG lookup, then update
eligible per-agent/current device state, sweep history, deterministic OCSF
events, mapper-promotion decisions, and execution reconciliation without
retaining or reconstructing a full scan or issuing one lookup per host.

#### Scenario: Update device availability from sweep
- **GIVEN** committed per-mode sweep observations derive a host availability
  state under the execution's versioned policy
- **WHEN** the sweep projector processes it
- **THEN** DIRE SHALL bulk-match eligible existing devices by authoritative
  canonical identity rather than a stale cache
- **AND** update the latest `(network_scope_id, device, agent)` availability only under the
  deterministic per-mode observation order
- **AND** derive `ocsf_devices.is_available` through the configured canonical
  availability-source policy
- **AND** update `ocsf_devices.last_seen_time` for available devices
- **AND** add `sweep` to `discovery_sources`

#### Scenario: Ignore sweep hosts not in inventory
- **GIVEN** a sweep observation is for a host not in device inventory
- **WHEN** DIRE applies inventory updates
- **THEN** it SHALL NOT create a new device or alias record
- **AND** the raw observation and execution count MAY still be recorded for
  audit and promotion decisions
- **AND** no mapper-promotion metadata SHALL be attached without an authoritative
  loaded device

#### Scenario: Enrich device with port information
- **GIVEN** a newer sweep observation contains TCP port data
- **WHEN** core processes it
- **THEN** current device metadata SHALL be updated with open ports
- **AND** device type MAY be inferred from supported port signatures

#### Scenario: Hosts have different TCP check sets
- **GIVEN** profile or device overrides produce different `(mode, protocol,
  port)` check sets
- **WHEN** the agent builds sweep batches
- **THEN** it SHALL place hosts only with an identical attempted-check dictionary
  in the same batch
- **AND** SYN and connect outcomes for the same port SHALL remain distinct

#### Scenario: Batch is redelivered
- **WHEN** a previously committed `(network_scope_id, event_id)` is received
  again with a matching stored `semantic_envelope_sha256`
- **THEN** the consumer SHALL acknowledge it without duplicating sweep history,
  OCSF events, state transitions, or execution counts

#### Scenario: Execution batches arrive out of order
- **GIVEN** multiple shards/executions are interleaved or one shard's data and
  terminal evidence arrives out of sequence
- **WHEN** core consumes their independently decodable batches
- **THEN** it SHALL process each batch without an arrival-order lock
- **AND** completion SHALL be reconciled from the immutable plan, authoritative
  attempt terminal state/evidence, and committed sequence ranges

#### Scenario: State observations arrive in opposite orders
- **GIVEN** the same older/newer authoritative observations are projected in two
  broker arrival permutations
- **WHEN** their event-time epoch becomes reconciled
- **THEN** both permutations SHALL produce the same final state and deterministic
  immutable observation-event IDs
- **AND** lifecycle transition/correction IDs SHALL come from the watermark
  reconciler rather than the first projector that updates the current row
