# Change: Refactor the durable edge producer data plane

> **DEPENDS ON `freeze-edge-record-v1-abi`.** The wire ABI — record and frame
> shapes, identity and digest grammars, enums, compatibility rules, the
> classification-span freeze, and the freeze gate (tasks 1.1–1.7, 1.13–1.15) —
> moved to that change. The ORIGINAL task 2.20 -- the loss-classification span freeze -- folded into that
> change's 1.6a; the number 2.20 is REUSED here for a distinct runtime task and is
> not a leftover; task 1.3 split, with its
> ABI/schema/correlation half there and its storage/repair/GC half here. This
> change is now the RUNTIME change: producer sinks, spool, gateway relay,
> JetStream, projectors, migration, and rollout over a frozen contract. It MUST
> NOT re-freeze anything the ABI change owns.

Task 0.12 in `tasks.md` is a GUARDED PRE-FREEZE INTEGRATION MILESTONE
against the currently committed candidate ABI. Passing it does not complete or
waive the ABI freeze, authorize an `edge-records:v1` production rollout, or make
this runtime change production-ready. Runtime promotion still depends on the
completed ABI freeze and its own rollout gates.

## Immediate implementation milestone

After `freeze-edge-record-v1-abi` task 1.5-l is saved and the active integration
branch is reconciled with `staging`, the next milestone is the FIRST GREEN
VERTICAL SLICE, not another expansion of independently proven pieces. Drive one
committed `SweepObservationBatchV1` fixture through the real path:

```text
record -> agent spool -> mTLS gRPC -> gateway -> JetStream PubAck
       -> EventWriter -> idempotent CNPG transaction -> query
```

The slice MUST prove that the JetStream body is exactly the record bytes stored
in the spool, replaying the same delivery creates no duplicate domain rows, and
JetStream unavailability leaves the spool entry unresolved. A synthetic fixture
is sufficient for this first milestone; connecting a real scanner is the next
increment after the path itself is green.

This milestone does not waive the remaining ABI freeze, recovery, security,
capacity, migration, or soak requirements. It prevents those horizontal proof
surfaces from indefinitely displacing the first composed runtime result: a real
record must travel through the new pipeline and land in the database before the
proof surface broadens again, unless a demonstrated defect blocks that path.

### Active milestone authority

Until the first green vertical slice above is recorded as complete in task 0.12,
it governs implementation ORDER and review SCOPE for this change. Other unchecked
tasks remain real obligations, but they are not prerequisites to this milestone
unless task 0.12 names them. They SHALL stay unchecked rather than being pulled
into the active PR merely because adjacent code, a surviving mutation, or a more
general future case exists.

The active slice is deliberately one committed BULK `SweepObservationBatchV1`
fixture on one valid durable route plus ONLY the six finite control groups named
in task 0.12. Scanner integration, MTR, recovery, complete DLQ/redrive coverage,
generalized producer support, fleet sizing, benchmarks, soak, and the final
ABI/archive gate resume only after this slice is green. A demonstrated
data-loss, authentication, unbounded-work, false-green, or unresolved normative
defect within the review contract still blocks; `design.md` defines that
contract and its stopping rule. This is a work-order freeze, not a waiver of the
deferred requirements.

## Why

ServiceRadar must ingest durable output from built-in collectors, scanners,
Wasm plugins, native add-ons, and integration adapters at fleet scale without
treating one run as one in-memory payload, falsely acknowledging data before it
is durable, or writing the same fact through multiple high-cardinality
representations. Million-host sweeps and full MTR traces are the first load
tests for the shared producer boundary, not identities baked into that boundary.

The current path has five structural problems:

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
5. Built-in scanners, Wasm plugins, native add-ons, OTLP relays, and embedded
   sync integrations use separate output queues, payload limits, retry loops,
   and acknowledgement meanings. Wasm `submit_result`, native
   `StreamTelemetry`, and integration JSON pages can still terminate in memory
   or `StreamStatus`, while the specialized OTLP relay carries its own spool.
   Adding a producer therefore keeps adding transport code to
   `serviceradar-agent` instead of reusing one bounded durable publishing
   boundary.

The correct architecture is layered rather than "gRPC or JetStream":

```text
agent/scanner/plugin/add-on/integration producer -> agent-owned producer API
        -> shared agent disk spool -> bounded typed frames over mTLS gRPC
        -> authenticated gateway -> JetStream PubAck
        -> partitioned pull consumer -> approved idempotent projection
```

gRPC remains the authenticated, flow-controlled edge transport. JetStream
becomes the durable commit, replay, fan-out, and backpressure boundary for
structured observations. ERTS remains appropriate for control traffic and
low-volume status, not the high-volume durable result path.

The reusable boundary is a **durable record producer**, not a universal workflow
or byte-transport API. Plugins and add-ons do not construct transport frames,
select NATS subjects, hold broker credentials, or write database schemas. They
submit a bounded output covered by an approved package/assignment contract; the
agent attests the carrier, package, assignment, run, and scope, reserves
capacity, assigns immutable delivery identity, and acknowledges the local
producer only after crash-safe spool append. Attestation never turns
producer-supplied body claims into trusted identity. Live media, interactive
tunnels, commands, credentials, update plans, and large opaque artifacts retain
their dedicated transports.

ServiceRadar is deliberately one customer per installation; the SaaS control
plane provisions each customer into a separate cluster. This change therefore
does not introduce an in-cluster tenant axis, per-tenant broker accounts,
database schemas, or capacity cells. `network_scope_id` is only the signed
site/address-space namespace needed to distinguish sites (including overlapping
RFC1918 networks). Scheduling and overload isolation are by network/site scope,
agent, producer assignment, run/execution, and control-plane-attested traffic
class.

## What Changes

### Canonical typed durable records

- **ADD** the versioned authoritative `EdgeRecordV1`, `EdgeDeliveryFrameV1`, sweep,
  and MTR contracts. Their exact fields, numbers, enums, and grammar versions are
  owned and frozen by the edge record v1 wire ABI change and are NOT enumerated
  here -- this change consumes them.

- **ADD** a small `EdgeDeliveryFrameV1` for edge transport only: persistent
  spool ID/sequence, the sink-computed exact-record checksum `record_sha256`,
  renewable delivery capability,
  and the unchanged `record_bytes`. The common spool owns the wrapper and exact
  record bytes; rollover/recovery may change delivery coordinates by creating a
  new wrapper without changing or re-encoding `EdgeRecordV1`. gRPC decodes the
  delivery wrapper, the gateway bounded-decodes/verifies the record, and
  JetStream persists the exact `record_bytes` as its message body. NATS headers
  remain minimal and transport-only; EventWriter decodes `EdgeRecordV1`.
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
- **GENERALIZE** the frame and lane metadata so the same transport/spool engine
  carries any approved, bounded, persisted edge record family. Add trusted
  producer/package/assignment provenance and a versioned output-contract ID,
  digest, encoding, cost model, delivery policy, and run/epoch correlation.
  A lane is a finite platform route-profile/immutable-traffic-class pair, not
  one hard-coded scanner implementation, payload family, package, or
  plugin-selected subject.
- **DEFINE** every output contract by a globally unambiguous, approval-owned
  contract ID/version and the digest of its complete immutable bundle: encoding
  and canonicalization, structural validator, authoritative-field rules,
  partition rule, cost model, route profile, projector configuration,
  retention/classification, domain identity/revision semantics, and error
  policy. Standard IDs live in a reserved platform namespace; extension IDs are
  namespaced by approved publisher/package identity and cannot be claimed by a
  different signer. A registry epoch authorizes an exact bundle set but is not
  a substitute for the per-record bundle and effective-grant digests.
- **ADD** a byte-bounded inventory snapshot batch plus start,
  checkpoint, terminal-manifest, and abort events. A complete snapshot may
  contain many independently durable but assignment-bounded batches without
  whole-run materialization. Absence reconciliation becomes authoritative only
  after every declared page and the ordered manifest root commit and a provider
  snapshot token/revision or contract-specific consistency proof establishes
  completeness. Otherwise the run is upsert-only. The embedded Armis inbound
  sync is the first non-sweep migration.
- **ADD** a bounded extension-record batch for approved package-defined outputs.
  The batch is homogeneous for output contract, package version, assignment,
  run, authorization, traffic class, and encoding. Standard platform contracts
  (MetricBatch, OTLP, OCSF, inventory, sweep, and MTR) remain preferred; a
  package-defined schema is usable only when its signed package contribution
  selects an installed bounded platform processor. Arbitrary executable core
  processors are not accepted.
- **ADD** immutable scheduler execution-plan headers with bounded content-
  addressed range pages, append-only fenced assignment attempts, and
  `SweepExecutionEventV1` start/progress/terminal evidence so core
  can reconcile batches, ranges, counts, and expected MTR traces without a
  whole-execution transaction. The scheduler terminalizes an orphaned attempt
  as lost/expired/superseded before REASSIGNING ITS COVERAGE. In v1 that reassignment
  replays the SAME COMPLETE range window, not a sparse remainder: the frozen ABI
  represents an assignment's MTR expectation as one CONTIGUOUS plan-global window, so
  "remaining coverage" as a partial subset is NOT representable and is deferred to the
  bounded-subset representation.

### Bounded streaming instead of whole-scan materialization

- **CHANGE** the sweeper/agent result boundary to release completed host windows
  into a byte-sized batch builder and crash-safe disk spool. It MUST NOT build a
  full-run JSON tree or retain a full-run delivery buffer.
- **ADD** one agent-owned producer service with adapters for built-in Go
  collectors, Wasm host calls, and native add-on gRPC streams. A producer emits
  bounded typed batches and lifecycle/checkpoint records; it never owns
  `EdgeRecordV1`, `EdgeDeliveryFrameV1`, spool sequence, network scope, traffic class, authorization
  proof, gateway selection, or broker routing. A successful producer receipt
  means the agent-created, complete binary `EdgeRecordV1` bytes and their
  delivery wrapper are fsynced in the common agent spool, not merely admitted
  to a channel. The producer submits bounded UNCOMPRESSED contract-payload
  bytes; the sink derives `submission_sha256` (pre-compression) and does its
  retry/receipt lookup BEFORE compressing, then compresses once. The exact record
  bytes later carried inside gRPC are stored unchanged by JetStream.
- **ADD** an atomic durable producer-key journal committed with each spool append.
  It binds package digest, assignment, host-issued run, output contract, and
  producer idempotency key to the event ID, the pre-compression
  `submission_sha256`, and receipt for the
  supported retry horizon. It survives agent and producer restart, lane
  rollover, and spool reclamation. Receipt lookup closes timeout-after-fsync
  crashes; reusing a key for a different `submission_sha256` is an integrity
  failure (a byte-layout difference that preserves the `submission_sha256`
  returns the original receipt). After a
  run's signed retry horizon and safe-GC watermark pass, a late lookup returns
  `RETRY_WINDOW_EXPIRED` rather than allocating a new event under the old key.
- **ADD** a versioned binary Wasm host ABI and one generic native add-on record
  relay. Wasm pays one bounded guest-to-host copy without protobuf/base64/JSON
  wrapping. Native records use byte/frame credits, assignment-bound session
  nonces, resume watermarks, and cumulative ACK only after common-spool fsync.
  Retryable pressure is distinct from permanent schema, size, capability,
  revocation, and quota errors.
- **CHANGE** Wasm and native add-on manifests to declare bounded output
  contracts and resource/rate requests. Package approval and assignment compile
  those requests into least-privilege output grants. The runtime enforces
  per-producer outstanding bytes, rate, run, record, and spool quotas underneath
  the same installation/agent hard budgets; a producer cannot promote itself to
  interactive traffic.
- **VALIDATE** every accepted record against the pinned contract before the
  agent gives a durable receipt. The agent runs the approved bounded structural
  validator and either computes the pinned conservative cost or charges the
  contract's fixed worst-case cost; EventWriter independently validates and
  recomputes before side effects. Durable contracts cannot select a silent-drop
  error policy.
- **MODEL** each execution as a logical stream: a start event, independently
  durable data micro-batches, bounded progress/watermark events, agent terminal
  evidence when available, and authoritative scheduler terminal state for every
  assignment attempt. Data is queryable while later targets are still being
  scanned; no component waits to reassemble the execution. An immutable
  scheduler plan supplies the expected ranges used to reconcile the stream.
- **BOUND** in-flight bytes and records at the scanner, spool sender, gateway,
  JetStream consumer, and database writer. Pressure propagates upstream, and
  scheduling is fair by network/site partition, agent, producer assignment,
  run/execution, and traffic class. Mandatory disjoint bulk/interactive streams
  and database-credit floors
  prevent one million-target bulk scan from consuming interactive progress. The
  same class-aware reservation applies before results exist: probe workers,
  sockets, ICMP/DNS tokens, CPU, spool, and sender credits retain an unborrowable
  interactive floor.
- Reserve worst-case spool output before opening each target window, cap active
  aggregation by bytes and projected rows, and fail closed on disk-full, I/O,
  torn-tail, or corruption conditions without claiming data durable. One atomic
  filesystem allocator covers every lane, quarantine, producer-receipt and
  recovery journals, rollover
  amplification, metadata, and scratch so nominal per-lane limits cannot
  overcommit disk or consume the recovery/terminal floor.
- A corrupt committed middle record uses a journalled, content-addressed loss
  tombstone (NOT agent-signed; no agent-signature ABI exists) on a separately
  reserved recovery stream plus crash-journaled, segment-at-a-time new-spool
  rollover. Bounded/chained loss manifests never enumerate the recoverable tail.
  A recovery consumer records the audit and partializes/reschedules affected
  ranges; every unresolved recoverable event keeps its semantic identity on the
  new spool. Recovery-stream PubAck stops retransmission but does not delete the
  local recovery proof; the agent retains it until a signed consumer-committed
  `RecoveryResolvedV1` (or idempotent resolution query) is durable locally.
- Target encoded `EdgeRecordV1` messages are 256 KiB with the frozen hard `MaxRecordBytes` limit,
  below the current 1 MiB NATS default. The delivery wrapper and minimal broker
  headers have separate small bounds. Count limits are secondary guards; actual
  protobuf size is authoritative.
- Bounded observations, traces, inventory pages, metrics, findings, events, and
  extension records remain JetStream records. This v1 does not use JetStream as
  an unbounded byte pipe or add an Object Store fallback; opaque artifact and
  live-media lifecycles remain separate contracts whose durable metadata may
  reference those objects/sessions.

### Durable gateway handoff

- **ADD** an independent bidirectional gRPC record-ingest RPC per durable
  traffic/delivery lane, whose nonce-bound `EdgeDeliveryAckV1` carries the typed
  disposition as an `EdgeRecordDispositionKind` -- the six-value enum frozen by the
  edge record v1 wire ABI change and landed in #4713, whose generated members are
  the only values on the wire. The runtime outcome names this change uses
  (`primary_publication`, `audit_publication`, `quarantine_publication`,
  `security_quarantine_publication`, `retryable_rejection`, `permanent_rejection`)
  are INTERNAL to this change and are not wire values; each maps onto exactly one
  generated member, and the mapping is the gateway publication matrix in
  `design.md`. The ACK also carries a
  `session_nonce`, and a `resolved_through_sequence` REMOTE
  terminal-disposition-through watermark over shared producer spool sequences
  (the separate agent-local reclaim watermark governs spool reclamation and is
  never conflated with it), plus a separately reserved recovery-control lane. Bulk,
  interactive, and recovery RPCs use
  separately pooled HTTP/2 connections and NATS publisher connections with
  independent windows/pending-byte ceilings, so a stalled bulk write cannot stop
  bounded interactive progress or loss reporting.
- The gateway derives the installation trust domain and authenticated agent
  origin through the
  canonical deployment-CA/certificate-CN
  mTLS resolver (SPIFFE metadata is optional compatibility), locally verifies
  the signed production grant plus the applicable source-authorization/delivery
  context and scope, compares the claimed origin/network scope to mTLS, and
  publishes the exact received `EdgeRecordV1` bytes unchanged. It does not
  move semantic authority into NATS headers or decode/re-encode the domain body.
- The gateway MUST use a JetStream publish request and set `Nats-Msg-Id` from the
  transcript frozen by the edge record v1 wire ABI; its ordered inputs are not
  restated here.

### Partitioned, replay-safe processing

- **ADD** one finite platform-owned `durable-records-v1` route profile with
  mandatory disjoint file-backed bulk/interactive streams, plus a reserved
  recovery lane. Sweep, MTR, inventory, metrics, events, and approved extension
  contracts share fixed generic subjects; importing a package never adds a
  stream, subject, consumer, connection, or RAFT group. The single-customer
  installation uses 64 stable logical partitions per class, ACLs/quotas,
  deployment-local pull consumers, production replication, and
  `DiscardNew` overload behavior rather than silent oldest-message eviction. A
  deployment maps disjoint logical partitions onto one or more physical stream/
  RAFT groups, so consumer concurrency does not get mistaken for broker write
  scaling. Capacity and `MaxAge` cover the admitted aggregate arrival envelope
  through supported outage plus worst-case catch-up and margin.
- **ROUTE** approved producer outputs through a deployment-owned contract
  registry shared by assignment compilation, gateway readiness, subject
  mapping, and EventWriter. Packages may request a standard output contract or
  contribute a bounded schema/declarative processor, but they cannot create
  subjects, streams, consumers, database DDL, executable BEAM processors, or
  high-cardinality routing labels. Physical stream count stays bounded as
  producer/package count grows. A contract digest pins its full historical
  schema/canonicalization, validator, authoritative-field and partition rules,
  cost model, projector configuration, retention/classification, domain
  identity/revision semantics, and error policy through every spool/replay/DLQ
  horizon. Planned retirement may drain pinned backlog; security revocation
  holds it fail-closed pending an operator-approved safe redrive or waiver.
- **BOUND** CNPG with explicit durable-record, sync, control/API/Oban, and background
  capacity pools whose maxima fit measured Repo/WAL/lock headroom. Inside the
  durable-record pool, fenced resident/write-byte, row, active-transaction, and commit-
  rate/fsync credits cover source, graph, reconciliation, recovery, DLQ, rollup,
  and repair writers, with reserved interactive/recovery progress. Initial
  durable cardinality is one registry-dispatching shared persistence durable per
  physical stream shard/route profile; adding a package contract does not add a
  durable. Any replica may process any logical key and correctness comes from
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
  broker arrival order, even within a shard. Every contract defines stable
  domain identity and revision/merge rules over the attested origin, scope,
  assignment, run, and event. Sweep execution/shard/attempt/sequence and
  mode-revision are one typed example. Reusing one identity for different
  content is a protocol-integrity incident with explicit quarantine and fenced
  repair.
- Shard assignment carries a scheduler-signed collection capability with a
  monotonic fencing epoch bound to network scope, agent, range, generation, and expiry;
  a separate event-bound delivery capability may drain old immutable spool data
  without authorizing probes. A replacement cannot race a stale owner, and the
  highest agent-claimed epoch is never authoritative.

### One canonical representation

- **REMOVE after parity** the agent-generated per-host sweep `MetricBatch` and
  the agent-generated MTR-hop metric expansion. These duplicate the domain
  observations and create much greater row cardinality than the canonical data.
- A v1 execution never emits the duplicate metric form. Already-accepted
  pre-cutover executions may finish and drain their old projection; parity
  comparison uses separate hard-cut cohorts or a non-writing shadow rather than
  dual authoritative writes.
- Required low-cardinality scanner, execution, availability-ratio, and trace
  health metrics are derived downstream from the authoritative protobuf event.
  Real-time consumers subscribe to the same structured stream instead of
  requiring a second agent serialization.
- Plugin/add-on persisted output likewise has one canonical ingress record.
  Small checker health/status may remain `GatewayServiceStatus`, but inventory,
  findings, events, metrics, traces, enrichment, and other durable payloads no
  longer hide inside `serviceradar.plugin_result.v1` or a lossy telemetry queue.

### Explicit rollout and capacity gates

- **ADD** a negotiated `edge-records:v1` capability and explicit per-cohort
  producer-plane enablement epoch. This is an assignment eligibility gate, not
  a caller- or execution-selectable format; a config content hash is not a
  rollout gate.
- Before enabling v1, require a minimum `edge-records:v1`
  agent/gateway/producer-adapter version. Older agents receive no new
  producer-plane assignments and are upgraded or remain ineligible. This change
  deliberately adds neither an unpatched-agent bridge nor a patched legacy
  sender/payload family for new work.
- Historical identity/scope backfill runs online behind a durable CDC cursor
  while pre-cutover deltas are continuously applied; a hard byte/age bound stops
  legacy admission before overflow. Each cohort uses a short ingress-epoch hard
  cut: stop new legacy admission, finish or fence already-issued work, drain only
  the bounded pre-cutover backlog to a final scope/origin watermark, and retire
  every authoritative ERTS/direct writer before assigning new work through the
  producer plane. The barrier never performs an unbounded historical rewrite or
  chooses a format per execution.
- Rollback stops new affected assignments and producer runs while upgraded
  agents, gateways, pinned contract bundles, streams, and consumers drain every
  new-format spool and backlog. It never emits new legacy JSON or restores a
  direct database writer.
- Roll out per output contract: registry and historical bundles, common sink and
  spool, built-in sweep/MTR, Wasm durable outputs, native/OTLP relay, Armis
  inventory, then approved extension records. Each contract compares distinct
  cohorts or a non-writing shadow and removes its JSON/lossy/specialized path
  only after parity; two authoritative projectors never run for one event.
- Remove JSON after the upgraded fleet and each contract's rollback window are
  proven.
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
- The same typed MTR trace contract over the shared route/class lane is the
  target for scheduled, sweep-profile, ad-hoc, and on-demand MTR. Issue #4669
  should converge on this lane rather than
  encode a complete trace as generic metric attributes.
- `add-adhoc-network-scan` MUST replace its `adhoc-scan-metrics` result contract
  with these canonical observation/trace events while preserving `scan_run_id`.
  The `add-sweep-profile-mtr` branch MUST rebase Phase 2 before either dependent
  implementation begins.
- This branch also amends `add-external-inventory-wasm-plugin-contract` from one
  whole-collection `plugin_result.v1` to bounded typed pages plus terminal
  activation while preserving its package-owned provider/configuration boundary.
  It amends `add-event-writer-processor-contributions` so the verified
  output-contract reference inside `EdgeRecordV1`, over fixed platform subjects,
  replaces package-requested subject filters while preserving the approved
  declarative downstream processor vocabulary. The shared durable transport
  does not create a second plugin catalog or give package manifests routing
  authority.
- Embedded inbound sync sources, beginning with Armis, SHALL migrate from JSON
  `StreamStatus` pages to the canonical inventory snapshot contract and common
  producer API. Provider HTTP/pagination code remains a producer adapter.
  Outbound integrations such as the Armis northbound updater remain
  command/job side effects; only their durable progress, audit, telemetry, and
  result records use canonical ingestion contracts.
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
  and outside the durable-record data plane.
- The existing broker-free sync ingestor remains a bounded migration path only.
  New or migrated agent-side inventory producers use the common durable record
  data plane; cluster-local producers MAY publish the same canonical contracts
  directly through a service-attested, contract-scoped governed JetStream
  ingress adapter rather than hairpinning through an agent/gateway. A database
  outbox is only for records whose system of record is that same transaction;
  metrics and telemetry remain JetStream-first.

## Impact

- **Affected specs**: `edge-architecture`, `ingestion-routing`,
  `observability-signals`, `sweeper`, `mtr-diagnostics`, `sweep-jobs`, `cnpg`,
  `agent-connectivity`, `agent-config`, `nats-tenant-isolation`,
  `nats-cross-account-consumption`, `age-graph`, `build-web-ui`, and
  `wasm-plugin-system`, plus the new `edge-producer-data-plane` capability.
- **Affected code**:
  - protobuf definitions and generated Go/Elixir modules;
  - Go sweeper result lifecycle, streaming batch builder, disk spool, and gateway
    client;
  - the agent's built-in producer API, Wasm host ABI/SDK, native add-on gRPC
    contract/SDK, plugin/add-on output grants, and embedded sync runtime;
  - Elixir agent-gateway record RPC, identity attestation, JetStream publisher,
    ACL/configuration, and removal of volatile result buffering for this lane;
  - Elixir core EventWriter streams, partitioned pull consumers, sweep/MTR
    processors, DLQ, ingest ledger, and execution reconciliation;
  - sweep/MTR resources, uniqueness constraints, retention, and rollups;
  - Helm/Docker stream capacity and gateway publisher configuration.
- **Compatibility**: minimum-version, hard-cut cohort migration. Older agents
  are upgraded or assignment-ineligible; only pre-cutover backlog is drained,
  followed by removal of legacy JSON and duplicate agent metric projections.
- **Breaking change**: after each cohort's hard cut and bounded pre-cutover
  backlog drain, sweep/MTR data and migrated durable plugin/add-on/inventory
  outputs no longer use JSON or `GatewayServiceStatus` delivery. Low-volume
  status/control remains compatible.
