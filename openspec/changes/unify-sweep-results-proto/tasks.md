# Tasks: Build the durable edge observation data plane

## 0. Baseline and approve capacity assumptions

- [ ] 0.1 Capture 1k, 10k, 100k, and 1M target fixtures for ICMP plus zero,
  five, ten, and fifty TCP ports, including realistic sparse open ports and
  failures.
- [ ] 0.2 Capture scheduled, sweep-profile, ad-hoc, and on-demand MTR fixtures
  with ECMP, MPLS, ASN, DNS, unreachable targets, partial hops, and maximum
  configured bounds.
- [ ] 0.3 Measure current end-to-end JSON and duplicate `MetricBatch` bytes,
  CPU, allocations, peak RSS, BEAM mailbox/queue bytes, gateway loss behavior,
  NATS traffic, database rows, index/WAL bytes, and query latency.
- [ ] 0.4 Produce and approve a capacity plan for burst rate, supported outage,
  agent spool bytes, JetStream logical and replica bytes per physical stream
  shard, stream/consumer RAFT and connection cardinality, consumer drain rate,
  shared CNPG transaction credits/ingest rate, raw retention, and MTR probe
  budget. Include correctness-metadata retirement bucket width, live partition
  count, row/index-byte ceiling, partition-retirement throughput, exceptional
  hold capacity, and accepted domain-replay horizon.
- [x] 0.5 Archive the unimplemented `add-bulk-payload-pipeline` and revise the
  active `add-adhoc-network-scan` contract to use canonical events.
- [ ] 0.6 Require the `add-sweep-profile-mtr` branch to rebase its Phase 2
  contract before either dependent implementation begins.

## 1. Define versioned wire contracts

- [ ] 1.1 Add the `EdgeResultFrame`, accepted/rejected disposition and resolved
  watermark contracts, lane-opening/session handshake, payload-kind,
  compression, canonical broker headers, projected-row and projected-write-byte
  costs plus a cost-model version, authoritative `network_scope_id`, immutable
  scheduler-signed traffic class, one authorization
  kind/context/range, separate signed collection/delivery capabilities,
  versioned signing/key-rotation metadata, `SpoolLossTombstoneV1`, and structured
  rejection contracts. Use canonical 16-byte UUIDs or strictly validated
  lowercase UUID text for every UUID-backed identifier. Require RFC 9562 UUIDv7
  for every v1/patched-legacy semantic event ID and v1 MTR trace ID; derive the
  metadata retirement bucket and trace identity time from them, validate their
  timestamps against signed collection/execution intervals, and prove in
  cross-language fixtures that an ID cannot change partitions.
- [ ] 1.2 Add compact `SweepObservationBatchV1` and mergeable
  host/ICMP/TCP/MTR-summary messages with exact `(mode, protocol, port)` check
  dictionaries, per-mode revisions/outcomes, per-host observation time,
  plan/range digests, presence, bounds, and stable correlation keys.
- [ ] 1.3 Add `SweepExecutionEventV1` start, progress/watermark, completion, and
  aborted evidence per assignment attempt; an immutable scheduler plan that
  uses a bounded header plus content-addressed range pages for arbitrary target
  sets and contains ranges/checks but not future attempts; and append-only authoritative
  assignment records including scheduler-authored lost/expired/superseded
  terminals, shard/range digests, terminal sequences, counts, expected MTR,
  configuration identity, epoch, lease/fence, and authorization metadata.
- [ ] 1.4 Add lossless `MtrTraceBatchV1` and `MtrTraceEventV1` contracts covering
  every current trace/hop/ECMP/MPLS/ASN/DNS/timing/outcome/source/correlation
  field without generic metric attributes. Require every batch to share one
  network-scope/agent/source/authorization/execution-or-command/range/traffic-
  class context. Define a deterministic content digest over canonical plan
  ordinal/range-block order so completion never depends on arrival order or
  execution-wide trace materialization. Allocate and durably record UUIDv7 trace
  IDs before probing and add cross-language UUIDv7/identity-time fixtures.
- [ ] 1.5 Define compatibility rules for unknown fields/enums, unsupported
  versions, timestamp units, optional zero-valued measurements, ASN range,
  string/count/byte/relational-row bounds, canonical header hashing, streaming
  compression expansion, recursion, and trailing-frame rejection. Define the
  immutable semantic-envelope digest separately from gateway receipt, physical
  placement, spool coordinates, and renewable delivery proof; define broker
  publication identity separately. Make projected row cost cover every
  synchronous ledger/domain/outbox/work/current-state mutation and canonicalize
  nanoseconds to PostgreSQL microseconds before identity/order comparison.
- [ ] 1.6 Generate Go and Elixir modules, update Bazel targets, and add
  cross-language golden fixtures proving byte and semantic compatibility.

## 2. Stream completed observations from the agent

- [ ] 2.1 Refactor sweep execution so completed host windows feed the result
  pipeline continuously while scanning continues; remove full-run result JSON
  construction and delivery ownership from `GetSummary`.
- [ ] 2.2 Implement byte-aware protobuf builders that flush near 256 KiB, never
  exceed 512 KiB, honor short flush timers, and apply secondary 2,000-host and
  128-trace guards plus hard 10,000 sweep-row and 5,000 MTR-row projection
  budgets; group hosts only when their exact attempted-check dictionaries match.
- [ ] 2.3 Emit stable execution start, bounded progress/watermark, completion,
  and aborted evidence, with each data frame independently decodable and useful;
  integrate scheduler lease recovery so an agent crash produces authoritative
  lost/expired/superseded attempt state and retriable remaining coverage.
- [ ] 2.3a Fetch/validate/cache only bounded immutable target-plan pages per
  assignment. Keep CIDR/range inputs compact and forbid an execution-wide target
  array in config, command, agent memory, or terminal evidence.
- [ ] 2.4 Implement an fsynced segmented agent spool that persists encoded bytes,
  event IDs, sequence state, checksums, retry/quarantine state, and survives
  restart without overwriting unacknowledged data; cover record/tail checksums,
  directory fsync, private permissions, never-reused sequence high-water,
  `ENOSPC`, `EIO`, torn-tail recovery, corrupt-segment quarantine, and emergency
  metadata capacity. Implement signed, bounded/chained loss-manifest/new-spool
  rollover with a durable phase journal, one-segment scratch reserve, fsynced
  old-to-new copy watermarks, replacement delivery capabilities, and per-segment
  delete-after-copy ordering. Never enumerate an outage-sized recoverable tail;
  re-enqueue it with stable semantic identity and make affected coverage partial.
  Bind every recovery generation and manifest page immutably, coarsen an
  overlarge manifest to a conservative uncertain scope, and retain both recovery
  journal copies until a signed, consumer-committed `RecoveryResolvedV1` (or its
  idempotent query result) is durable locally. Put every lane, quarantine,
  journal copy, segment/metadata overhead, rollover amplification, and scratch
  reservation under one atomic filesystem byte allocator with an unborrowable
  minimum-free-space floor for recovery/control and terminal evidence.
- [ ] 2.5 Add a bounded bidirectional gRPC sender with independent sweep/MTR and
  reserved recovery-control sequence/credit lanes, cumulative resolved
  watermarks, accepted/rejected dispositions, nonce-fenced opening handshake,
  bounded frame/byte windows, reconnect/replay, stale-session ACK rejection,
  retry backoff, capability negotiation, collection-expiry-safe
  delivery-capability renewal, and permanent-rejection quarantine. Use an
  independent RPC per lane plus separately pooled bulk, interactive, and recovery
  HTTP/2 connections with reserved connection-level windows; test a zero-window
  stalled bulk connection while interactive and recovery frames progress.
- [ ] 2.6 Connect scanner admission to spool and network pressure: pause/defer
  lower-priority or overlapping work at high-water, reserve worst-case bytes per
  target window, cap active result state by bytes, use high/low-water hysteresis,
  stop/abort safely at hard-full, expose pressure, and never claim a scan
  completed durably while required frames remain unresolved. Give raw rejection
  quarantine separate bulk/interactive accounting with an unborrowable
  interactive floor, high-water admission stop, crash-safe move, explicit
  retention/export/operator-deletion workflow, and no silent overwrite.
- [ ] 2.7 Add fair interleaving across network/site scopes, agents, executions,
  and scheduler-attested traffic classes at the agent and site scheduler. Use
  independent sweep-bulk, sweep-interactive, MTR-bulk, MTR-interactive, and
  recovery spool/credit lanes so one large sweep or MTR job cannot monopolize
  the result window; callers cannot promote their own work. Reserve an
  unborrowable interactive agent-execution floor across probe workers, sockets/
  file descriptors, ICMP tokens, DNS concurrency, CPU, spool, and sender credits.
- [ ] 2.8 Emit the small MTR summary on its correlated sweep host and the complete
  trace through `MtrTraceBatchV1` for every producer mode; allow an independently
  revisioned MTR-mode fragment to follow ICMP/TCP without suppressing it, and
  flush rather than mixing different authorization contexts in one trace batch.
  Feed each completed trace directly into the bounded builder/spool and release
  its working memory in scheduled, sweep-profile, ad-hoc, and on-demand paths;
  forbid an interval-wide or execution-wide `[]trace` accumulation.
- [ ] 2.9 Advertise encoder/spool-reader support in Hello and select one sticky,
  mutually exclusive result format per execution from explicit config plus
  gateway durability readiness; do not use a config hash as the gate and never
  emit the duplicate legacy MetricBatch for a v1 execution.

## 3. Make the gateway a durable authenticated relay

- [ ] 3.1 Add the dedicated mTLS bidirectional result RPC and advertise the
  `edge-results:v1` capability only when all required streams are writable.
- [ ] 3.2 Derive installation trust, network scope, agent, gateway, and partition
  authority from the canonical deployment-CA/certificate-subject edge identity
  resolver without
  requiring SPIFFE; locally verify the outer authorization context/range and
  scheduler-signed collection or delivery capability, and reject identity,
  range, generation, expiry, or stale-collection conflicts without a per-frame
  core/DB lookup. Permit stale-epoch immutable replay only under an exact
  event/checksum-bound delivery capability and stamp it for audit-only/fenced
  projection.
- [ ] 3.3 Implement a project-owned JetStream publisher that sends a publish
  request, derives the database semantic digest without spool/partition delivery
  coordinates and `Nats-Msg-Id` from trusted identity plus spool ID/sequence and
  that digest, sets `Nats-Expected-Stream`, parses PubAck, and distinguishes
  capacity, timeout, protocol, and permanent errors. Use separately bounded NATS
  publisher connections/pools for bulk, interactive, and recovery traffic.
- [ ] 3.4 Publish the inner protobuf bytes without domain decode/re-encode and
  persist both immutable-semantic and full delivery/placement envelope digests;
  bound asynchronous publication by frame count, encoded bytes, and measured
  retained gateway memory including decoded envelope terms, pinned binaries,
  encoded headers, NATS request state, mailboxes, and TLS buffers.
- [ ] 3.5 Return durable accepted/rejected dispositions and advance only the
  contiguous resolved prefix after primary-stream or audit-DLQ PubAck; withhold
  progress on NATS unavailability, stream refusal, or publisher saturation.
- [ ] 3.6 Ensure this lane never enters `StatusBuffer`, never acknowledges an
  ERTS/Core NATS handoff as durable, and remains stateless across restarts.
- [ ] 3.7 Add byte-bounded fair queues and rate limits across network/site scope,
  agent, execution, and attested traffic class so a noisy stream cannot starve
  other edge sessions before JetStream partitioning. Preserve separate bulk,
  interactive, and recovery credits through every gateway queue.

## 4. Provision the JetStream durability boundary

- [ ] 4.0 Reconcile runtime NATS provisioning with the completed single-customer
  control-plane split: audit and remove customer-prefixed runtime subjects,
  per-customer accounts/capacity cells, shared-platform imports/mirrors, database
  routing from subject prefixes, and synthetic `default`-customer inference.
  Seal and drain any declared legacy prefixed backlog under an explicit watermark;
  quarantine ambiguous records rather than inventing authority.
- [ ] 4.1 Add fixed installation-local, versioned sweep-bulk,
  sweep-interactive, MTR-bulk, MTR-interactive, result-recovery, and
  class-preserving result-DLQ subjects with 64 stable logical data/DLQ
  partitions and documented versioned hashes. Define a complete non-overlapping
  `(traffic_class, kind, pNN) -> physical stream` map shared by gateways and
  consumers, exact subject/credential ACLs, installation admission quotas, and
  no authoritative cross-account result mirror/import. `network_scope_id` is a
  signed site/address namespace, not a broker-account or capacity-cell key.
- [ ] 4.2 Provision separate file-backed sweep/MTR physical stream shards plus a
  capacity-reserved recovery stream and scheduler-repair durable, with RAFT
  placement from benchmarked per-stream limits, production replication, a 512
  KiB encoded-body limit plus explicit bounded NATS-header allowance,
  `LimitsPolicy`, `DiscardNew`, capacity from the aggregate admitted arrival
  envelope over outage plus worst-case catch-up plus margin, and separately
  capacity-reserved, class-separated partitioned DLQ streams large/fast enough
  for full admitted source
  rate over the poison detection/pause interval plus in-flight overlap. Disable
  DLQ `MaxAge`; use `MaxBytes` with `DiscardNew`, a poison circuit, and explicit
  catalog-state-aware deletion so unresolved poison never expires silently.
  Add per-shard/aggregate poison circuit breakers, gateway and consumer stable
  rejection IDs, and least-privilege ACLs. Fail readiness for missing/overlapping
  subject authority and define a versioned stop/revoke/seal/new-authority barrier
  that keeps old consumers draining through final redelivery/repair. Size every
  physical shard for its worst-case assigned arrival envelope/hash skew and
  place leaders/replicas across intended failure domains.
- [ ] 4.3 Define the authoritative durability domain for hub and NATS-leaf
  deployments, including whether any edge-local stream may acknowledge data and
  its explicit replication/site-loss RPO.
- [ ] 4.4 Provision initially one shared persistence durable per physical stream
  shard/schema version with byte-bounded pulls, bounded ack-pending, unlimited
  transient redelivery, bounded backoff, and systemic-failure pull pause. Permit
  any replica to process any logical key, including concurrent redelivery, and
  make database guards authoritative instead of local ownership/handoff. Bulk
  and interactive SHALL use disjoint physical streams and persistence durables,
  including the smallest supported deployment. Cap installation-wide streams,
  consumer RAFT groups, NATS connections, processes, and backlog; stop new bulk
  admission before the bounded interactive latency SLO is threatened.
- [ ] 4.5 Add dashboards and alerts for PubAck latency/errors, stream bytes and
  oldest age, per-physical-stream leader/replica placement and throughput, total
  stream/consumer/connection cardinality, lag, ack-pending, redelivery, consumer
  drain rate, recovery-record lag/state, shared CNPG credits/pool/lock/WAL
  pressure, per-shard/aggregate DLQ rate/ratio/circuit/capacity, agent spool and
  quarantine pressure by original traffic class, interactive latency under bulk
  catch-up, projected retention exhaustion, correctness-metadata row/index bytes,
  oldest retirement bucket, partition-retirement lag/rate, acceptance watermark,
  exceptional hold count/bytes, and metadata-budget admission stops.

## 5. Implement replay-safe domain projectors

- [ ] 5.1 Add strict envelope/domain decoders that validate version, checksum,
  canonical broker headers/digest, actual streaming-decompression output and
  ratio, trailing frames, protobuf depth, projected rows, count/string/byte
  bounds, observation time against the original signed collection interval plus
  attested clock tolerance (not a symmetric gateway-receipt age window), one
  homogeneous MTR authorization context, decoded execution/check/command/range
  equality, and every target's authoritative plan/range membership before
  allocating or writing. Persist and independently verify bounded canonical
  collection capability bytes/key ID, and reject missing verification state.
- [ ] 5.2 Add a retirement-bucket-partitioned ingest ledger keyed by trusted
  metadata bucket, network scope, authenticated agent, payload kind, and stable
  event ID, with body checksum and semantic-envelope
  digest stored and immutably compared, plus network-scope-prefixed database
  uniqueness constraints for sweep observations, MTR traces/hops, execution
  plans/events, and deterministic OCSF events. Make sweep history use a trusted
  scheduler-execution-derived `identity_time` partition key and unique logical
  history key so replays/conflicts always meet in one chunk; do not add a
  permanent per-host identity side table. Add a bucketed delivery-slot binding on
  network scope/agent/lane/spool/sequence,
  and a sweep batch-slot constraint on network scope/execution/shard/epoch/batch-sequence that
  binds event ID, checksum, counts, and projected rows. Keep the first
  authenticated committed binding immutable, DLQ later conflicts, mark the
  attempt integrity-failed, exclude both protocol-invalid alternatives from
  authoritative completion, and fence/retry its range before reconciliation.
  Add an immutable per-attempt terminal slot that closes exactly `[1,N]` and
  rejects conflicting terminals or batches outside the closed interval.
- [ ] 5.3 Implement horizontally partitioned sweep consumers that preserve each
  micro-batch as an independent idempotency unit while adaptively grouping
  compatible messages in bounded aggregate transactions. Perform bounded bulk authoritative
  CNPG/DIRE identity resolution, merge revisions per agent/mode with a stable
  observation-time order, preserve canonical availability-source and mapper
  promotion semantics, use `AckExplicit` (never `AckAll`), and individually ACK
  each message only after its containing transaction commits. Roll back and
  boundedly split/isolate a group on deterministic conflict. Before every pull,
  reserve worst-case encoded/resident bytes, projected write bytes, and rows per
  message plus transaction-concurrency slots per concurrently active aggregate
  transaction from a fenced/expiring
  installation-level CNPG result-data-plane grant; after decode refund to
  verified actual cost and hold credits
  through the bounded queue/disposition. Add bounded `AckWait` progress/deadline
  behavior. Reuse a slot for a sequential split only after confirmed rollback;
  require another slot for a parallel subgroup and enforce a separate destination
  commit-rate/fsync budget. Bound source, graph, reconcile, recovery, DLQ indexing/redrive,
  rollup, and repair writers together, with reserved progress subpools whose sum
  and rolling lease overlap never exceed Repo/WAL/lock/resident-byte/write-byte/
  commit-rate measurements. Partition the installation hard
  connection/write budget into explicit results, sync, control/API/Oban, and
  background/maintenance pools whose maxima plus reserve fit the database.
  Recheck the fenced grant immediately before commit, retain expired capacity
  until backend cancellation/session death is proven, and use one canonical
  table/row lock order with sorted bulk keys across all result writers.
- [ ] 5.4 Implement separate MTR consumers that preserve complete trace fidelity,
  derive `trace_identity_time` from the validated RFC 9562 UUIDv7 trace ID, bind
  expected summary context/target in both arrival orders using only bounded
  partitioned expectations, uniquely persist `(trace_identity_time,
  network_scope_id, trace_id)` in `mtr_traces`/`mtr_hops` without a permanent
  per-trace side table, and atomically enqueue a unique
  graph-outbox row before ACK. Add a bounded idempotent normalizer that atomically
  expands each parent into deterministic vertex/edge observation tasks plus an
  expected count/digest. Route tasks by an immutable versioned topology-identity
  owner map whose hash and shard count are fixed within the version,
  require endpoint vertex completion before an edge is eligible, and allow only
  one fenced owner generation per shard. Implement the bounded AGE fold so
  class-fair batches coalesce common identities and set-oriented graph MERGEs,
  watermarks, and represented-task success commit together; mark the parent
  complete only when all expected tasks resolve. Persist the immutable traffic
  class on outbox work and use class-aware subqueues/weighted-fair bounded claims
  plus the interactive reserved credit floor. Store bounded
  immutable projection input (or a content-addressed non-hypertable payload),
  not a pointer to expiring chunks; use network-scope-prefixed HopNode and
  network-scope/agent/protocol/endpoints/path-variant edge identity, monotonic
  `(observed_at, trace_id)` property updates, scope-safe prune/query, retry/
  repair audits, and graph-lag admission alerts. Require AGE edge drain above
  admitted live rate plus catch-up. Benchmark near-total common-backbone vertex/
  edge overlap and fail rollout if stable-owner coalescing cannot meet the bound.
  Advance each relational prune tombstone/watermark and delete its AGE edge in
  the same fenced transaction. Implement a stop-expand/fence/drain-or-atomic-
  migrate barrier for owner-map changes; retain map history through repair/prune/
  rollback and never let old/new owners mutate one identity concurrently.
- [ ] 5.5 Reconcile execution progress/completion from unique committed batch
  sequences, immutable plans, and authoritative attempt terminal state/evidence;
  expose scanner, delivery, projection, MTR pending/missing/quarantined, partial,
  aborted, and late-completing states rather than treating transport disconnect
  as completion. Persist per-shard evidence in message transactions and update
  parent execution summaries through append-only per-event reconcile work,
  class-aware fixed hash-partitioned queues, fenced/expiring queue leases,
  bounded grouping, reserved interactive claims/credits,
  processed-work commit, and anti-entropy repair--not one parent or substitute
  `(network_scope, execution)` dirty-row update per batch. Emit deterministic immutable
  observation events; generate lifecycle transitions only through an event-time
  watermark reconciler with explicit provisional and late-correction semantics.
- [ ] 5.6 Implement the idempotent recovery consumer keyed by network-scope/agent/
  recovery-ID/page/abandoned-spool/lost-range/manifest digest. Persist chained
  pages idempotently, validate the bounded terminal copy manifest, then in one
  transaction persist the loss audit, mark affected attempts/ranges partial or
  lost, fence unsafe authority, and enqueue scheduler retry intent before ACK;
  retain durable state and alert if recovery-stream expiry approaches. After
  commit, expose/emit a signed idempotent `RecoveryResolvedV1` bound to recovery
  ID, manifest root, and applied state; a recovery-stream PubAck alone MUST NOT
  authorize agent journal deletion.
- [ ] 5.7 Copy poison events and diagnostics to the durable DLQ, wait for its
  PubAck, and only then terminate the source delivery; use a stable network-scope/
  source-sequence/checksum/error-class DLQ ID and retry ambiguous acknowledgments.
  Use a separate trusted agent/spool/fingerprint/rejection ID before primary
  publication. Pause/retry transient or valid-newer-schema deployment failures
  without a finite delivery ceiling. Add a bounded `result_dlq_record` catalog
  keyed by DLQ ID plus physical stream/sequence, explicit unresolved/resolved/
  redriven/waived states, and an authorized deleter that removes only resolved
  catalogued sequences. Redrive through a synthetic durable lane with new
  delivery coordinates/publication ID while preserving exact trusted envelope,
  semantic identity, original traffic class, and source provenance.
- [ ] 5.8 Derive required low-cardinality execution/scanner/availability/trace
  metrics from the canonical event without recreating per-host/per-hop generic
  metric expansion.
- [ ] 5.9 Add bounded current-state, raw-history, execution-summary, and rollup
  storage/retention paths and verify queries do not require execution-wide
  materialization. Preserve operator-controlled MTR retention within safe bounds;
  migrations/control-plane reconciliation, never EventWriter, own policy DDL.
  Define finite replay horizons and trusted retirement buckets for delivery-slot/
  ledger/batch-slot/terminal-slot/expectation/outbox/reconcile state, then retire
  ordinary metadata by whole partition. Add bounded `correctness_hold` records
  for unresolved DLQ/recovery/rollback/repair with semantic digest, class, source
  locator, state, domain-replay deadline, and complete bounded replay/projection
  input inline or in a checksummed content-addressed payload owned by the hold.
  Before partition drop, atomically move inline unresolved graph/outbox/task input
  into held storage or pin its payload; never retire on a digest alone. Reject non-held work below the
  acceptance watermark as `replay_horizon_expired`; after the replay deadline,
  permit audit/partial/recollection resolution only. Enforce hard metadata row/
  index-byte and held-payload byte budgets that stop new scan admission before
  exhaustion.

## 6. Integrate scheduling and all MTR producers

- [ ] 6.1 Update `add-sweep-profile-mtr` Phase 2 so its full trace uses
  `MtrTraceBatchV1`; preserve only the small `MTRStatus`/trace-ID summary on the
  sweep host.
- [ ] 6.2 Migrate scheduled, sweep-profile, ad-hoc, and on-demand MTR producers
  to the same trace contract, map ad-hoc `scan_run_id` through the canonical
  execution/source key into `adhoc_scan_results`, and remove direct JSON/database
  and lossy `MetricBatch` trace paths after parity. Verify every producer feeds
  each completed trace into the bounded builder/spool and releases it rather
  than retaining a run- or interval-wide result slice.
- [ ] 6.3 Add deterministic scan shards and per-site/global MTR target,
  trace/probe-rate, concurrency, duration, interval-overlap, backlog, and
  storage admission budgets, including monotonic assignment fencing for
  reassigned target ranges.
- [ ] 6.4 Add baseline sampling/rotation, critical-target selection, and
  anomaly/incident-triggered MTR policies so fleet-wide deep tracing is an
  explicit capacity decision rather than an hourly default.
- [ ] 6.5 Preserve on-demand command/control responses as lightweight status and
  trace correlation; persist the full result only through the canonical MTR
  event lane, and update the UI to resolve the trace after EventWriter commit
  with pending, failed, quarantined, and timeout states.

## 7. Roll out and retire legacy paths

- [ ] 7.1 Deploy additive schema, database identity/slot keys, class-separated
  streams/consumers/DLQ, and gateway support. Enforce a minimum dual-path agent
  and gateway version before assigning new work; do not build an unpatched-agent
  compatibility bridge. Change the patched legacy sender to send and acknowledge
  one stable signed frame no larger than 512 KiB instead of a cumulative request.
  Backfill authoritative network scope and partition-local identity times from
  site/agent ownership online behind
  durable source high-water marks, quarantine ambiguity/collisions, populate
  sweep/MTR identity keys without per-observation side tables, capture concurrent
  legacy writes behind a durable CDC cursor, and continuously apply them while
  backfill runs. Enforce a hard delta byte/age budget that slows/stops new legacy
  scan admission before overflow and require catch-up to a configured bounded
  tail before the barrier. Rebuild a versioned scope-safe graph through the canonical
  outbox. Complete and validate historical parity before an installation ingress-
  epoch barrier. Inside that short barrier, stop scan admission, fence and drain
  every legacy ERTS/direct writer, persist final per-scope/agent watermarks, drain
  and validate only the bounded delta, then enable only the PubAcked JetStream/
  EventWriter path. Never run an unbounded historical scan/rewrite inside the
  admission pause.
  Prove read/graph parity before switching reads; retain the patched bounded
  JetStream legacy path solely for rollback until the declared window closes.
- [ ] 7.2 Canary by explicit agent/cohort configuration and compare event counts,
  execution totals, current device state, OCSF rows, scanner/banner metrics,
  MTR/AGE field fidelity, mapper promotion, per-agent availability, ad-hoc rows,
  latency, memory, lag, storage, network-scope-safe UI/SRQL reads, and retained-history
  graph parity against a non-writing legacy shadow.
- [ ] 7.3 Exercise the supported minimum-version and offline-agent upgrade window;
  older binaries receive no new assignments. Keep rollback consumers until all
  stream backlog and agent spools are drained. Rollback changes only
  new-execution selection and retains a compatible v1 spool reader/sender until
  existing lanes drain.
- [ ] 7.4 Remove agent-side duplicate sweep/MTR metric projections only after
  real-time consumer and persistence parity is demonstrated.
- [ ] 7.5 Remove legacy JSON `GatewayServiceStatus{source: "results"}` emission,
  decode, ERTS routing, and volatile fallback only in a separately gated
  cleanup release.
- [ ] 7.6 Update architecture, operations, capacity, installation-local NATS,
  network-scope identity, result-state, and failure-recovery documentation after
  the conflicting active proposals are
  withdrawn/rebased in task 0.5.

## 8. Verify correctness, scale, and failure behavior

- [ ] 8.1 Add unit, fuzz, property, and cross-language tests for sizing,
  boundaries, unknown versions, corrupt checksums, decompression bombs,
  identity spoofing, sequencing, cumulative dispositions, spool recovery,
  changed bytes or schema/row-cost/epoch/authorization/range semantic headers
  under one event ID inside and outside the broker dedup window,
  conflicting batch-slot bindings in both arrival orders with immutable
  conflict state, exclusion of protocol-invalid alternatives, and fenced repair,
  delivery-slot reuse with changed semantics, terminal-slot conflicts and data
  outside a closed `[1,N]`, collection/delivery proof
  expiry and fencing, out-of-range targets, mixed-context MTR batches,
  crash-before-terminal scheduler repair, bounded paginated corrupt-middle-record
  tombstone and crash at every copy/fsync/PubAck/delete rollover boundary near a
  full spool, semantic replay under changed spool coordinates, same trace ID
  across different Timescale chunks or target/execution bindings, sweep semantic
  identity replay across different Timescale chunks, graph failure after source
  commit/outbox repair, identical private hops in distinct network scopes,
  newer-then-older graph projection, crash after evidence commit before
  reconcile notification, reconciler crash/generation race, old-valid backlog
  timestamp acceptance and future-time quarantine, torn spool tails,
  `ENOSPC`/`EIO`, quarantine exhaustion, per-mode out-of-order merges,
  equal-timestamp ordering, permutation-equivalent observation/transition event
  sets, nanosecond/microsecond boundaries, malformed/noncanonical UUIDs and
  network-scope IDs, exact check dictionaries, complete projected-row/write-byte
  cost fixtures,
  canonical headers, capability rotation/revocation, and deterministic IDs.
- [ ] 8.2 Add integration tests for continuous scan/data/completion interleaving,
  mixed agents, gateway/NATS/core/CNPG restarts, PubAck loss, five forced
  redeliveries, a greater-than-64-MiB patched legacy execution carried as
  independent frames no larger than 512 KiB, minimum-version assignment
  rejection, gateway/consumer poison DLQ PubAck loss, bulk poison at DLQ and
  quarantine capacity while an interactive failure still obtains its reserved
  disposition path, fleet-wide bad-decoder circuit/pause/repair/redrive,
  indefinite transient retries, stale sessions/assignments, key rotation with
  queued frames, stale-gateway installation stream-map migration, concurrent
  zero-window bulk RPC/NATS publisher saturation while separately connected
  interactive and recovery traffic progress, maximum-header/compression frames
  with delayed PubAcks and measured retained gateway memory, concurrent
  same-key replicas, maximum admitted bulk catch-up while interactive ingest,
  reconcile, graph, and terminal latency remain bounded, two-stage credit lease
  crash/scale overlap and commit fencing, reverse-order concurrent result writers
  proving canonical lock ordering, concurrent sync/API/Oban/background load,
  recovery PubAck without/lost/delayed `RecoveryResolvedV1`, DLQ catalog redrive/
  waiver/deletion, correctness-partition retirement with an unresolved inline
  graph task and held-payload recovery, graph owner-map drain/migration fencing,
  MTR expectation-binding gaps in both arrival orders,
  cross-network-scope negative reads, retention-boundary catch-up, and partial
  execution repair.
- [ ] 8.3 Prove zero acknowledged loss and zero duplicate domain/OCSF/MTR rows,
  p99 durability under 2 seconds, p99 queryability under 30 seconds, and at
  least twice-live backlog drain capacity. Define and prove a separate bounded
  end-to-end interactive SLO while bulk streams, reconciliation, graph projection,
  DLQ, and database credits operate at their maximum admitted catch-up load.
- [ ] 8.4 Benchmark the full matrix through 1M hosts and a 72-hour soak; require
  at least 10,000 host observations/second aggregate on a fully documented
  reference topology, a 1M-host ten-port drain within 6 minutes, bounded result
  RSS below 256 MiB independent of scan size, measured domain-row/WAL rates, no
  hot reconcile tuple/index page, AGE edge drain above live-plus-catch-up with
  bounded lag/lock/WAL cost, and an approved MTR throughput/storage budget. Add
  an accelerated long-horizon churn/capacity test for delivery/ingest/batch/
  terminal/sweep/MTR identity, outbox, work, recovery, DLQ catalog, stream-map,
  plan/fence/key metadata, and watermark GC. Include worst-case timer-fragmented
  frames from 1,000 low-rate agents and record messages/second, transactions/
  second, rows/transaction, commit fsyncs, and WAL per observation for adaptive
  grouping versus one-message transactions; fail if fragmentation breaks the
  ingest or interactive-latency gate. Prove correctness rows/index bytes converge
  to a bounded sawtooth/plateau under partition retirement plus configured holds;
  linear steady-state growth or bulk row-delete/vacuum cleanup fails the gate.
- [ ] 8.5 Run Go, Elixir, database, and Bazel suites for all touched targets and
  `openspec validate unify-sweep-results-proto --strict`.
