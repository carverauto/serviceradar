# Design: Durable protobuf edge observation data plane

## Context

The live sweep path is:

```text
Go sweep summary -> whole-run JSON -> ResultsChunk -> StreamStatus
  -> agent-gateway -> asynchronous ERTS cast -> core ResultsRouter
  -> JSON decode -> sweep/device/OCSF writes
```

The agent also parses that sweep JSON back into generic maps and creates a
second protobuf `MetricBatch`. Scheduled MTR similarly sends full JSON on the
direct results path and a separate scalar `MetricBatch`. The metric copy is
published to JetStream, but it is not the complete MTR trace and does not write
the MTR trace/hop tables.

This is not merely a serialization problem:

- the agent deep-copies/materializes an entire scan before delivery;
- a one-million-host payload exceeds the 64 MiB `StreamStatus` window;
- the gateway can acknowledge before durable storage and can drop from its
  volatile fallback queue;
- Core NATS publish does not provide a JetStream PubAck;
- one core results router serializes high-volume work;
- generic metric expansion can create tens of rows per host and hundreds per
  trace; and
- replay is not idempotent across sweep, OCSF, execution, and MTR projections.

## Goals

- Bound memory by active scan window plus in-flight/spooled bytes, not fleet
  size or completed scan size.
- Encode each canonical domain batch once at the agent, pass its bytes through
  the gateway, and decode once in each downstream consumer.
- Acknowledge the agent only after the observation is durably stored in
  JetStream.
- Preserve complete sweep, execution, scanner, banner, and MTR trace fidelity.
- Support at-least-once delivery with application-level idempotency.
- Make overload explicit through backpressure, spool pressure, stream limits,
  and incomplete-execution state; never silently report success after a drop.
- Scale consumption horizontally with fixed logical partitions, bounded shared
  pull consumers, and database-enforced concurrency correctness.
- Keep raw history bounded while preserving current state and useful rollups.

## Non-Goals

- Replacing JSON in low-volume commands, configuration, or administrative APIs.
- Moving broker-free sync snapshots onto JetStream in this change.
- Treating JetStream Object Store as a telemetry lake.
- Claiming literal end-to-end zero-copy across protobuf, gRPC/TLS, BEAM, NATS,
  replicas, and PostgreSQL WAL.
- Selecting a new database before the canonical workload is benchmarked against
  the existing CNPG/Timescale path and candidate alternatives.

## Workload Model

The architecture is sized around completed observations, not just agent count.
The first benchmark profile is one million targets, ICMP plus ten TCP ports,
hourly, with results draining in a six-minute burst.

Order-of-magnitude estimates to validate with fixtures:

| Representation | Approximate one-million-host size | Six-minute drain |
|---|---:|---:|
| Current ICMP + ten-port JSON | 0.8-0.9 GB | 2-3 MB/s |
| Straightforward host protobuf | 150-220 MB | 0.4-0.7 MB/s |
| Compact batch-oriented protobuf | 80-140 MB | 0.2-0.4 MB/s |
| Duplicate per-host generic MetricBatch | 3.5-5.5 GB | 10-16 MB/s |
| Full twenty-hop MTR protobuf for every host | 1.5-4 GB | 4-12 MB/s |
| MTR flattened into generic metric points | 40-70 GB | 110-200 MB/s |

The average rate of one million hosts per hour is only 278 hosts/second. The
danger is synchronized bursts, whole-run memory, duplicate row expansion,
per-hop multiplication, hot execution counters, and database/index/WAL cost.
The design therefore removes whole-run and duplicate representations before
micro-optimizing protobuf allocation.

Universal hourly MTR is not a reasonable default. At twenty hops it produces
twenty-one persisted rows per trace and can require tens of millions of probes
per run. The scheduler must budget and shard MTR independently from sweep host
summaries.

ServiceRadar installations are single-customer security and capacity domains;
the SaaS control plane provisions customers in separate clusters. This data plane
therefore does not add per-tenant NATS accounts, database schemas, capacity cells,
or fairness. Inside one installation, fairness and identity are hierarchical by
network/site partition, agent, execution, and traffic class. `network_scope_id`
is an explicit site/address-space namespace so overlapping RFC1918 networks do
not collide; it is not a SaaS tenant identifier.

## Decision 1: Layer the transport and durability responsibilities

```text
scan workers
  -> crash-safe agent spool
  -> bidirectional mTLS gRPC result stream
  -> authenticated stateless gateway
  -> JetStream publish request + PubAck
  -> partitioned pull consumers
  -> idempotent bounded database transactions
```

- gRPC provides edge authentication, connection management, streaming flow
  control, and cumulative application acknowledgements.
- The gateway is the trust boundary and sole publisher for agent-originated
  sweep/MTR observations. It does not own durable delivery state.
- JetStream is the durable commit, replay, fan-out, and backlog boundary.
- ERTS/direct core calls remain for control, configuration, commands, heartbeat,
  and small status. They are not a bulk persistence acknowledgement.
- The agent spool owns unacknowledged data. If JetStream is unavailable or full,
  the gateway withholds ACKs and the agent retains the frames.

This avoids a gateway persistent-volume requirement and keeps gateways
replaceable. A future gateway disk spool may be proposed for sites that must
accept data while every agent is storage-constrained, but it is not part of the
v1 correctness chain.

## Decision 2: Use a generic transport frame with typed domain payloads

The outer frame is decoded by gRPC. The gateway validates it without decoding
the inner domain message and publishes `payload` unchanged.

Illustrative normative shape (exact package placement is an implementation
task, but field meanings and presence are fixed here):

```proto
enum EdgeResultPayloadKind {
  EDGE_RESULT_PAYLOAD_KIND_UNSPECIFIED = 0;
  EDGE_RESULT_PAYLOAD_KIND_SWEEP_OBSERVATION_BATCH_V1 = 1;
  EDGE_RESULT_PAYLOAD_KIND_SWEEP_EXECUTION_EVENT_V1 = 2;
  EDGE_RESULT_PAYLOAD_KIND_MTR_TRACE_BATCH_V1 = 3;
  EDGE_RESULT_PAYLOAD_KIND_LEGACY_SWEEP_JSON_V0 = 4;
  EDGE_RESULT_PAYLOAD_KIND_LEGACY_MTR_JSON_V0 = 5;
  EDGE_RESULT_PAYLOAD_KIND_SPOOL_LOSS_TOMBSTONE_V1 = 6;
}

enum EdgeResultCompression {
  EDGE_RESULT_COMPRESSION_NONE = 0;
  EDGE_RESULT_COMPRESSION_ZSTD = 1;
}

enum EdgeResultAuthorizationKind {
  EDGE_RESULT_AUTHORIZATION_KIND_UNSPECIFIED = 0;
  EDGE_RESULT_AUTHORIZATION_KIND_SWEEP_ASSIGNMENT = 1;
  EDGE_RESULT_AUTHORIZATION_KIND_SCHEDULED_CHECK = 2;
  EDGE_RESULT_AUTHORIZATION_KIND_COMMAND = 3;
  EDGE_RESULT_AUTHORIZATION_KIND_SPOOL_RECOVERY = 4;
}

enum EdgeResultTrafficClass {
  EDGE_RESULT_TRAFFIC_CLASS_UNSPECIFIED = 0;
  EDGE_RESULT_TRAFFIC_CLASS_BULK = 1;
  EDGE_RESULT_TRAFFIC_CLASS_INTERACTIVE = 2;
}

message EdgeResultFrame {
  string spool_id = 1;                 // persistent UUID for one delivery lane
  uint64 sequence = 2;                 // persistent, strictly increasing
  string event_id = 3;                 // stable across every retry
  EdgeResultPayloadKind payload_kind = 4;
  uint32 schema_version = 5;
  EdgeResultCompression compression = 6;
  uint32 encoded_size = 7;
  uint32 uncompressed_size = 8;
  bytes payload_sha256 = 9;            // SHA-256 of encoded payload bytes
  string execution_id = 10;            // bounded routing/correlation hint
  uint32 execution_shard = 11;
  optional uint64 assignment_epoch = 12;
  bytes collection_capability = 13;    // signed permission valid at collection
  uint32 projected_row_count = 14;     // verified downstream upper-bound hint
  bytes payload = 15;                  // canonical domain protobuf bytes
  EdgeResultAuthorizationKind authorization_kind = 16;
  string authorization_context_id = 17;
  string target_range_id = 18;
  bytes target_range_sha256 = 19;
  bytes delivery_capability = 20;      // renewable permission to drain old data
  uint64 projected_write_bytes = 21;   // conservative SQL/index/WAL byte cost
  uint32 cost_model_version = 22;
  string network_scope_id = 23;        // signed site/address-space namespace
  EdgeResultTrafficClass traffic_class = 24;
}

enum EdgeResultDispositionKind {
  EDGE_RESULT_DISPOSITION_KIND_UNSPECIFIED = 0;
  EDGE_RESULT_DISPOSITION_KIND_ACCEPTED = 1;
  EDGE_RESULT_DISPOSITION_KIND_REJECTED = 2;
}

message EdgeResultDisposition {
  uint64 sequence = 1;
  string event_id = 2;
  EdgeResultDispositionKind kind = 3;
  string rejection_code = 4;
}

message EdgeResultAck {
  string spool_id = 1;
  uint64 resolved_through_sequence = 2; // contiguous accepted/rejected prefix
  repeated EdgeResultDisposition dispositions = 3;
}
```

All UUID-backed identifiers (`spool_id`, event/trace/execution/plan IDs, and
source IDs stored as UUIDs) use canonical 16-byte UUID fields in the final
protobuf contract. A field retained as text for legacy compatibility MUST be a
validated lowercase canonical UUID representation, reject nil/noncanonical aliases,
and have identical Go/Elixir normalization fixtures.

Every v1 semantic `event_id`, and every patched-legacy frame event ID admitted to
this path, is RFC 9562 UUIDv7 allocated once before durable spooling. Its UUIDv7
timestamp selects the trusted metadata retirement bucket and must match the
signed collection/execution interval plus the defined terminal grace and clock
tolerance. The same event ID therefore cannot move between metadata partitions;
recovery preserves it even when delivery coordinates change.

The agent persists `spool_id`, sequence, event ID, checksum, encoded body,
authorization context/range, and the collection-capability proof before sending.
A retry within a lane reuses its delivery coordinates and all semantic/payload
values. Crash-safe recovery MAY copy the same semantic event to a new spool ID
and sequence as defined below. Only delivery coordinates, the outer renewable
delivery capability, and deployment stream-map metadata may change without
changing domain identity. The gateway MUST NOT advance an ACK past a missing or
failed sequence.

Sequence space is scoped to a durable delivery lane: sweep-bulk,
sweep-interactive, MTR-bulk, MTR-interactive, and a minimal separately reserved
spool-recovery control lane, not to all traffic from an agent. Interactive is a
hard-size/rate/duration-bounded service class assigned by the scheduler, not a
caller-controlled priority bit. A blocked MTR frame, bulk backlog, or corrupt
sweep sequence therefore cannot prevent bounded interactive reachability or its
own audited loss recovery. Each lane uses an independent bidirectional RPC.
Bulk, interactive, and recovery RPCs use separately pooled HTTP/2 transport
connections with reserved connection-level windows and pending-byte ceilings;
they are not multiplexed onto one connection whose flow-control window can be
consumed by another class. Flow-control credits, reclaim watermarks, and spool
quotas remain independent.

The data-lane rollover protocol below does not recurse through a corrupt control
sequence. Recovery-control metadata is kept in a separately reserved,
double-written generation journal. If its active generation is corrupt, the
agent opens a fresh recovery-control generation under an explicit scheduler
recovery capability and reports the compact loss scope of the prior generation;
the gateway never requires the damaged generation's contiguous ACK to accept the
replacement. If neither journal copy can establish a trustworthy scope, the
agent stops all scan admission and the scheduler fences/times out affected work;
it does not claim recovery or durability.

Every lane opens with `spool_id`, lane kind, sequence base (sequences start at
one), first unresolved sequence, a fresh random session nonce, and requested
byte/frame credits. The gateway echoes the nonce and negotiated credits. An
agent has one active sender per lane and ignores dispositions for an old nonce,
spool ID, or closed session. A replacement gateway reconstructs no private ACK
state: the agent replays from its first unresolved sequence, identical broker
IDs deduplicate accepted frames, and the gateway builds a new resolved prefix
from the declared base. Concurrent stale sessions may duplicate publication but
cannot reclaim the active spool or violate database correctness.

Each disposition says whether the sequence was accepted by its primary stream
or permanently rejected. `resolved_through_sequence` advances only across a
contiguous run for which every primary acceptance has a PubAck and every
permanent rejection has an audit/DLQ PubAck. The agent deletes accepted records,
moves rejected records to durable local quarantine, and only then reclaims the
resolved prefix. This permits progress past poison data without describing a
rejection as successful telemetry ingestion.

Permanent protocol rejection is returned as a bounded structured disposition
after its deployment-local audit record has obtained a DLQ PubAck; the agent
quarantines the rejected frame locally and surfaces an operator alert. Raw bytes
that violate ingress size or trust bounds remain in that local quarantine and
the audit record carries only safe bounded metadata plus its checksum. Transient
gateway, NATS, DLQ, or capacity failures leave the frame unresolved.

Raw quarantine has explicit bulk/interactive byte accounting, an unborrowable
interactive floor, a total byte quota, retention policy, class-specific
high/low-water admission thresholds, and owner-acknowledged export/deletion workflow. Moving a
rejected record is an atomic crash-safe rename/index update, not an extra
unbounded copy; the spool prefix is reclaimed only after quarantine durability.
At quarantine high-water, new scan admission stops and operator paging begins.
Bytes are never overwritten or silently expired, so a bad rollout cannot hide a
fleet-wide rejection storm by filling agent disks while the normal spool appears
healthy.

After a gateway protocol fix, fleet orchestration may issue an audited
reclassification instruction scoped to agent, rejection code/version, frame
fingerprint, and time cohort. The agent revalidates each selected quarantined
frame and crash-safely re-enqueues unchanged semantic bytes under new spool
coordinates and replacement delivery authority. This path is rate limited,
reports per-agent progress, and uses the normal semantic ledger for idempotency.
Local raw bytes are deleted only after accepted resolution or an explicit
operator waiver, not merely because the central audit record exists.

Collection and delivery authority are separate. The collection capability
proves that the agent was allowed to perform the check under the named context,
range, and epoch at observation time; expiry immediately forbids starting new
probes. If an immutable spooled frame outlives that capability or its PubAck is
lost across a fence, the scheduler may issue a short-lived delivery capability
bound to network scope, agent, spool ID/sequence, event ID, payload checksum, original
collection-capability digest, and range. Renewal changes no semantic event or
payload identity and grants no collection right. The gateway may use it only to
publish the old bytes. The consumer still applies current authoritative fencing:
pre-fence data may remain audit history, but cannot displace a replacement
attempt. A frame without valid collection proof and either current collection
authority or explicit delivery authority remains unresolved or quarantined; it
is never silently relabeled as newly collected data.

If crash recovery changes spool coordinates, a replacement delivery capability
also binds `recovery_id`, old and new coordinates, and the unchanged semantic
digest. It is authorized only against the durable rollover/recovery record; an
old coordinate-bound capability cannot be replayed for arbitrary new bytes.

All capabilities use versioned canonical signing bytes and carry issuer, key ID,
algorithm, not-before/expiry, network-scope/agent/context/range, and fence claims. Normal
verification keys overlap for at least the maximum supported agent-spool/offline
plus JetStream replay/rollback horizon. Before routine retirement, remaining
backlog is drained or receives delivery-only reauthorization against retained
authoritative assignment records. A compromised key is revoked fail-closed:
affected backlog is quarantined/audited and coverage is recollected under a new
epoch, never blindly re-signed. Key and assignment verification metadata obey the
safe-GC floor defined below.

Compression defaults to none. Zstandard level 1 may be enabled per capability
only after CPU/wire benchmarks show a net benefit. Consumers use streaming
decompression with independent hard output and expansion-ratio limits, reject
unsupported dictionaries, concatenated/trailing frames, and excessive protobuf
recursion/depth, then verify the actual output size equals the declaration. The
declared uncompressed size is never trusted as an allocation authority.

## Decision 3: Keep sweep summaries and full MTR traces as separate correlated events

Physical co-location is not required for logical correlation. The sweep host
observation carries a small MTR outcome and stable `trace_id`; the complete
trace is a separate typed event.

### Sweep observation shape

```proto
message SweepTestV1 {
  SweepMode mode = 1;                 // e.g. TCP_SYN or TCP_CONNECT
  TransportProtocol protocol = 2;
  uint32 port = 3;
}

message SweepObservationBatchV1 {
  string execution_id = 1;
  string sweep_group_id = 2;
  uint32 execution_shard = 3;
  uint64 assignment_epoch = 4;
  uint64 batch_sequence = 5;
  int64 observed_at_unix_nano = 6;
  string execution_plan_id = 7;
  bytes execution_plan_sha256 = 8;
  string target_range_id = 9;
  bytes target_range_sha256 = 10;
  repeated SweepTestV1 tested_checks = 11; // exact set shared by every host
  uint32 configured_mode_bits = 12;
  string availability_policy_id = 13;
  SweepExecutionSource source = 14;
  string source_run_id = 15;           // e.g. ad-hoc scan_run_id
  repeated SweepHostObservationV1 hosts = 16;
}

message SweepHostObservationV1 {
  bytes address = 1;                  // exactly 4 or 16 bytes
  string hostname = 2;
  sint64 observed_at_delta_nano = 3;  // probe completion vs batch timestamp
  sint64 first_seen_delta_nano = 4;
  sint64 last_seen_delta_nano = 5;
  uint32 result_mode_bits = 6;        // terminal modes carried by this fragment
  uint32 mode_revision = 7;           // compared separately for each named mode
  optional SweepIcmpSummaryV1 icmp = 8;
  optional SweepTcpSummaryV1 tcp = 9;
  repeated SweepOpenPortV1 open_ports = 10;
  repeated SweepPortErrorV1 port_errors = 11;
  optional SweepMtrSummaryV1 mtr = 12;
}

message SweepOpenPortV1 {
  uint32 tested_check_index = 1;
  optional uint64 response_time_nano = 2;
  string service = 3;
}

message SweepMtrSummaryV1 {
  string trace_id = 1;
  MtrOutcome outcome = 2;
  bool target_reached = 3;
  optional uint64 final_rtt_micro = 4;
  optional double packet_loss_pct = 5;
  uint32 total_hops = 6;
  string error_code = 7;
}
```

`tested_checks` plus the open-port list avoids repeating a closed result object
for every host/check pair while preserving TCP SYN versus TCP connect semantics.
Every host in one batch MUST have the exact same attempted check set; profile or
host overrides create a separate builder. The TCP summary, explicit error
entries, and `result_mode_bits` distinguish all-closed, skipped, incomplete, and
failed scanning. Batch-level modes and timestamps avoid repeated strings and
large absolute values. Plan/range IDs and digests replace repeated enumeration
of target scopes. Exact validation bounds are part of the schema task.

A host observation is a mergeable terminal-mode fragment, not a promise that
all configured modes finished simultaneously. ICMP/TCP may be emitted as soon
as they finish. A slower sweep-profile MTR run may later emit a fragment carrying
its small summary and trace ID. `mode_revision` is compared independently for
each mode named by `result_mode_bits`; a newer MTR fragment never suppresses an
unseen older ICMP/TCP fragment. Reusing the same network-scope/agent/execution/shard/
assignment/host/mode/revision key with different content is poison.

There is no fragment-global `available` boolean. Each mode carries an explicit
success/failure/skipped/not-admitted/timed-out/unknown outcome. After merging
the latest revision of every reported mode, the projector derives per-agent and
aggregate availability with the execution plan's versioned availability policy.
Unknown or unfinished modes never become false by omission; for an any-success
policy, a late MTR failure cannot overwrite an earlier ICMP success.

The scheduler persists an immutable `SweepExecutionPlan` header plus bounded
content-addressed range pages containing shards/ranges, expected target counts/
digests, configured modes/check sets, availability policy, and MTR admission
budget. CIDR/range inputs remain compact; arbitrary target lists use immutable
bounded pages and a plan root, never one database value, config blob, or command
containing every target. Page fetch, validation, caching, and assignment are
byte/count bounded. Assignment attempts are not part of that immutable plan: the
scheduler appends separate authoritative attempt records with agent, page/range,
epoch, lease/fence generation, remaining coverage, and state. This permits
retries that did not exist when the plan was created.

Each assignment attempt has exactly one sweep-data batch sequence space,
starting at one and allocated contiguously when batches become durable even when
multiple mode builders flush concurrently. Empty sequence numbers are forbidden.
The terminal evidence closes `[1, terminal_batch_sequence]` (or the empty
interval when it is zero), and persistence must prove every slot in that interval
has one non-conflicting binding. Compact range sets may represent the proof, but
`{1,3}` can never satisfy a terminal value of `3`. MTR trace batches use their own
identity/binding reconciliation and do not consume sweep batch slots.

MTR completion uses a versioned, bounded, order-independent-to-arrival proof over
deterministic plan order, not a hash of publication order. The immutable plan
assigns every MTR-eligible target a canonical ordinal inside bounded range blocks.
For each ordinal, the leaf encodes the expected binding tuple plus one explicit
terminal disposition (`trace_id` allocated, not-admitted, probe-failed,
quarantined, or scheduler-lost). Builders compute canonical per-block Merkle roots
in ordinal order while holding only the bounded active block; assignment terminal
evidence composes those block roots in plan/range order. Parent reconciliation
combines stable range roots, counts, and projected trace bindings without sorting
or materializing a million IDs. Digest version, leaf encoding, empty-root rule,
and composition have cross-language golden fixtures.

The agent emits `SweepExecutionEventV1` start/progress evidence and, when it can,
one stable completed/aborted terminal evidence event per attempt. Those events
carry plan identity, assignment epoch, terminal batch sequence, cumulative
counts, scanner/banner summary, and expected/emitted MTR-summary and trace
counts/digests. If the agent disappears or cannot durably write its terminal,
the scheduler fences the attempt and atomically records an authoritative
`expired`, `superseded`, `lost`, or `aborted` terminal state before assigning
remaining coverage. Overall execution state is reconciled from the immutable
plan, append-only authoritative attempt records, and agent evidence; no
distributed agent authors a global completion record.

### MTR trace shape

`MtrTraceBatchV1` contains bounded `MtrTraceEventV1` records with:

- stable RFC 9562 UUIDv7 `trace_id` and event ID;
- source (`scheduled_check`, `sweep`, `ad_hoc`, or `on_demand`);
- optional sweep execution/host correlation, check ID, command ID, and device
  hint, including `scan_run_id` for ad-hoc runs;
- one Unix-nanosecond observation timestamp;
- explicit attempted/outcome/error state;
- target, resolved address, protocol, IP version, packet size, and reachability;
- bounded hops with ECMP addresses, MPLS labels, sent/received, loss, optional
  RTT/jitter values, and a nonnegative 32-bit ASN represented safely on wire and
  as `BIGINT` in PostgreSQL.

Every trace in one `MtrTraceBatchV1` MUST share the frame's authenticated
network scope, agent, source class, authorization kind/context, and, when applicable, sweep
execution/shard/epoch/range. Sweep, scheduled-check, ad-hoc, and on-demand
contexts are never mixed in one frame. The outer capability covers the complete
batch and the consumer verifies every decoded record against it before any side
effect; a mixed-context batch is poison. Builders flush when any context changes,
even if the byte target has not been reached.

Timing fields whose absence differs from a measured zero MUST use proto presence.
Routing identity is not embedded as authoritative data; it comes from
gateway-attested headers.

The wire preserves Unix nanoseconds, including signed host deltas, while CNPG
`timestamptz` stores microseconds. Before hashing, identity comparison, ordering,
or persistence, every implementation canonically truncates nanoseconds toward
negative infinity to the containing PostgreSQL microsecond and separately stores
the original signed `observed_at_unix_nano` wherever sub-microsecond fidelity is
part of the domain/audit contract. Negative delta arithmetic is checked for
overflow. Golden fixtures cover the +/-999 ns boundaries so Go, Elixir, and SQL
cannot disagree about replay or ordering.

For every MTR producer, the producer allocates and durably records an RFC 9562
UUIDv7 `trace_id` before starting the probe. Its timestamp is the immutable
`trace_identity_time` and MUST fall within the signed collection interval plus
the configured attested-clock tolerance. The same ID survives encode, spool,
transport, and delivery retries, and a sweep/ad-hoc summary and trace event use it
verbatim. A restarted probe attempt receives a new attempt/event ID but remains
correlated to the same execution target; it MUST NOT overwrite a different
completed trace under the old ID.

The existing `MtrTraceResult` and `MetricBatch` shapes may be used as migration
inputs, but they are not the canonical v1 trace contract until timestamp,
presence, ASN, correlation, and failure-outcome defects are corrected.

## Decision 4: Treat each execution as a continuous bounded stream

The scanner result lifecycle is changed from whole-run snapshot delivery:

1. Reference the immutable scheduler plan plus append-only assignment attempt and
   emit start evidence for the attempt; processing does not depend on that event
   arriving first.
2. Process targets in bounded windows (initial range 4,000-16,000 hosts,
   benchmark tuned).
3. Retain a host only until the modes in its current execution phase reach a
   terminal outcome; do not retain completed ICMP/TCP state while waiting for a
   slower MTR phase.
4. Feed completed hosts into execution-shard batch builders while later target
   windows are still scanning.
5. Flush a builder when `proto.Size` approaches 256 KiB or a short flush timer
   expires; never exceed 512 KiB, the item guard, or the projected database-row
   budget.
6. Append the encoded domain batch and frame metadata to an fsynced segmented
   spool before it becomes eligible for transmission.
7. Release completed host/port state after the frame is durably spooled.
8. Emit bounded progress/watermark events at configured count/time thresholds,
   not once per host or delivery retry.
9. Emit one stable completed or aborted terminal evidence event after the
   shard/range has closed, including terminal batch sequence, cumulative counts,
   and expected/emitted MTR trace reconciliation data. If that is impossible,
   scheduler lease/fence recovery terminalizes the attempt as lost/superseded and
   preserves missing coverage for retry.

The data plane is continuously pipelined: scanning, encoding, spooling, gRPC
transmission, JetStream persistence, consumption, and database projection may
all be active for the same execution at once. Each data batch is useful without
agent start or terminal evidence. That evidence and authoritative assignment
state control execution status; the immutable scheduler plan defines expected
work. None is a prerequisite for processing or querying already durable
observations.

The same rule applies at every MTR producer. Scheduled checks, sweep-profile,
ad-hoc, and on-demand runners use bounded probe concurrency and feed each
completed trace directly into the byte/row/write-cost/timer builder and fsynced
MTR lane. They release the trace/hop object after append and never accumulate a
run- or interval-wide slice of completed traces before encoding. MTR producer RSS
is therefore bounded by active probes plus one builder/spool window, not due
trace count.

The long-lived bidirectional gRPC lane is only a multiplexed carrier. It may
remain open across many executions, and frames from different executions may be
interleaved by the fairness scheduler. RPC EOF, reconnect, or half-close never
means that a sweep completed; only authoritative attempt terminal state plus
plan/range reconciliation can establish completion. Conversely, finishing one
execution does not require closing or draining the connection before another
can make progress.

For a genuinely perpetual producer, the same framing rule uses bounded
time/config-generation epochs and durable watermarks instead of pretending the
entire lifetime is one execution. Consumers process each record independently,
advance event-time/sequence watermarks, and rotate epochs without waiting for
transport EOF. This proposal applies that general rule to finite sweep attempts;
adding another continuous observation type still requires its own typed payload,
row-cost, retention, and admission contract.

For well-formed events with non-conflicting stable identities, correctness does
not depend on broker arrival order, including within an execution shard. Stable
`(network_scope_id, execution_id, execution_shard, assignment_epoch, batch_sequence)` and
event IDs permit safe interleaving, retry, reassignment, and late arrival.
Partition affinity improves ownership and cache locality only. Consumers track
compact committed ranges/watermarks per assignment attempt; start or terminal
evidence may arrive first and trigger reconciliation again when missing data
commits. A producer that assigns two different payloads to one immutable identity
has violated the protocol and follows the explicit conflict rule below.

Initial secondary guards are 2,000 sweep hosts per batch and 128 MTR traces per
batch. Initial hard projected-row budgets are 10,000 sweep projection rows and
5,000 MTR trace/hop/path-variant rows per message. Encoded bytes, projected rows,
or projected write bytes always win over item count. The versioned cost contract is a conservative
worst-case count of every synchronous row mutation and of decoded resident/SQL-
parameter/index/WAL bytes, not merely encoded payload length. It includes ledger
and batch-slot/trace-identity bindings, host/check/error,
history/current state, OCSF, execution evidence, MTR correlation, trace/hop/path
variants, graph/reconcile outbox, and low-cardinality projection rows, plus fixed
per-message overhead. The producer cannot subtract likely conflicts or no-ops.
The consumer independently recomputes and verifies both upper bounds before
writing, and a schema version cannot ship without golden fixtures enumerating
every projector it can invoke. A single host or trace cannot
exceed the hard byte/row limit because check, hop, ECMP, label, hostname, and
metadata counts/lengths are bounded at collection time. An unexpected oversize
record is quarantined and reported rather than retried forever.

Each lane's spool is byte-bounded using the larger of two maximum planned outputs
or the configured production rate times the supported gateway/NATS outage, with
at least 25 percent headroom. Those lane limits are subordinate to one atomic
filesystem allocator covering every lane, raw quarantine, both recovery-journal
copies, rollover copy amplification, directory/segment metadata, and one-segment
scratch. The allocator enforces a hard minimum-free-space floor reserved for
recovery/control and terminal evidence; the sum of nominal lane quotas can never
overcommit the filesystem. When a lane or the global allocator reaches its
high-water mark, the scheduler defers lower-priority or overlapping work and
alerts. It never overwrites unacknowledged records or consumes the reserved floor
for ordinary data.

Admission reserves a conservative worst-case output budget for every new target
window and keeps separate emergency capacity for terminal/aborted metadata and
quarantine bookkeeping. Active aggregation is capped by bytes as well as host
count. No new window starts unless its reservation fits. High/low watermarks add
hysteresis; a hard watermark stops new probes and either resumes before the
execution deadline or emits an aborted terminal event from reserved capacity.

Spool records are length-delimited and checksummed, segment creation/rename and
directory metadata are fsynced, ownership/mode are private to the agent, and the
persistent sequence high-water is never reused. Startup truncates only an
uncommitted torn tail and quarantines corrupt committed segments without
silently skipping them. `ENOSPC`, `EIO`, fsync failure, or corrupt metadata
stops scan admission immediately, preserves the bounded current window for
retry when possible, marks the execution delivery-failed/paused, and alerts. A
host result is never released or reported durable until its append and metadata
are durable; if the process dies first, the scheduler retries the unfinished
target range under normal assignment fencing.

A corrupt committed record in the middle of a lane is not silently skipped and
does not permanently pin every later valid record. Using separately reserved
recovery metadata/capacity, the agent durably fences the old lane from normal
publication, creates a new spool identity, and records a crash-resumable rollover
journal. Normal spool admission permanently reserves at least one maximum segment
plus recovery metadata as rollover scratch. The agent copies one readable old
segment at a time to the new lane with the same semantic event ID/body/checksum,
fsyncs the new segment and copy watermark, and only then advances the journal.
After the tombstone pages have PubAcked, that exact old source segment may be
deleted before copying the next, so recovery needs bounded scratch rather than a
second full-spool allocation. Copying to a new spool ID/sequence is a
delivery-coordinate change; database semantic idempotency absorbs any original
publication whose PubAck or edge ACK was lost.

The agent also submits a signed, hard-size-bounded `SpoolLossTombstoneV1` on an
independent recovery-control lane. It names the abandoned spool, compact
lost/uncertain sequence intervals, bounded affected attempt/range summaries, a
cryptographic segment/quarantine manifest root, and reason. It never enumerates
millions of later recoverable records; those records are evidenced by their
fsynced copy and are simply re-enqueued. If loss metadata itself cannot fit one
record, pages share a stable `recovery_id`, page count, ordered page digest chain,
and terminal manifest; the terminal page records copy completion or a bounded
failed/uncertain remainder. Both page size and total page count/manifest bytes are
hard bounded; when interval detail would exceed them, the producer coarsens to
one conservative uncertain sequence/attempt scope. Admission reserves the entire
manifest, all pages share an assembly deadline inside the recovery retention
window, and the agent retries them until the durable page store records terminal
completion. Each page obeys the normal frame limit. The recovery consumer durably
stores pages idempotently and applies partialization/fencing/retry exactly once
only after the complete manifest validates; an early page cannot expire while a
later required page remains admissible.

The scheduler issues a spool-recovery capability bound to network scope, agent,
abandoned spool/range, affected attempts, recovery ID, and expiry; the
authenticated agent signs each page and the gateway verifies identity,
capability, and chain. The gateway publishes pages to the deployment recovery
stream with stable IDs derived from network scope, agent, recovery ID, page
index, lost scope, and manifest digest. An old segment is physically deleted
only after its readable events and mapping watermark are fsynced in the new lane
and the required loss-manifest pages have PubAcked; full old-lane retirement also
requires the terminal copy-completion page. The journal distinguishes publication
fencing, per-segment copy, recovery publication, and physical deletion, and
startup resumes any phase idempotently. A dedicated recovery consumer atomically
stores the loss audit, marks affected attempts/ranges partial or lost, fences
unsafe authority, and enqueues remaining coverage for scheduler retry before
ACKing the completed recovery state. Recovery state and lag are operator-visible
and retained beyond the recovery stream's replay window. This is explicit
acknowledged data-loss handling, not a success disposition for the missing
result.

Recovery identity is immutable independently of broker deduplication. A binding
keyed by `(network_scope_id, agent_id, recovery_id)` fixes abandoned spool,
manifest root/page count, and conservative loss scope; each `(recovery_id,
page_index)` fixes one page digest. A later conflict is quarantined as integrity
failure and cannot apply a second partialization/fence/retry transition.

Recovery-stream PubAck only stops publication retry; it does not allow the agent
to garbage-collect its recovery journal. After the consumer transaction commits,
the scheduler returns a signed `RecoveryResolvedV1` over the control stream (or
an idempotent control query) bound to recovery ID, manifest root, and applied
state. The agent retains both journal copies and page proof until that resolution
is durable locally. A lost resolution is queried/replayed safely.

Admission, probe execution, and send scheduling use weighted fairness across
site/network scope, agent, execution, and traffic class. Each agent reserves an
unborrowable interactive floor for probe workers, sockets/file descriptors, ICMP
tokens, DNS concurrency, CPU, spool bytes, and sender credits; bulk work cannot
occupy it before an interactive assignment arrives. Interactive/on-demand work
remains hard-bounded and cannot bypass durability or starve scheduled work. MTR
has an independent byte/probe budget from reachability summaries. These policies
avoid head-of-line blocking when a million-target scan shares an agent or gateway
with small jobs.

## Decision 5: Make the gateway an authenticated pass-through publisher

For every frame the gateway:

1. Authenticates the installation trust domain and agent through the canonical
   edge mTLS identity resolver (deployment CA and certificate subject/CN; a
   SPIFFE URI SAN is optional compatibility metadata, not a requirement).
2. Enforces payload kind, schema, authorization kind/context, range ID/digest,
   string, byte, checksum, and in-flight bounds.
3. Locally verifies the scheduler-signed collection or delivery capability for
   the declared context. A sweep/ad-hoc assignment covers network scope, agent,
   execution, shard/range, epoch, traffic class, config generation, and collection lease; a
   scheduled check or command capability covers its corresponding check/command
   identity and bounds. Revocation/fence generations are distributed over the
   control/config plane; no per-frame core/DB/ERTS lookup is allowed. The
   consumer rechecks decoded context, every target's plan/range membership, and
   authoritative fencing before side effects. The highest agent-claimed epoch
   is never treated as authority.
4. Computes the logical partition. Sweep hashes trusted network scope plus
   execution and shard (not assignment epoch). Opaque MTR batches hash trusted
   network scope, authenticated agent, and stable semantic event ID; no trace-key decode or
   per-trace ordering is required, and spool rollover preserves the partition.
   Agent-provided routing cannot cross an identity boundary.
5. Selects the subject, stream-map version, and expected physical stream.
6. Writes the complete canonical broker-header envelope described below.
7. Computes the immutable semantic-envelope digest defined below, includes it in
   `Nats-Msg-Id` with trusted network-scope/agent and spool ID/sequence, and sets
   `Nats-Expected-Stream` to the selected stream.
8. Publishes with a JetStream request and waits for PubAck.
9. Returns accepted/rejected dispositions and advances only the contiguous
   resolved spool prefix after the required primary-stream or audit-DLQ PubAck.

The JetStream body is the exact encoded inner protobuf. The following bounded
headers are part of the persisted broker contract, not optional telemetry:

```text
Sr-Network-Scope-Id        Sr-Agent-Id              Sr-Gateway-Id
Sr-Spool-Id                Sr-Spool-Sequence        Sr-Event-Id
Sr-Payload-Kind            Sr-Schema-Version        Sr-Compression
Sr-Encoded-Size            Sr-Uncompressed-Size     Sr-Payload-Sha256
Sr-Projected-Row-Count     Sr-Projected-Write-Bytes Sr-Cost-Model-Version
Sr-Execution-Id            Sr-Execution-Shard
Sr-Assignment-Epoch        Sr-Authorization-Kind    Sr-Authorization-Context
Sr-Target-Range-Id         Sr-Target-Range-Sha256   Sr-Collection-Capability
Sr-Collection-Capability-Sha256  Sr-Delivery-Capability-Sha256
Sr-Traffic-Class           Sr-Identity-Epoch         Sr-Metadata-Bucket
Sr-Partition               Sr-Gateway-Received-At
Sr-Stream-Map-Version      Sr-Semantic-Envelope-Sha256
Sr-Envelope-Sha256
```

`Sr-Collection-Capability` carries the bounded canonical signed capability bytes
(encoded safely for a NATS header), not merely a digest. Its digest is bound into
the semantic envelope. Consumers independently verify the signature/key ID and
can therefore validate collection interval, range, and fence after gateway
restart without a volatile lookup. Missing or unverifiable proof is fail-closed.

`Sr-Identity-Epoch` is derived from trusted scheduler/collection authority, never
an agent-selected placement hint. `Sr-Metadata-Bucket` is derived from the
validated UUIDv7 semantic event ID and its configured replay-horizon policy; it
must agree with the signed collection/execution interval. The identity epoch
routes sweep history to the one partition that can own its logical observation;
the metadata bucket routes ledger/slot rows to a whole-partition retirement
bucket after the accepted replay horizon. Consumers recompute and verify both.

`Sr-Semantic-Envelope-Sha256` is the domain/ledger digest. It binds the exact
body plus trusted network-scope/agent, event ID, kind/schema, compression/sizes/checksum/
cost-model version/worst-case row and write-byte costs, traffic class,
execution/shard/epoch, identity epoch, metadata bucket,
authorization kind/context/range, and
original collection-capability digest. It deliberately excludes delivery
coordinates (`spool_id`, sequence, logical/physical partition), gateway identity/
receipt, stream-map placement, and renewable delivery proof, so crash-safe lane
rollover cannot turn a previously committed semantic event into poison.

`Nats-Msg-Id` is a publication identity derived from trusted network-scope/agent,
`spool_id`, sequence, and semantic digest. It is stable for every retry in one
lane and intentionally changes when recovery copies the same event to a new
lane. Broker deduplication therefore handles lost ACKs within a lane, while the
database ledger handles semantic replay across lanes and after the broker
duplicate window.

`Sr-Envelope-Sha256` additionally binds every delivery/placement header,
including spool ID/sequence, logical partition, gateway receipt, map version,
and delivery proof, for exact persisted-envelope integrity. The consumer verifies both, then decodes
the declared kind/version and verifies decoded execution/assignment fields
match. Before applying anything, it validates each decoded target/check against
the authoritative plan/range and validates that every MTR record shares the
attested authorization context. The ingest ledger stores and compares the
semantic digest as well as payload checksum, catching conflicts outside the
broker duplicate window. This preserves opaque forwarding at the gateway without
treating the opaque body as authorized merely because its envelope was valid.
Headers supplied by the agent are discarded; every `Sr-*` value is constructed
or validated by the gateway.

Publishing may pipeline 32-64 asynchronous PubAcks. Every class uses a separate
NATS publisher connection/pool with its own pending-byte ceiling, so bulk client
buffering cannot consume the interactive or recovery path. Admission is bounded
by frame count, encoded bytes, and measured retained gateway memory including
outer decode terms, pinned binaries, capability/header encoding, NATS request
state, mailboxes, and TLS buffers, not a raw-payload estimate alone. Initial raw
payload limits may be 16-32 MiB only when the measured resident-memory bound and
gateway hard limit contain their worst-case amplification. Lost edge ACK after a successful PubAck is
safe: a retry in the same lane uses the same broker publication ID even if
delivery authority or physical placement changed. Recovery under new spool
coordinates uses a new publication ID but the same semantic digest. Reusing a
semantic event ID with different bytes or semantic headers produces a different
semantic digest/publication ID so the consumer ledger can reject the conflict
instead of JetStream hiding it as a duplicate. Database idempotency remains the
correctness backstop after the broker duplicate window expires.

The current generic `Gnat.pub` wrapper is insufficient for this path because it
only confirms handoff to the client connection. A shared project-owned
JetStream publisher must parse and validate PubAck responses.

The gateway does not enqueue this lane into `StatusBuffer`. NATS unavailability,
stream capacity refusal, or publisher saturation stops ACK progress and lets
gRPC plus the agent spool apply backpressure.

The PubAck must come from the configured authoritative durability stream. A
Core NATS handoff through a leaf connection, a local non-authoritative mirror,
or an ERTS send is not sufficient. A deployment MAY designate an edge-local
JetStream as authoritative only when its replication and site-loss RPO are
explicitly configured and surfaced; otherwise the acknowledgement must reflect
acceptance by the hub durability domain.

## Decision 6: Use dedicated, partitioned JetStream streams

The runtime has one installation NATS authority with least-privilege component
credentials and fixed signal contracts. It does not prefix subjects or allocate
accounts, streams, durables, processes, or database schemas per SaaS customer;
the SaaS control plane provides customer isolation by provisioning separate
clusters. Legacy customer-prefixed runtime subjects/imports/mirrors and
`default`-customer inference are sealed and drained under an explicit migration
watermark, never extended by this data plane.

Initial subjects are installation-local and fixed:

```text
telemetry.sweep.v1.bulk.pNN
telemetry.sweep.v1.interactive.pNN
telemetry.mtr.v1.bulk.pNN
telemetry.mtr.v1.interactive.pNN
telemetry.result-recovery.v1
telemetry.result-dlq.v1.bulk.pNN
telemetry.result-dlq.v1.interactive.pNN
```

The scheduler attests the disjoint traffic class; no message matches both.
Traffic class is immutable for an assignment attempt and is bound by its signed
collection capability, semantic envelope, subject, and stream-map entry. Gateway
validation requires all four to agree. Replay, rollover, and DLQ redrive preserve
the original class; they cannot promote bulk data into the interactive reserve.

V1 uses 64 logical partitions (`p00` through `p63`) with a versioned hash. The
benchmark may raise the count before rollout, but it cannot change after data is
published without a new subject/hash version. Large executions are sharded by
the scheduler so no one agent/shard depends on cross-partition ordering. All
sweep data and execution events for one shard, including replacement assignment
epochs, use the same partition for locality. Each context-homogeneous opaque MTR
batch is partitioned from trusted network scope, authenticated agent, and stable
semantic event ID, so
recovery-lane coordinate changes do not move it; one batch is the broker unit
while consecutive batches may distribute. MTR correlation is
eventual; its stream does not participate in sweep-shard ordering, and consumers
require no per-trace arrival order.

A logical subject partition is routing and locality metadata, not an exclusive
application-worker ownership key and not automatically a
JetStream storage shard. Each physical stream has its own replicated state and
write leader. Provisioning therefore maintains an explicit mapping from every
logical partition to exactly one authoritative physical stream. A small
installation maps all partitions for each `(payload kind, traffic class)` to its
own physical stream; bulk and interactive never share a stream or persistence
durable. Larger installations spread disjoint partition subject sets across more
physical streams/RAFT groups. The versioned map key
is `(traffic class, payload kind, logical partition)`, and gateways and consumers receive the
same configuration.
The gateway persists its map version and uses the selected physical name for
`Nats-Expected-Stream`; overlapping or missing subject authority fails
readiness. A map-version change uses a distributed publish barrier: stop affected
admission, revoke or wait out every old-generation gateway lease, seal/remove the old stream's writable
subject authority and ACL, then activate exactly one new authority. The old
consumer remains alive after sealing to drain all accepted messages through the
final AckWait/redelivery horizon and a repair scan. A stale gateway therefore
gets no authoritative PubAck and cannot strand an
edge-acknowledged message after a drain snapshot. Publishing may resume on the
new authority while the sealed old stream drains. Increasing the logical
partition count alone is not a broker-write scaling mechanism.

Every immutable stream-map version, subject authority, publisher fence, and
consumer configuration is persisted through the old stream's empty/repair,
AckWait/redelivery, and rollback watermark. An old consumer can restart from
that history after a newer map activates; latest-config-only reconstruction is
not allowed.

Sweep/MTR bulk and interactive classes use disjoint file-backed physical streams
and pull durables inside the installation's NATS authority. Gateway credentials can
publish only the fixed result subjects and read PubAcks, never subscribe to
results. This proposal creates no cross-cluster result aggregation path.

The low-volume recovery subject uses a separately capacity-reserved file-backed
stream and one idempotent scheduler-repair durable per installation. It is not
the poison DLQ: its consumer has a required state transition and
ACKs only after the loss audit plus attempt/range partialization/retry intent
commit. Its retention, lag paging, and `DiscardNew` headroom cover the supported
outage/catch-up window so a recovery claim cannot expire silently.

Result DLQ partitions map deterministically from the source data partition and
retain the attested original traffic class; a gateway rejection that has no valid
source partition hashes authenticated agent/spool coordinates and uses the class
from its verified capability. Bulk and interactive use disjoint physical streams
and consumers, never a shared-stream substitute and never the recovery-control
reserve. DLQ `MaxAge` is disabled: unresolved raw
records are removed only by audited state-aware deletion. `MaxBytes`, replicas,
and PubAck throughput cover the full admitted source rate for the configured poison
detection/pull-pause interval plus bounded in-flight/retry overlap. Per-shard and
aggregate poison-rate/ratio circuit breakers pause the affected source pulls and
new gateway acceptance and page immediately when a decoder/schema regression can
turn ordinary fleet traffic into poison. The system does not continue draining a
systemic failure into the DLQ until it fills; individual source messages remain
unresolved whenever the mapped DLQ cannot PubAck.

After admission pauses, DLQ capacity retains that bounded poison cohort through
the supported incident-diagnosis, rollback, redrive, and audit-resolution window.
No raw record expires merely because diagnosis takes longer than detection.
Bulk poison cannot consume the interactive DLQ floor or prevent an interactive
rejection from reaching a durable disposition. Circuit accounting, catalog
state, and redrive preserve original class. Final deletion requires an explicit
resolved/redriven/waived state and advances
the semantic-ledger safe-GC watermark; otherwise operators must extend capacity
or the path remains not ready.

A bounded DLQ indexer populates an idempotent `result_dlq_record` catalog keyed by
stable DLQ ID and physical stream/sequence. The catalog records immutable source
provenance, error cohort, redrive attempts/outcomes, waiver, audit actor/time, and
final state. An authorized deleter removes only stream sequences whose catalog
entry is durably resolved/redriven/waived and whose dependent ledger watermark is
safe. Gateway publication remains stateless; unknown/unindexed sequences are
never guessed or purged.

Production streams use three replicas where the deployment supports them, a
hard maximum message size of 512 KiB plus headers, `LimitsPolicy`, and
`DiscardNew`. Refusing new data propagates backpressure; silently evicting
unconsumed sweep results is not an accepted overload policy.

Capacity is calculated per installation and physical stream shard from an admitted
arrival envelope:

```text
catch_up_seconds = outage_bytes / (drain_bytes_per_second - live_bytes_per_second)
retention_horizon >= supported_outage + catch_up_seconds + safety_margin
max_bytes >= 1.25 * (
  max_admitted_bytes_in_any(retention_horizon)
  + maximum_spool_replay_overlap_bytes
  + measured_jetstream_record_overhead_bytes
)
```

`max_admitted_bytes_in_any(T)` includes synchronized scheduled bursts across all
sites/agents/executions sharing the physical stream, live traffic during recovery, retry/replay
overlap, headers, and all configured producer classes. It is not peak burst rate
multiplied continuously and is not an average-rate estimate. With drain capacity
at twice live ingress, a 24-hour outage needs about another 24 hours to catch up,
plus safety margin; a 24-hour `MaxAge` is therefore invalid.

For one compact one-million-host hourly installation, 24 hours of arrivals is roughly
2-4 GB logical. A retention horizon covering outage plus catch-up initially puts
that installation in roughly the 8-16 GB logical sizing band after replay/record
overhead and headroom; three replicas consume roughly 24-48 GB physical before
other streams and filesystem reserve. Actual capacity is the sum of admitted
site/agent/execution envelopes. MTR capacity is
derived from an explicit trace budget, not an assumption that every sweep target
runs MTR.

Fleet enablement requires `MaxAge` and `MaxBytes` to preserve every edge-ACKed
event through the supported outage, worst-case catch-up, and margin. Approaching
the window pages operators and stops new admission before `DiscardNew`. An
outage beyond the declared window is an explicit durability-SLO breach: affected
executions remain partial and emit a critical data-loss-risk incident; the
system never silently claims complete ingestion. Stream lag, ack-pending,
redelivery, bytes, oldest age, PubAck latency/errors, and retention risk are
mandatory telemetry.

Every capacity, retention, catch-up, storage, and PubAck-throughput calculation
is evaluated per physical stream shard using the site/agent/partition envelope
assigned to it, including worst-case hash skew and a hot execution. Stream
leaders and replicas are explicitly placed across the intended nodes and
failure domains. The deployment gate also checks the aggregate of all shards.

Pull requests are byte-bounded. Initial processor settings are 8-16 messages or
about 4 MiB raw per pull and 32-64 max ack pending, then benchmark tuned. Every
persistence consumer uses JetStream `AckExplicit`; `AckAll` is forbidden because
replicas and workers may finish deliveries out of order. A worker sends an
individual ACK only after the database transaction containing that message has
committed. If a later message commits while an earlier worker crashes, the
earlier delivery remains unacknowledged and redelivers. V1
starts with one shared persistence durable per physical stream shard and schema
version, pulled by a bounded EventWriter replica pool. Any replica may receive
any `pNN`, including concurrent redelivery of the same key; correctness depends
on ledger locks, uniqueness, revision order, and assignment fences, never an
application-local exclusive owner or handoff. Additional independent downstream
projections get their own durable, but adding workers does not create one
durable, connection, or OS process per agent/execution/logical-partition tuple.
Consumer/stream RAFT-group and connection cardinality are hard deployment
limits. The persistence durable uses unlimited transient redelivery with bounded
backoff and pauses pulls during systemic database failure. It never silently
stops at a finite `MaxDeliver`; deterministic poison follows the DLQ path
instead.

A shared stream cannot select around backlog it has not yet delivered. Admission
therefore caps each site/agent/execution envelope and the installation-wide
backlog, oldest age, and interactive-job drain-delay SLO. A job that exceeds its
envelope is paused/deferred before publication. Bulk and interactive traffic use
mandatory disjoint physical streams/durables so the bounded interactive reserve
remains reachable during bulk catch-up. The stream map gives each message exactly
one durable ownership path; overlapping filtered durables are forbidden.

## Decision 7: Make persistence idempotent and bounded

Every JetStream message remains an independently decodable, costed, idempotent
unit, but persistence MAY combine multiple already validated messages into one
bounded adaptive database transaction. Interactive work flushes at its latency
bound and MAY commit one message. Sparse and bulk work groups across agents and
executions to amortize commit/WAL overhead, bounded by aggregate encoded and
resident bytes, projected write bytes, rows, message count, lock set, and a short
transaction deadline. It never crosses traffic-class or schema/projector
semantics, never becomes an execution-wide transaction, and every constituent
message retains its own delivery slot, ledger result, and post-commit explicit
ACK. A deterministic database conflict rolls the entire group back and triggers
bounded split/isolation; no constituent is ACKed until a valid subgroup commits.
Transaction admission is global to its CNPG destination. The installation-level database capacity plan
partitions measured Repo/WAL/lock headroom into explicit result-data-plane, sync,
control/API/Oban, and background/maintenance pools whose maxima sum to no more
than the hard destination limit. Ungoverned or database-internal work is charged
as unavailable reserve, never assumed absent.

Within the result pool, one fenced resident-byte/write-byte/row/active-transaction/commit-rate
controller bounds sweep/MTR source projection, graph outbox projection, execution
reconciliation, spool-loss recovery, DLQ indexing/redrive, result rollups, and
result repair. Fixed subpools preserve recovery/reconciliation and a small bounded interactive share;
bulk cannot borrow those minimums, and interactive cannot consume the bulk floor.
Work-conserving lending outside the floors is
allowed only while every result grant remains within its pool. V1 readiness
requires every in-scope writer generation to enroll. During rolling migration,
unconverted writers consume a static worst-case reservation that is released only
after they are fenced/drained. Per-consumer `max_ack_pending` is only a safety
ceiling.

Admission is two-stage. Before a pull, a worker reserves the maximum encoded/
resident body plus headers and worst-case projected row/write-byte costs for
every message it requests, plus one transaction-concurrency slot for every
aggregate transaction it may execute concurrently. One sequentially split/retried
group reuses its slot only after rollback is confirmed; a parallel subgroup must
acquire another slot. A separate destination commit-rate/fsync budget bounds how
quickly slots may turn over, so grouping cannot evade WAL pressure. The worker
never pulls more messages than those reservations cover. After trusted headers
and the decoded cost function validate, it returns the unused worst-case delta
and holds verified resident-byte, write-byte, row, active-transaction, and commit-
rate credits through its bounded queue, commit/failure, and delivery disposition.
A message waiting
legitimately under a reservation sends JetStream in-progress heartbeats no less
frequently than one third of `AckWait`, but only until a configured processing
deadline; at the deadline it NAKs/releases rather than renewing forever.

Distributed grants carry a monotonically fenced generation, expiry, and maximum
transaction deadline. Old grants remain charged until surrendered or expired;
scale-out/rebalance cannot reuse their capacity concurrently, and a worker does
not admit work unless its lease outlives the transaction deadline. If the
allocator is unavailable, no new pull is admitted. Crash reclamation waits for
expiry and confirmed database session cancellation/death; DB-side statement and
transaction timeouts never exceed the grant deadline. Immediately before commit,
the transaction rechecks the current grant generation/expiry and rolls back if
fenced. If cancellation/session death cannot be confirmed, the worst-case old
transaction remains charged. Static quotas are
acceptable only when their configured sum, including rolling overlap, is within
the same hard total. Fair suballocation prevents a hot site/agent/execution or
MTR lane from consuming every general credit, while the reserved
recovery/control pool remains available.

Within those credits, projection is:

1. Insert or lock both a delivery-slot binding keyed by trusted metadata bucket,
   network scope, agent, lane, spool ID, and sequence and an ingest-ledger row
   keyed by trusted metadata bucket, network scope, authenticated agent, payload
   kind, and semantic event ID. The slot binds one
   event ID/semantic digest; the ledger stores checksum, encoded/projected-write
   byte counts, cost-model version, immutable semantic-envelope digest,
   expected/projected record counts, and commit state (not the payload body).
2. If the same committed event/checksum/semantic digest exists, return success
   without applying side effects again. The same event ID with a different body
   or immutable semantic envelope is poison.
3. Bulk insert/upsert domain rows, current-state changes, immutable per-shard
   execution evidence, deterministic OCSF events, required low-cardinality
   projections, and any required derived-view outbox rows. Do not lock/update
   one parent execution-summary row per batch.
4. Mark the ledger entry committed with actual row counts.
5. Commit the bounded message group, then explicitly ACK each constituent
   JetStream delivery; never use cumulative `AckAll` semantics.

Before SQL, the projector canonical-sorts every overlapping identity/current-
state/summary key and acquires tables and rows in one documented global order.
Bulk `INSERT ... ON CONFLICT` input follows that same order. This prevents two
legal batches containing the same devices in reverse order from turning bounded
concurrency into a deadlock/retry storm.

Every address-derived identity starts with the authoritative `network_scope_id`.
Stable keys and fencing rules include:

- raw sweep host mode fragment: trusted scheduler identity time + network scope +
  agent + execution ID + execution shard + assignment epoch + canonical address
  + mode + mode revision;
- reconciled per-agent execution host: network scope + agent + execution ID + execution
  shard + canonical target, selecting the scheduler-authoritative assignment and
  latest revision independently per mode;
- MTR trace: UUIDv7-derived trace identity time + network scope + stable
  `trace_id`, with observation time and trace content immutably bound to that
  identity;
- MTR hop: network scope + trace key + hop number + path-variant identity;
- OCSF event: deterministic ID from network scope plus stable domain-record identity;
- delivery slot: metadata bucket + network scope + authenticated agent + lane + spool ID + sequence,
  immutably bound to event ID and semantic digest;
- ingress ledger: metadata bucket + network scope + authenticated agent + payload
  kind + event ID;
- sweep batch slot: network scope + execution ID + execution shard + assignment epoch
  + batch sequence, immutably bound to event ID, payload checksum, host/mode
  counts, and projected rows;
- agent terminal slot: network scope + execution ID + execution shard + assignment
  epoch, immutably bound to terminal kind, event ID, closed batch interval,
  counts, outcomes, and versioned MTR range roots.

Replaying an equal sweep batch-slot binding is harmless. If two different
bindings claim one slot, the first authenticated binding that commits remains
immutable forensic/domain state; a later conflicting claim is poison and never
overwrites or merges with it. The attempt is marked `integrity_failed`, cannot
reconcile complete, and its range is scheduled under a new fenced epoch to
repair authoritative current state/counts. No order-independence guarantee is
made between two mutually protocol-invalid values. The terminal sequence
reconciler reads only committed non-conflicting slots from authoritative
attempts.
Likewise, reusing one network-scope-scoped `trace_id` with a different observation time
or trace content is poison rather than a second historical trace.
Reusing one delivery slot for different semantics is also poison, even though
its changed broker publication ID reaches JetStream. Recovery may bind the same
semantic event to a new slot; the semantic ledger then deduplicates it normally.

The first authenticated agent-terminal binding is immutable. A conflicting
terminal or any data batch outside its closed interval makes the attempt
`integrity_failed`, excludes it from authoritative reconciliation, and triggers
fenced range repair regardless of whether data or terminal arrived first.
Scheduler-authored lost/expired/superseded state occupies a separate authoritative
assignment-state slot and never masquerades as agent evidence.

Sweep and MTR identity are partition-local by construction rather than duplicated
into a permanent non-hypertable row per observation. Raw sweep history uses an
immutable `identity_time` resolved from the scheduler-owned execution epoch; the
projector rejects any agent-supplied alternative. Its unique key includes
`identity_time`, network scope, agent, execution, shard, assignment epoch,
canonical address, mode, and mode revision. The row binds canonical observation
time and semantic digest, so every replay or conflicting binding for one logical
observation reaches the same partition. Long-lived/continuous work rotates
bounded scheduler epochs instead of keeping one identity partition open forever.

V1 MTR trace IDs are RFC 9562 UUIDv7 values allocated and durably recorded before
probing. `trace_identity_time` is derived exclusively from the UUIDv7 timestamp
and must fall inside the signed collection interval plus clock tolerance.
`mtr_traces` uniquely binds `(trace_identity_time, network_scope_id, trace_id)` to
authenticated source/context, canonical target, observation time, and semantic
digest; `mtr_hops` references that physical key. A summary that precedes its trace
may create a bounded partitioned expectation row, but the row is consumed or
reduced to terminal reconciliation state when the trace resolves. V1 does not
retain a permanent `sweep_observation_identity` or `mtr_trace_identity` side row
for every completed observation.

The scheduler issues a monotonically increasing `assignment_epoch` and signed
collection capability whenever a shard or target range moves to another agent.
The collection capability, not the scalar epoch, proves that the authenticated
agent was permitted to probe the bounded range until its lease/fence generation;
a delivery capability can only drain immutable bytes as defined above.
Reassignment fences the old epoch before the replacement owns its range.
Already durable late data from an older epoch remains auditable but cannot
change reconciled counts, current state, or terminal status after the fence.
The epoch is not part of the partition hash, so related data retains locality;
reconciliation still does not depend on arrival order.

Execution totals are reconciled from unique committed observations, the
immutable execution plan, and authoritative terminal state/evidence for every
assignment attempt. They are not blindly incremented on every delivery. Current
device state is updated only by a newer per-agent/mode observation. The
total-order key is
the bounded per-host probe-completion timestamp, configured source priority,
execution ID, authoritative assignment epoch, mode revision, and event ID;
arrival or batch-flush time is never used. Agent clocks outside the configured
original signed collection-capability interval (plus bounded tolerance and any
attested session clock offset) are quarantined rather than allowed to pin future
state. Gateway receipt time is delivery-latency metadata and a one-sided future
sanity check, never a symmetric age window: an old frame legitimately retained
through the supported spool/outage horizon remains valid when its observation
time fits its original collection authority. Equal domain keys with equal
content are replay; equal keys with different content are poison.

Derived events do not depend on which concurrent projector won first. Every
authoritative observation gets one deterministic immutable OCSF observation
event. Lifecycle transition events are produced separately by an event-time
reconciler that sorts authoritative observations by the same total order and
advances only through a closed execution/time-epoch watermark. Before closure,
state is explicitly provisional. Data older than a finalized watermark follows
a versioned correction/retraction policy with deterministic IDs; it cannot
silently create a different alert/event set based on broker arrival order. A
narrow raw observation history uses
time-partitioned retention; current state and execution summaries are retained
separately; longer-term UI/SRQL views use rollups.

Parent execution totals/state are refreshed from per-shard committed ranges by
a separately bounded, coalescing reconciler. Every evidence/terminal transaction
inserts an append-only reconcile-work event keyed by the source ledger event and
carrying the immutable traffic class; it never updates one `(network_scope,
execution)` dirty tuple. A fixed number of class-separated reconcile queue
partitions hash trusted network-scope/execution identity. Fenced expiring leases
give one worker at a time a bounded batch from a queue partition, and the
interactive queues retain an unborrowable claim/credit floor during maximum bulk
catch-up. The
worker groups many work events per execution, recomputes from authoritative
committed ranges/attempt state, and atomically stores the parent summary and
marks the claimed work processed. New evidence remains as later work. A bounded
anti-entropy scan recreates missing work from append-only evidence. This keeps
both the parent row and a substitute global dirty row off the per-message hot
path, collapses bursts into coalesced updates, and survives a crash after
evidence commit or during summary update.

Initial hard transaction caps match the 10,000 total sweep-projection-row and
5,000 MTR-row message budgets; normal builders target materially less. Both caps
are tuned downward with real CNPG/WAL/index measurements if needed. An
execution-wide transaction is explicitly forbidden.

Malformed or permanently incompatible consumer events are published, including
original bytes and error metadata, to the mapped DLQ partition whose message
limit safely exceeds the source message plus bounded diagnostics; its PubAck is
required before the source delivery is terminated. Consumer poison uses a stable
ID from network scope, source stream/sequence, source checksum, and error class. A
gateway rejection before primary publication instead uses trusted network-scope/agent,
spool ID/sequence, a safe full-frame fingerprint or semantic digest, and rejection
class. Both survive an ambiguous DLQ PubAck while the gateway stays stateless.
DLQ credentials, retention, access auditing, and encryption protect raw topology
data. Transient database errors NACK and retry without a finite delivery ceiling.

The bounded canonical DLQ wrapper preserves the exact immutable trusted source
headers, exact bounded collection capability bytes and digest, semantic digest, original source
stream/sequence, traffic class, and body checksum alongside raw body and error metadata. Gateway
rejections preserve the maximum safely validated subset plus a full-frame
fingerprint. Redrive re-verifies that provenance and generates only fresh
delivery/map headers; it never reconstructs authority from body bytes alone.

An event using a valid advertised newer schema for which the mapped consumer is
not ready is a deployment-readiness/systemic failure, not permanent poison:
pulls/admission pause. After a bad decoder/schema rollout is repaired, an
operator-authorized deployment-local redrive may republish retained raw bytes with
their original trusted semantic identity through the current stream map. Each
redrive has a durable synthetic `dlq-redrive` lane ID/sequence and an operator/
scheduler capability bound to the immutable DLQ record; those new delivery
coordinates create a new publication ID and delivery-slot binding even inside the
original broker duplicate window. Original spool/stream coordinates remain
provenance only. Redrive is rate/credit limited, fully audited, requires exact
error cohort selection, and relies on the ordinary semantic ledger for
idempotency; it cannot rewrite network scope, authorization, or content. Source TERM,
redrive, and final audited deletion are distinct states.

MTR persistence also maintains an expected binding for every trace referenced by
a sweep or ad-hoc summary: `(network scope, authenticated agent, source/authorization
context, execution+shard+epoch or check/command, canonical target/host,
trace_id)`. Summary-first and trace-first arrival use the same binding. A trace
becomes `projected` only when its immutable identity/content matches all expected
fields; reusing an existing network-scope trace ID for another target/context is
`integrity_failed`/quarantined and cannot satisfy a terminal trace digest.
Reachability projection may complete first, but the execution exposes MTR
`pending`, `projected`, `failed`, `missing`, or `quarantined` counts and is not
fully reconciled until its authoritative plan/attempt state and terminal
evidence's expected binding count/digest are satisfied, remaining coverage is
retried, or every missing trace has an explicit terminal disposition.

The source MTR transaction also inserts an idempotent graph-outbox row keyed by
`(network_scope_id, trace_id, graph_schema_version)` before the JetStream delivery is
ACKed. The outbox stores the bounded immutable graph-projection input (or a
content-addressed non-hypertable payload) transactionally; it is never only a
pointer to trace/hop chunks that retention may drop. Raw chunks may retire once
every unresolved projection input is independently durable, without pinning a
large Timescale chunk for one failed row. Each row preserves the immutable
traffic class.

Graph projection is a two-stage append-only fold rather than concurrent direct
updates from arbitrary trace workers. A bounded normalizer transaction expands a
trace outbox payload into deterministic vertex-observation and edge-observation
tasks, stores the expected task count/digest, and marks the parent `expanded` in
the same transaction. Every topology task is keyed by source trace plus stable
network-scope-safe topology identity and carries an immutable
`graph_owner_map_version`, `owner_shard = hash_version(topology_identity) mod K`,
source class, monotonic observation order, and all immutable projection input.
`K` and the hash function are immutable within one graph owner-map/schema version.
Endpoint vertex tasks commit before dependent edge tasks become eligible.

Exactly one fenced worker lease owns an `(owner_map_version, owner_shard)`
generation at a time.
Class-aware subqueues and an unborrowable interactive claim/credit floor prevent
bulk work from delaying interactive topology indefinitely. The worker claims a
bounded class-fair batch, coalesces all observations for the same vertex or edge
to the deterministic newest/aggregate value, performs set-oriented or
`UNWIND`-style AGE mutations, advances the relational watermark, and marks the
represented tasks projected in one PostgreSQL transaction. Thus thousands of
traces sharing a backbone hop or edge cause one coalesced owner update per fold
window rather than cross-worker lock contention. A parent becomes `projected`
only after its expected task digest/count is fully resolved. It never issues one
transaction/Cypher call per hop.

Graph failure rolls the owner transaction back and leaves its tasks pending with
observable attempts/error/age; it is never rescued as success, and replay of the
already-committed source event cannot bypass the existing outbox/tasks. A repair
audit finds committed traces missing an outbox, expanded parents missing tasks,
and parents whose task completion does not match their expected digest. Changing
`K` or the hash function requires a versioned stop-expand/fence/drain barrier:
normalization pauses, every old task resolves or is atomically migrated with its
payload/watermark under a new owner fence, old leases are revoked, and only then
does the new map accept tasks. Owner-map history remains through repair, prune,
and rollback horizons; old and new owners never mutate one topology identity
concurrently.

Graph identity is network-scope-safe and monotonic. HopNode identity starts with
network scope plus canonical address; an existing Device is reused only inside
that scope. `MTR_PATH` identity includes network scope, agent, protocol, ordered endpoint identities,
and path-variant dimension. RTT/loss/hostname/ASN/last-observed properties update
only when `(observed_at, trace_id)` is newer than the stored order; late older
traces remain historical and never move `last_observed_at` backward. Queries,
TTL pruning, and orphan cleanup are network-scope-scoped. A compact relational
`graph_edge_watermark` is uniquely keyed only by the same scope-safe edge
identity and stores its current owner-map version/shard/fence plus maximum applied
order and prune tombstone through the full source replay/DLQ-
redrive horizon. Advancing the prune tombstone and deleting the AGE edge occur in
one owner-fenced PostgreSQL transaction. An owner-map migration changes the
stored owner only under that row's old/new fence barrier. TTL deletion uses the
stored current owner as projection. TTL deletion of an
AGE edge therefore cannot let a delayed old
outbox recreate it; an already-expired observation is marked projected-expired
without recreating topology. Graph-outbox lag/backlog has a
budget and can pause new MTR admission before derived topology falls outside its
declared freshness window. Fleet enablement requires graph drain throughput
above admitted live MTR edge rate plus the catch-up margin, including contention
on common backbone edges; graph-specific lock/WAL cost, lag, and freshness are
measured independently from relational trace ingest.

Retention defaults and safe bounds come from these benchmarks, but the existing
operator-managed MTR retention setting remains authoritative within them.
Migrations/control-plane reconciliation own Timescale retention/compression DDL;
EventWriter only writes rows and telemetry and never creates or alters policies.

Correctness replay has a finite configured horizon; metadata is not an unbounded
shadow database. Ordinary delivery/terminal/batch slots, ingest ledgers,
expectations, and correlations are assigned a trusted retirement bucket derived
from the validated UUIDv7 event ID and checked against collection authority.
After agent-spool, JetStream/AckWait/redelivery,
repair, compatible rollback, and integrity-audit watermarks pass that bucket,
ordinary metadata is retired by whole partition detach/drop, not row-by-row GC.
Long-retained current state, execution summaries, rollups, or historical query
rows do not by themselves pin ordinary correctness metadata after their immutable
projection can no longer produce side effects.

Before ordinary metadata for an unresolved DLQ, recovery, rollback, graph repair,
or other exceptional item retires, the system atomically persists a bounded
`correctness_hold` containing semantic identity, first accepted checksum/digest,
original traffic class, source catalog locator, state, and domain-replay deadline.
It also retains the complete bounded input needed to finish the unresolved work,
either inline or through a checksummed content-addressed payload whose reference
and lifecycle are owned by the hold. Before dropping an ordinary partition, the
system atomically copies an inline graph/outbox/task payload into held storage or
pins its existing content-addressed payload; a digest-only hold is insufficient.
Redrive below the ordinary acceptance watermark requires that exact hold. After
the domain-replay deadline, resolution is audit/partial/recollection-only and
cannot rehydrate expired raw history or mutate current state. A hold is removed
only after final resolution and its audit horizon close; finite class-separated
DLQ/recovery/repair capacities and their admission circuits bound the hold set.

A non-held delivery below the durable acceptance watermark terminates as
`replay_horizon_expired` after one stable bounded audit record and cannot recreate
domain or correctness rows. The live-state invariant is ordinary metadata no
greater than admitted events inside the replay horizon plus holds no greater than
configured exceptional capacity. If watermark progress, partition retirement,
or hold capacity cannot maintain that invariant, the scheduler stops new scan
admission before the hard metadata row/index-byte/held-payload budget is exceeded.

Immutable execution plans/ranges, authoritative assignment/fence records,
capability signing metadata, and retired verification keys remain available for
every event still inside the accepted replay horizon or represented by a hold.
Pending graph/recovery work remains held rather than pinning an ordinary time
partition. Capacity planning specifies metadata bucket width, maximum live
partitions, row/index bytes, insert rate, partition-retirement rate, hold limit,
and a long-horizon sawtooth/plateau model; linear steady-state growth fails
readiness.

## Decision 8: Publish one canonical event, then derive low-cardinality views

The agent does not publish a second generic representation of every host, port,
or MTR hop. The canonical domain stream is subscribable by persistence,
anomaly/causal, and other real-time consumers.

The persistence projector may write required low-cardinality execution/scanner
metrics in the same transaction. A separate stateless normalizer may publish a
derived `MetricBatch` only if an existing consumer cannot read the domain event;
that publisher must be unique, idempotent, correlated to the source event, and
must not recreate per-host/per-hop duplication.

Legacy-format executions retain their existing sweep/MTR metric projection until
parity and consumer audits are complete. A v1 execution never emits that
duplicate representation; its required low-cardinality metrics are derived from
the canonical event. Canary comparison uses different executions/cohorts or a
non-writing shadow, never two authoritative writes for one execution. The
legacy projection is removed from the agent after parity.

## Decision 9: Defer artifact transport to a separate contract

Normal sweep batches and bounded MTR traces stay in JetStream. They are naturally
record-oriented and must be available to streaming consumers.

This v1 does not add an artifact-reference payload kind, upload path, or object
lifecycle. Packet captures, raw command archives, and other indivisible objects
require a separate proposal covering installation-bound create-only keys, resumable
idempotent upload, durability acknowledgement, manifest publication, orphan GC,
reference-aware deletion, authorization, and a pluggable object backend. An
oversize sweep/MTR record is rejected or quarantined; it is never silently
diverted into Object Store.

## Decision 10: Treat "zero-copy" as encode/decode minimization

Literal end-to-end zero-copy is impossible across the required process and
durability boundaries. The useful contract is:

- no full-run materialization or reassembly;
- one inner protobuf encode at the agent;
- gateway forwards the same large BEAM binary without semantic decode/re-encode;
- one domain decode per consumer;
- bounded bulk database construction;
- no JSON map tree and no duplicate per-host metric serialization.

Go `MarshalAppend`, buffer pools, compression, and custom allocators are later
optimizations gated by profiles. They must not complicate the correctness path
before allocation data shows a remaining bottleneck.

## Failure Semantics

| Failure | Required behavior |
|---|---|
| Agent crash | Replay the fsynced spool with original IDs/sequences; if terminal evidence never arrives, the scheduler terminalizes/fences the attempt and retries remaining coverage. |
| Gateway/link failure before PubAck | Do not ACK; reconnect and replay. |
| PubAck succeeds but edge ACK is lost | Replay same event ID; broker/DB deduplicate. |
| JetStream unavailable or full | Stop ACK progress; retain at agent and apply backpressure. |
| Agent spool high-water | Defer new/lower-priority scans and alert; never overwrite unacked data. |
| Agent spool `ENOSPC`/`EIO` | Stop new probes, preserve/recover the bounded window, expose delivery failure, and retry or abort the fenced range without claiming durability. |
| Corrupt committed spool sequence | PubAck a signed loss tombstone through the recovery lane, abandon the old spool, re-enqueue recoverable later events with stable semantic IDs, and mark lost coverage partial/retriable. |
| Collection capability expires with backlog | Stop new probes; obtain event/checksum-bound delivery-only authority or leave the frame unresolved, then apply scheduler fencing at projection. |
| Consumer or database failure | Pause pulls or NACK and retry forever with bounded backoff; never exhaust into silent termination. |
| AGE graph projection failure | Keep the atomically created outbox pending, retry idempotently, expose lag/error, and never treat a rescued exception as success. |
| Poison payload | PubAck original bytes to DLQ, then terminate source delivery. |
| Gateway rejects a bounded frame | PubAck safe audit metadata to the deployment DLQ, return a rejected disposition, and retain raw bytes in agent quarantine. |
| Gateway restart | Reconnect; the stateless gateway has no acknowledged-only buffer. |
| Missing execution batch/shard | Keep execution partial and expose missing ranges. |
| Missing correlated MTR trace | Keep the MTR substate pending/missing/failed and do not report full reconciliation. |
| Retention window exceeded | Declare a durability-SLO breach and affected executions partial; never hide expiry as success. |
| Core rollback with proto backlog | Forbidden until the backlog and agent spools are drained or compatible consumers remain. |

## Performance and Reliability Gates

The implementation does not fleet-enable until it proves:

- zero acknowledged-message loss through gateway/core restarts and a configured
  24-hour core/consumer outage followed by worst-case catch-up, including events
  that begin near the configured `MaxAge` boundary;
- zero duplicate domain/OCSF/MTR rows and exact execution counts under at least
  five forced redeliveries;
- detection and quarantine of a semantic event ID reused with changed bytes
  inside and outside the JetStream duplicate window;
- p99 agent-to-JetStream durability below 2 seconds at the expected burst;
- p99 observation-to-queryable below 30 seconds at the expected burst;
- a separately declared end-to-end interactive durability, queryability,
  reconciliation/terminal, and graph-freshness SLO that remains bounded while
  bulk source streams, reconcile queues, graph outboxes, DLQ, and database
  writers operate at maximum admitted catch-up;
- a one-million-host, ten-port result drains in at most 6 minutes;
- at least 10,000 host observations/second aggregate on the documented reference
  deployment and backlog drain capacity at least twice live ingress;
- a measured MTR target of at least 1,000 traces/second or 20,000 hop rows/second
  in replay before production trace budgets are set;
- result serialization/delivery memory below 256 MiB and independent of total
  scan size; no full-scan result slice or JSON tree and no scheduled,
  sweep-profile, ad-hoc, or on-demand MTR run/interval result collection;
- bounded BEAM mailboxes and queues by bytes as well as item count;
- measured retained gateway memory remains bounded with maximum headers,
  compression, delayed PubAcks, and a zero-window bulk connection while
  interactive and recovery traffic continue within their SLOs;
- bounded global CNPG transaction/row/byte credits with stable Repo pool checkout
  latency, lock waits, WAL/fsync latency, and no timeout/redelivery storm while
  sync, control/API/Oban, and background/maintenance pools are concurrently busy;
- no reverse-order deadlock under concurrent source, graph, reconcile, recovery,
  DLQ, and repair writers using the canonical lock order;
- worst-case timer-fragmented traffic from 1,000 low-rate agents meets ingest and
  interactive-latency gates without one commit fsync per message; record messages/
  second, transactions/second, rows/transaction, commit fsyncs, and WAL per
  observation for single-message and adaptive-group modes;
- zero committed MTR traces without identity/outbox state, replay-safe graph
  repair after forced post-source-commit failures, and bounded graph-outbox lag;
- recovery PubAck without a durable `RecoveryResolvedV1` never reclaims local
  proof, and lost/replayed resolution converges without duplicate transitions;
- bulk poison at its DLQ/quarantine capacity cannot consume the interactive
  rejection reserve or block bounded interactive progress;
- stable NATS/database disk use during a 72-hour hourly-scan soak; and
- no row-delete/vacuum storm for retained sweep/MTR history.

Benchmarks cover 1k/10k/100k/1M hosts, zero/five/ten/fifty ports, MTR-heavy
profiles, 1-1,000 concurrent agents, full and timer-fragmented frames, 256/512 KiB
limits, maximum headers/compression, stalled bulk transport, delayed PubAcks, NATS/core outages,
redelivery, rolling upgrades, real CNPG WAL/index behavior, and retention.
Every result records the exact CPU/memory allocation, gateway and EventWriter
replica/worker counts, total physical streams and consumers/RAFT groups,
connections, stream-map version, traffic-class backlog/oldest age, stream leader/
replica placement, per-stream and
aggregate PubAck throughput, NATS fsync storage/network, CNPG topology, Repo pool
size/checkout latency/timeouts, transaction credits, schema/indexes/storage,
site/agent/execution mix, frame size, messages/second, transactions/second, rows/
transaction, commit fsyncs, domain rows/second, lock waits, WAL bytes per
observation, fsync latency, and tail latencies. Per-worker and per-logical-partition rates are
diagnostics, not substitutes for the aggregate gate. If one CNPG primary cannot
pass, rollout stops; adding consumers is not a substitute for a separately
designed stable network-scope/partition-to-database placement strategy.

## MTR Scheduling Guardrails

Every MTR-enabled profile has explicit per-site and global target, trace,
probe-rate, concurrency, duration, and backlog budgets. The compiler estimates
completion time from target count, hop/probe settings, rate, and assigned agent
capacity. It rejects or requires an explicit override when the estimated run
overlaps the next interval.

Large fleets use deterministic sharding, baseline sampling/rotation, critical
device/path selection, anomaly-triggered traces, and incident fan-out. "Run a
deep MTR against every million-host target every hour" is supported only if an
operator-supplied capacity plan and benchmarked storage budget make it viable;
it is never an implicit default.

## Migration and Rollback

1. Capture current JSON/proto size, CPU, allocation, gateway, NATS, CNPG, and
   storage baselines with representative fixtures.
2. Land new protobuf schemas, golden cross-language fixtures, capability fields,
   assignment fencing, additive network-scope columns, DB keys/ledger/retention
   structures, and no behavior change. Run an online idempotent shadow backfill
   for retained sweep/MTR rows from agent/site ownership while legacy writes
   continue. Persist a durable CDC cursor, capture every post-water write, and
   apply that delta continuously while historical backfill runs. Maintain a hard
   delta byte/age budget; slow or stop new legacy scan admission before capture
   can exhaust it. Open the final barrier only after catch-up reaches a configured
   bounded tail. Quarantine ambiguous rows rather than guessing;
   populate partition-local sweep/trace identity keys and legacy migration
   identity times, detect same-scope ID/content collisions, and continuously
   validate every scope-bound read/join without holding the cutover barrier for
   historical volume or creating a permanent per-observation side table.
3. Create subjects, ACLs, streams, pull consumers, DLQ, and legacy/v1 EventWriter
   decoders. Enqueue versioned graph-outbox rebuild work for retained trace
   history. At a barrier, stop the legacy direct graph writer; one canonical
   outbox projector then maintains separately idempotent old/new graph-schema
   statuses during the rollback window. Compare relational identity, vertices,
   edges, and properties; switch reads only after network-scope-safe v2 parity, then
   stop v1 projection and retire unscoped graph data after rollback closes.
4. Set and enforce a minimum dual-path agent/gateway version before cutover. Stop
   assigning new work to older binaries and upgrade them; this design does not
   build an unpatched-agent compatibility stream. The dual-path build changes
   legacy JSON to independently acknowledged frames no larger than 512 KiB, with
   stable IDs/checksums, signed scope/range authority, and no cumulative request.
5. Establish a destination database-admission epoch. Reserve static worst-case
   capacity for every not-yet-enrolled result writer, then fence/drain it before
   moving that reserve to grant-aware source/graph/reconcile/recovery/DLQ workers.
   V1 readiness requires all result writer generations to be enrolled and keeps
   sync/control/background pools separate.
6. At a short installation cutover barrier, stop new scan admission, fence/drain
   old direct-writer gateways/core requests, persist the final per-scope/agent
   legacy watermark, and drain only the bounded captured delta into ledger/domain/
   OCSF identity. Validate delta parity and advance the ingress epoch only after
   no old writer remains. Historical backfill MUST already be complete before the
   barrier; the barrier is not allowed to scan or rewrite unbounded history. Then
   enable the PubAcked JetStream/EventWriter path and remove ERTS/direct/volatile
   fallback.
7. Deploy the upgraded agents with disk spool and protobuf encoder disabled by
   default. Enable only when the gateway advertises `edge-results:v1` and explicit
   cohort config asks for it.
8. Canary one cohort and compare payload counts, DB rows, execution state,
   current device state, OCSF, scanner/banner metrics, trace/hop fidelity, lag,
   spool pressure, memory, latency, network-scope reads, and graph-v2 parity over
   both newly ingested and retained history. Format selection is sticky and
   mutually exclusive per execution; a shadow decoder may compare output but
   cannot write authoritative domain tables.
9. Expand gradually; migrate scheduled, sweep-profile, ad-hoc, and on-demand MTR
   producers to the canonical trace lane.
10. Remove agent-side duplicate metric expansion only after downstream parity.
11. Remove legacy JSON after the upgraded fleet and rollback window are proven;
   there is no long-lived unpatched-agent support requirement.

Rollback selects patched bounded legacy JSON only for new executions and still
uses PubAcked JetStream/EventWriter--never the retired direct writer. Agents
continue reading and draining every existing v1 spool lane; no rollback binary
may be deployed unless it understands that spool version. Backend dual decoders
remain until every JetStream message and agent spool is drained. Gateway rollback
is last. A consumer failure pauses consumption; it never falls back to a direct
database write.

## Alternatives Rejected

### Keep direct gRPC/ERTS and only replace JSON with protobuf

This reduces bytes but preserves false ACKs, volatile buffering, singleton core
routing, no replay, whole-run materialization, and the 64 MiB RPC window.

### Put the full MTR trace in each sweep host result

This couples heavy traces to latency-sensitive reachability, inflates every
retry, creates cross-table partial-fanout problems, and violates the dedicated
JetStream-first telemetry path. Stable correlation provides coherence without
physical co-location.

### Reuse generic MetricBatch for the full MTR trace

The existing mapping is lossy and expands one trace into hundreds of generic
points. A dedicated trace schema is both smaller and semantically complete.

### Store each whole scan or normal MTR trace as an object

This removes streamability, adds upload/reference/fetch/GC coordination, and
still consumes the current NATS Object Store's JetStream disk. Bounded domain
records are the simpler unit.

### Reassemble the entire scan in core

This recreates memory scaling, head-of-line blocking, and a large failure blast
radius. Every batch must be independently useful and idempotent.

## Resolved Design Values

- Target encoded frame: 256 KiB.
- Hard encoded frame: 512 KiB plus bounded transport headers.
- Initial logical partitions: 64 per schema/hash version.
- Logical partitions map disjointly to one or more benchmark-sized physical
  stream/RAFT groups through an audited map version; subject partitions never
  have overlapping authority. Physical shard count is a required deployment
  sizing result, not a wire-protocol constant.
- Bulk and interactive use disjoint physical streams and persistence durables,
  even in the smallest supported deployment. Within one class and physical
  stream, one persistence durable per schema version is the initial cardinality;
  any worker may process any logical key and database guards provide correctness.
- Each CNPG destination has one hard capacity budget split explicitly among
  result data plane, sync, control/API/Oban, and background/maintenance work.
  Inside the result pool, one fenced resident/write-byte/row/active-transaction/
  commit-rate budget
  covers source, graph, reconcile, recovery, DLQ, rollup, and repair writers,
  with unborrowable interactive and recovery/reconcile floors whose sum never
  exceeds the result total.
- Initial sweep count guard: 2,000 hosts.
- Initial MTR count guard: 128 traces.
- Hard projected-row guards: 10,000 sweep rows and 5,000 MTR rows per message.
- Agent is the durable pre-JetStream spool owner.
- Sweep-bulk, sweep-interactive, MTR-bulk, MTR-interactive, and reserved spool-
  recovery control use independent spool/credit sequence lanes. Traffic class
  remains immutable through reconcile, graph, DLQ, redrive, and quarantine.
- Each lane has an independent bidirectional RPC; bulk, interactive, and recovery
  use separately pooled HTTP/2 and NATS publisher connections with independent
  windows and pending-byte ceilings.
- One atomic agent-filesystem allocator covers all spools, quarantine, journals,
  rollover amplification, metadata, and scratch while reserving an unborrowable
  recovery/control/terminal floor.
- Gateway durability means a validated JetStream PubAck, not Core NATS publish.
- Broker headers carry the complete trusted routing/schema/size/checksum/
  assignment envelope and a digest binding those headers to the opaque body.
- Broker publication IDs include trusted identity, spool coordinates, and the
  immutable semantic-envelope digest; delivery coordinates are excluded from the
  ledger digest so recovered copies deduplicate semantically across lanes.
- Persistence uses `AckExplicit` and bounded adaptive compatible-message
  transactions; every constituent delivery is ACKed individually only after the
  containing commit.
- Sweep domain uniqueness uses scheduler-owned identity time, MTR uses UUIDv7-
  derived trace identity time, and ordinary correctness metadata retires by whole
  partition behind a finite replay watermark. Bounded exceptional holds preserve
  unresolved audit/redrive state without permanent side rows per host or trace.
- Well-formed non-conflicting events never depend on broker arrival order; plans,
  attempt state/evidence, and data are independently reconcilable from stable
  sequences and watermarks. Identity collisions are integrity failures with an
  explicit first-committed quarantine/repair rule.
- Stream capacity and retention cover the admitted outage window, catch-up
  interval, redelivery headroom, and safety margin rather than peak ingress
  multiplied by retention alone.
- Sweep shard reassignment uses a monotonic fenced assignment epoch plus a
  scheduler-signed, network-scope/agent/range-bound capability.
- Full MTR trace is a separate canonical protobuf event.
- Object references are not used for ordinary sweep/MTR observations.

Benchmark results may lower operational limits or increase partition count
before first rollout. Changing the wire meanings, ACK boundary, event split, or
idempotency model requires a new OpenSpec revision.
