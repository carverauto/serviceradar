# Change: Refactor the edge sweep and MTR result data plane

## Why

ServiceRadar must ingest scheduled observations from hundreds of thousands to
millions of hosts without treating one scan as one in-memory payload, falsely
acknowledging data before it is durable, or writing the same observation through
multiple high-cardinality representations.

The current path has four structural problems:

1. Sweep results are materialized as full JSON payloads and sent through
   `StreamStatus`; the agent then parses that JSON again to build a second
   protobuf `MetricBatch`. MTR producers also retain interval/run-wide result
   collections before building their telemetry output. For large scans these
   patterns create whole-run memory amplification, repeated serialization, and
   duplicate row expansion even though the existing MTR JetStream path is
   already protobuf.
2. A successful `StreamStatus` response is not a durability acknowledgement.
   The gateway forwards sweep results to core through an asynchronous ERTS cast;
   its fallback queue is memory-only and can drop acknowledged data. Existing
   gateway NATS publishers use Core NATS publish semantics rather than waiting
   for a JetStream publish acknowledgement.
3. The standard gRPC stream has a 64 MiB request window, while a one-million-host
   result can be hundreds of MiB even before full MTR traces. Converting one
   whole-run JSON document to one whole-run protobuf does not solve this limit.
4. The existing `mtr-metrics` `MetricBatch` is a scalar projection, not a full
   trace contract. It omits rich path data and is persisted as generic
   timeseries rows; it does not populate `mtr_traces` and `mtr_hops`.

The correct architecture is layered rather than "gRPC or JetStream":

```text
scanner -> agent disk spool -> bounded protobuf frames over mTLS gRPC
        -> authenticated gateway -> JetStream PubAck
        -> partitioned pull consumer -> idempotent database projection
```

gRPC remains the authenticated, flow-controlled edge transport. JetStream
becomes the durable commit, replay, fan-out, and backpressure boundary for
structured observations. ERTS remains appropriate for control traffic and
low-volume status, not the high-volume durable result path.

ServiceRadar is deliberately one customer per installation; the SaaS control
plane provisions each customer into a separate cluster. This change therefore
does not introduce an in-cluster tenant axis, per-tenant broker accounts,
database schemas, or capacity cells. `network_scope_id` is only the signed
site/address-space namespace needed to distinguish sites (including overlapping
RFC1918 networks). Scheduling and overload isolation are by network/site scope,
agent, execution, and scheduler-attested traffic class.

## What Changes

### Canonical typed observation events

- **ADD** a versioned `EdgeResultFrame` transport envelope with a persistent
  per-lane spool sequence, stable event ID, payload kind/schema version,
  compression, encoded/uncompressed sizes, checksum, projected database-row and
  write-byte costs with a versioned cost model, authoritative network scope,
  immutable traffic class, one authorization context/range, separate collection
  and renewable spool-delivery capabilities, and opaque protobuf body. The gateway persists an
  equivalent complete broker-header envelope bound to the body by a digest.
- **ADD** compact, byte-bounded `SweepObservationBatchV1` messages for ICMP/TCP
  results and an optional small MTR summary plus `trace_id`. Batch-level fields
  carry plan/range digests, configured modes, availability policy, and exact
  `(mode, protocol, port)` check dictionaries. Per-mode revisions and explicit
  outcomes make late/out-of-order fragments mergeable without one global
  availability boolean.
- **ADD** separate `MtrTraceBatchV1` messages for complete structured traces.
  Full hops are not embedded in sweep observations and are not flattened into a
  generic `MetricBatch`. Each batch is homogeneous for source, execution/check/
  command authorization, assignment epoch, and range so one signed outer
  context covers every record.
- **ADD** immutable scheduler execution-plan headers with bounded content-
  addressed range pages, append-only fenced assignment attempts, and
  `SweepExecutionEventV1` start/progress/terminal evidence so core
  can reconcile batches, ranges, counts, and expected MTR traces without a
  whole-execution transaction. The scheduler terminalizes an orphaned attempt
  as lost/expired/superseded before assigning its remaining coverage.

### Bounded streaming instead of whole-scan materialization

- **CHANGE** the sweeper/agent result boundary to release completed host windows
  into a byte-sized batch builder and crash-safe disk spool. It MUST NOT build a
  full-run JSON tree or retain a full-run delivery buffer.
- **MODEL** each execution as a logical stream: a start event, independently
  durable data micro-batches, bounded progress/watermark events, agent terminal
  evidence when available, and authoritative scheduler terminal state for every
  assignment attempt. Data is queryable while later targets are still being
  scanned; no component waits to reassemble the execution. An immutable
  scheduler plan supplies the expected ranges used to reconcile the stream.
- **BOUND** in-flight bytes and records at the scanner, spool sender, gateway,
  JetStream consumer, and database writer. Pressure propagates upstream, and
  scheduling is fair by network/site partition, agent, execution, and traffic
  class. Mandatory disjoint bulk/interactive streams and database-credit floors
  prevent one million-target bulk scan from consuming interactive progress. The
  same class-aware reservation applies before results exist: probe workers,
  sockets, ICMP/DNS tokens, CPU, spool, and sender credits retain an unborrowable
  interactive floor.
- Reserve worst-case spool output before opening each target window, cap active
  aggregation by bytes and projected rows, and fail closed on disk-full, I/O,
  torn-tail, or corruption conditions without claiming data durable. One atomic
  filesystem allocator covers every lane, quarantine, journals, rollover
  amplification, metadata, and scratch so nominal per-lane limits cannot
  overcommit disk or consume the recovery/terminal floor.
- A corrupt committed middle record uses a signed loss tombstone on a separately
  reserved recovery stream plus crash-journaled, segment-at-a-time new-spool
  rollover. Bounded/chained loss manifests never enumerate the recoverable tail.
  A recovery consumer records the audit and partializes/reschedules affected
  ranges; every unresolved recoverable event keeps its semantic identity on the
  new spool. Recovery-stream PubAck stops retransmission but does not delete the
  local recovery proof; the agent retains it until a signed consumer-committed
  `RecoveryResolvedV1` (or idempotent resolution query) is durable locally.
- Target encoded frames are 256 KiB with a hard 512 KiB limit, below the current
  1 MiB NATS default. Count limits are secondary guards; actual protobuf size is
  authoritative.
- Normal sweep observations and bounded MTR traces remain JetStream records.
  This v1 does not add an Object Store fallback; opaque artifact lifecycle is a
  separate proposal.

### Durable gateway handoff

- **ADD** an independent bidirectional gRPC result-ingest RPC per durable lane,
  with cumulative dispositions over sweep/MTR spool sequences plus a separately
  reserved recovery-control lane. Bulk, interactive, and recovery RPCs use
  separately pooled HTTP/2 connections and NATS publisher connections with
  independent windows/pending-byte ceilings, so a stalled bulk write cannot stop
  bounded interactive progress or loss reporting.
- The gateway derives the installation trust domain and agent through the
  canonical deployment-CA/certificate-CN
  mTLS resolver (SPIFFE metadata is optional compatibility), locally verifies
  the one signed collection/delivery authorization context and range, stamps the
  complete authoritative network-scope/agent/routing/decoding header envelope, and
  publishes the inner protobuf bytes unchanged.
- The gateway MUST use a JetStream publish request and set `Nats-Msg-Id` from
  trusted network-scope/agent, spool ID/sequence, and a domain-semantic digest of body,
  schema, sizes/row cost, execution/epoch, authorization/range, and collection
  proof. The semantic digest excludes delivery coordinates so recovered copies
  deduplicate in the database even though their broker publication ID changes.
  The gateway waits for a real PubAck before accepting the edge sequence. A
  different body or semantic header under the same event ID reaches the ledger
  as a conflict instead of being hidden by broker deduplication.
  If JetStream is unavailable or full, the gateway does not ACK; gRPC flow
  control and the agent disk spool apply backpressure.
- The memory-only gateway results buffer is not used by this data plane.
- The PubAck must represent the configured durability authority. A Core NATS
  handoff, ERTS send, or non-authoritative leaf/mirror acceptance is not a
  durability acknowledgement; edge-local authority requires an explicit
  replication and site-loss RPO decision.

### Partitioned, replay-safe processing

- **ADD** mandatory disjoint file-backed bulk/interactive streams for sweep and
  MTR so trace or catch-up load cannot starve bounded interactive work. The
  single-customer installation uses fixed subjects, 64 stable logical partitions
  per class, ACLs/quotas, deployment-local pull consumers, production replication,
  and
  `DiscardNew` overload behavior rather than silent oldest-message eviction. A
  deployment maps disjoint logical partitions onto one or more physical stream/
  RAFT groups, so consumer concurrency does not get mistaken for broker write
  scaling. Capacity and `MaxAge` cover the admitted aggregate arrival envelope
  through supported outage plus worst-case catch-up and margin.
- **BOUND** CNPG with explicit result, sync, control/API/Oban, and background
  capacity pools whose maxima fit measured Repo/WAL/lock headroom. Inside the
  result pool, fenced resident/write-byte, row, active-transaction, and commit-
  rate/fsync credits cover
  source, graph, reconciliation, recovery, DLQ, rollup, and repair writers, with
  reserved interactive/recovery progress. Initial durable
  cardinality is one shared persistence durable per physical stream shard/schema
  version; any replica may process any logical key and correctness comes from
  database guards, not application-local ownership.
- **CHANGE** persistence to process independently decodable batches in bounded
  adaptive transaction groups. A low-latency class MAY commit one message, while
  sparse/bulk traffic MAY group multiple messages under one aggregate byte/row/
  duration bound. Stable IDs, an ingest ledger, uniqueness constraints,
  deterministic OCSF IDs, explicit per-delivery ACKs after commit, and replay-safe
  upserts make redelivery harmless without forcing one fsync per small frame.
- **BOUND** correctness metadata without a permanent side row per host or trace:
  scheduler-owned sweep identity time and UUIDv7 MTR identity time make domain
  uniqueness partition-local; ordinary ledger/slot state retires by whole time
  partition after a finite replay watermark. Only bounded unresolved exceptional
  work receives a `correctness_hold`, and stalled retirement stops new admission.
- Poison messages are copied with their original bytes and diagnostics to a
  capacity-reserved, class-separated partitioned DLQ and PubAcked there before
  the source delivery is terminated. DLQ `MaxAge` is disabled; a bounded durable
  catalog governs explicit resolution, redrive, waiver, and authorized deletion
  so unresolved evidence cannot expire silently. Poison circuit breakers pause
  systemic decoder failures, and an audited deployment-local synthetic-lane
  redrive preserves original semantic identity and traffic class after repair.
- Execution completion is reconciled from the immutable plan, committed batch
  ranges, authoritative attempt terminals, and expected MTR state; missing data
  remains visibly partial rather than falsely complete.
- Immutable traffic class follows each event into reconciliation, graph outbox,
  DLQ, redrive, and local quarantine. Each stage has a disjoint queue or an
  unborrowable interactive capacity floor, so bulk catch-up cannot satisfy the
  ingest SLO while silently starving interactive terminal state or topology.
- Correctness for well-formed, non-conflicting identities does not depend on
  broker arrival order, even within a shard. Stable network-scope/execution/shard/
  attempt/sequence/mode-revision/event identities make asynchronous publication,
  retry, and late arrival safe. Reusing one identity for different content is a
  protocol-integrity incident with explicit quarantine and fenced range repair.
- Shard assignment carries a scheduler-signed collection capability with a
  monotonic fencing epoch bound to network scope, agent, range, generation, and expiry;
  a separate event-bound delivery capability may drain old immutable spool data
  without authorizing probes. A replacement cannot race a stale owner, and the
  highest agent-claimed epoch is never authoritative.

### One canonical representation

- **REMOVE after parity** the agent-generated per-host sweep `MetricBatch` and
  the agent-generated MTR-hop metric expansion. These duplicate the domain
  observations and create much greater row cardinality than the canonical data.
- A v1 execution never emits the duplicate metric form. Legacy executions retain
  it only during compatibility; parity comparison uses separate cohorts or a
  non-writing shadow rather than dual authoritative writes.
- Required low-cardinality scanner, execution, availability-ratio, and trace
  health metrics are derived downstream from the canonical protobuf event.
  Real-time consumers subscribe to the same structured stream instead of
  requiring a second agent serialization.

### Explicit rollout and capacity gates

- **ADD** a negotiated `edge-results:v1` capability and explicit per-agent/cohort
  result-format setting. A config content hash is not a rollout gate.
- Before enabling v1, require and roll out a minimum dual-path agent/gateway
  version. Older agents receive no new assignments; this change deliberately does
  not build an unpatched-agent bridge. The patched legacy sender emits one stable
  signed frame no larger than 512 KiB at a time through the PubAcked JetStream/
  EventWriter path. Historical identity/scope backfill runs online behind a
  durable CDC cursor while concurrent deltas are continuously applied; a hard
  byte/age bound stops legacy admission before overflow. A short ingress-epoch
  barrier opens only at a bounded tail, drains that delta, and retires authoritative ERTS/direct persistence before
  canary; it never performs an unbounded historical rewrite. One execution selects one format;
  comparison shadows do not write domain tables.
- Rollback selects only the patched bounded legacy format for new executions and
  still uses JetStream/EventWriter while upgraded agents drain v1 spools.
- Remove JSON after the upgraded fleet and rollback window are proven.
- Require representative 100k- and 1M-host benchmarks, failure injection, and a
  72-hour soak before fleet enablement. The gate covers memory, PubAck latency,
  stream lag, database throughput/WAL, replay, and stable storage growth.

## Scope and Relationships

- This change supersedes the unimplemented `add-bulk-payload-pipeline` design.
  Its whole-payload reassembly and in-memory gateway buffering are not suitable
  durability or scaling boundaries.
- This change preserves the useful part of `add-sweep-profile-mtr`: a small
  MTR reachability summary on the host result. It replaces that proposal's claim
  that the existing `mtr-metrics` path carries full traces. Phase 2 MUST emit the
  dedicated `MtrTraceBatchV1` event instead.
- The same typed MTR trace lane is the target for scheduled, sweep-profile,
  ad-hoc, and on-demand MTR. Issue #4669 should converge on this lane rather than
  encode a complete trace as generic metric attributes.
- `add-adhoc-network-scan` MUST replace its `adhoc-scan-metrics` result contract
  with these canonical observation/trace events while preserving `scan_run_id`.
  The `add-sweep-profile-mtr` branch MUST rebase Phase 2 before either dependent
  implementation begins.
- The change composes with `remove-agent-gateway-spiffe-dependency`,
  `add-per-agent-availability`, `refactor-identity-cache-ingestion-correctness`,
  `fix-eventwriter-backpressure-hotpath`, and the existing operator-managed MTR
  retention work; it does not replace their identity, state, pull-consumer, or
  retention-control contracts.
- This change aligns the stale `nats-tenant-isolation` and
  `nats-cross-account-consumption` runtime specs with the completed
  `2286-break-out-tenant-control-plane` north star: the OSS/runtime cluster is
  single-customer, uses fixed installation-local subjects and component
  credentials, and never derives customer or database authority from a subject
  prefix. Any SaaS cross-customer orchestration remains outside this repository
  and outside the result data plane.
- Broker-free large sync ingestion remains unchanged. Sync snapshots are a
  separate workload protected by the existing `ingestion-routing` requirement.

## Impact

- **Affected specs**: `edge-architecture`, `ingestion-routing`,
  `observability-signals`, `sweeper`, `mtr-diagnostics`, `sweep-jobs`, `cnpg`,
  `agent-connectivity`, `agent-config`, `nats-tenant-isolation`,
  `nats-cross-account-consumption`, `age-graph`, and `build-web-ui`.
- **Affected code**:
  - protobuf definitions and generated Go/Elixir modules;
  - Go sweeper result lifecycle, streaming batch builder, disk spool, and gateway
    client;
  - Elixir agent-gateway result RPC, identity attestation, JetStream publisher,
    ACL/configuration, and removal of volatile result buffering for this lane;
  - Elixir core EventWriter streams, partitioned pull consumers, sweep/MTR
    processors, DLQ, ingest ledger, and execution reconciliation;
  - sweep/MTR resources, uniqueness constraints, retention, and rollups;
  - Helm/Docker stream capacity and gateway publisher configuration.
- **Compatibility**: minimum-version additive dual-path migration, followed by a separately
  gated removal of legacy JSON and duplicate agent metric projections.
- **Breaking change**: after the compatibility window, sweep and MTR result data
  no longer use `GatewayServiceStatus{source: "results"}` JSON delivery.
