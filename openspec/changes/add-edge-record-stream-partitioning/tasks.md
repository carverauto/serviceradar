# Tasks: Partition the edge-record streams and add the durable DLQ and retention

## 1. Moved from `unify-sweep-results-proto`

Each task keeps its original text and number from `unify-sweep-results-proto`; its last line states what remained
when it moved.

- [ ] 1.1 (was `unify-sweep-results-proto` 4.0) Reconcile runtime NATS provisioning with the completed single-customer
  control-plane split: audit and remove customer-prefixed runtime subjects,
  per-customer accounts/capacity cells, shared-platform imports/mirrors, database
  routing from subject prefixes, and synthetic `default`-customer inference.
  Seal and drain any declared legacy prefixed backlog under an explicit watermark;
  quarantine ambiguous records rather than inventing authority.
  Remaining as of the move (2026-11-02): low confidence: not audited in this
  reconciliation.
- [ ] 1.2 (was `unify-sweep-results-proto` 4.1) Add fixed installation-local, versioned platform route-profile plus
  bulk/interactive, result-recovery, and class-preserving result-DLQ subjects
  with 64 stable logical data/DLQ
  partitions and documented versioned hashes. Define a complete non-overlapping
  `(traffic_class, route_profile, pNN) -> physical stream` map shared by
  gateways and
  consumers, exact subject/credential ACLs, installation admission quotas, and
  no authoritative cross-account result mirror/import. `network_scope_id` is a
  signed site/address namespace, not a broker-account or capacity-cell key.
  Remaining as of the move (2026-11-02): follow-up; today there is one
  `TELEMETRY_EDGE_RECORD_V1_BULK` stream.
- [ ] 1.3 (was `unify-sweep-results-proto` 4.2) Provision separate file-backed physical stream shards by the finite
  platform route-profile/class map plus a capacity-reserved recovery stream and
  scheduler-repair durable, with RAFT
  placement from benchmarked per-stream limits, production replication, an encoded-body
  limit of the ABI-frozen `MaxRecordBytes` plus an explicit bounded NATS-header
  allowance,
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
  Remaining as of the move (2026-11-02): follow-up; replication of the edge stream is
  `move-agent-telemetry-to-edge-records` task 1.4.
- [ ] 1.4 (was `unify-sweep-results-proto` 4.3) Define the authoritative durability domain for hub and NATS-leaf
  deployments. The gateway remains the sole NATS publisher for agent-originated
  records and plugins/add-ons receive no NATS credentials. Document whether an
  edge-local stream may produce the authoritative PubAck and its explicit
  replication/site-loss RPO; do not call a leaf PubAck durable if the admitted
  RPO requires hub replication first.
  Remaining as of the move (2026-11-02): follow-up (see
  `add-hosted-edge-leaf-connectivity`).
- [ ] 1.5 (was `unify-sweep-results-proto` 4.4) Provision initially one registry-dispatching shared persistence durable
  per physical stream shard/route profile with byte-bounded pulls, bounded
  ack-pending, unlimited
  transient redelivery, bounded backoff, and systemic-failure pull pause. Permit
  any replica to process any logical key, including concurrent redelivery, and
  make database guards authoritative instead of local ownership/handoff. Bulk
  and interactive SHALL use disjoint physical streams and persistence durables,
  including the smallest supported deployment. Cap installation-wide streams,
  consumer RAFT groups, NATS connections, processes, and backlog; stop new bulk
  admission before the bounded interactive latency SLO is threatened.
  Remaining as of the move (2026-11-02): one shared EventWriter durable on the edge
  stream. Disjoint bulk and interactive streams and the cardinality caps are not
  built.
- [ ] 1.6 (was `unify-sweep-results-proto` 4.5) Add dashboards and alerts for PubAck latency/errors, stream bytes and
  oldest age, per-physical-stream leader/replica placement and throughput, total
  stream/consumer/connection cardinality, lag, ack-pending, redelivery, consumer
  drain rate, recovery-record lag/state, shared CNPG credits/pool/lock/WAL
  pressure, per-shard/aggregate DLQ rate/ratio/circuit/capacity, agent spool and
  quarantine pressure by original traffic class, interactive latency under bulk
  catch-up, projected retention exhaustion, correctness-metadata row/index bytes,
  oldest retirement bucket, partition-retirement lag/rate, acceptance watermark,
  exceptional hold count/bytes, and metadata-budget admission stops.
  Remaining as of the move (2026-11-02): M3.4's four signals landed (#6193); the rest
  of the list remains.
- [ ] 1.7 (was `unify-sweep-results-proto` 4.6) Give cluster-local durable producers the same canonical
  contract/registry/projector rules through a least-privilege direct publisher
  or transactional outbox. Do not hairpin them through an agent/gateway and do
  not let this exception become an arbitrary subject or direct-to-CNPG metric
  path. A governed service publisher uses its OWN isolated service-ingress subject
  and credential (only an authorized governed service may publish to it), and stamps
  the SERVICE variants of the three transport transcripts over its `service_slot`.
  Those variants -- their domain tags, slot kind, framed members, and delivery-proof
  presence rule -- are the ABI-frozen grammars from task 1.14 and are NOT restated
  here. Because governed publishers emit FRESH records only, the publisher stamps no
  delivery proof and a receiver SHALL NOT treat its absence as poison. Assert the
  stamped headers against the ABI-owned service-slot vectors; do NOT generate a
  second corpus.
  The governed service publisher (or its transactional outbox/journal) OWNS its
  `publication_lane_id`, `publication_sequence`, pending exact record bytes, retry
  state, and their ATOMIC allocation -- NOT the gateway or EventWriter: allocate
  `publication_lane_id` as a 16-byte UUIDv7 ONCE, durably, before first publication;
  for EACH record, ATOMICALLY allocate the NEXT `publication_sequence` and journal the
  exact bytes + immutable route/header state BEFORE publishing (sequence allocation is
  NOT gated on a PubAck, so publishes MAY pipeline multiple outstanding sequences); a
  validated PubAck only RESOLVES/RECLAIMS its journaled slot. REUSE the same
  `(publication_lane_id, publication_sequence)` with the exact pending bytes after a
  retry/timeout/restart so a lost-ACK redelivery deduplicates. `publication_sequence`
  MUST NEVER wrap: on approaching the maximum sequence, SEAL and DRAIN the current lane
  while allocating NEW work on a fresh UUIDv7 `publication_lane_id` restarting at 1.
- [ ] 1.8 (was `unify-sweep-results-proto` 5.2) Add a retirement-bucket-partitioned ingest ledger keyed ONLY by
  (network scope, stable event ID) -- the retirement-metadata bucket derived
  from the event ID for physical partitioning only -- with authenticated agent,
  exact output-contract bundle, and `record_sha256` stored (physical-slot value
  only) and `semantic_envelope_sha256` stored and immutably compared for
  replay-vs-conflict (never in the key), plus network-scope-prefixed database
  uniqueness constraints for sweep observations, MTR traces/hops, execution
  plans/events, and deterministic OCSF events. Make sweep history use a trusted
  scheduler-execution-derived `identity_time` partition key and unique logical
  history key so replays/conflicts always meet in one chunk; do not add a
  permanent per-host identity side table. Add a bucketed delivery-slot binding on
  network scope/agent/spool/sequence that immutably binds the record
  checksum `record_sha256`, event ID, and `semantic_envelope_sha256` (rejecting a
  later frame on the same slot whose `record_sha256` differs as a
  transport-integrity violation), and a sweep batch-slot constraint on network
  scope/execution/shard/epoch/batch-sequence that
  binds event ID, `semantic_envelope_sha256`, counts, and projected rows. Keep the first
  authenticated committed binding immutable, DLQ later conflicts, mark the
  attempt integrity-failed, exclude both protocol-invalid alternatives from
  authoritative completion, and fence/retry its range before reconciliation.
  Add an immutable per-attempt terminal slot that closes exactly `[1,N]` and
  rejects conflicting terminals or batches outside the closed interval.
  Create the ledger and every slot table (delivery-slot, sweep-batch-slot,
  agent-terminal-slot, and service-ingress-slot) range-partitioned by
  `(ordered_time_bucket, hash_subshard)`. `ordered_time_bucket` is the slot's
  epoch coordinate (delivery-slot = spool generation epoch; sweep-batch-slot and
  agent-terminal-slot = assignment epoch; service-ingress-slot = publication
  epoch; the event ledger keeps its `event_id` UUIDv7-timestamp window unchanged)
  floored to a fixed retention window, so it is CHRONOLOGICALLY ORDERED and a
  whole expired window retires by a single range `DROP`/detach, never a hash scan.
  `hash_subshard` is the low N bits (fixed width, e.g. 8 bits -> 256 subshards) of
  SHA-256(slot-tuple) (delivery-slot = hash(edge_slot); sweep-batch-slot and
  agent-terminal-slot = hash(scope, execution, shard); service-ingress-slot =
  hash(service_slot)) to spread write load WITHIN a window. Add a
  chronological-DROP retirement job that retires whole expired ordered-time
  windows by range drop/detach.
  PARTIALLY LANDED: commit `0d3940cbe1` added the
  minimum slice ledger (migration `20260910120000_create_edge_record_ledger`:
  `event_ledger`, `edge_delivery_slots`, `edge_sweep_batch_slots`,
  `edge_sweep_projected_rows`) and the idempotent
  `ServiceRadar.EventWriter.Processors.EdgeRecord` writer. None of those tables is
  bucket- or range-partitioned, and there is no terminal slot, service-ingress
  slot, or retirement job, so this task stays unchecked.
  Remaining as of the move (2026-11-02): unchanged: the tables are not partitioned,
  and there is no terminal slot, service-ingress slot or retirement job.
  Interim (#6427): `ServiceRadar.Edge.EdgeLedgerRetentionWorker` prunes expired
  rows from the four unpartitioned tables by bounded batched `DELETE`. It is
  not the chronological range-`DROP` retirement job this task requires.
- [ ] 1.9 (was `unify-sweep-results-proto` 5.3) Implement horizontally partitioned sweep consumers that preserve each
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
  Remaining as of the move (2026-11-02): the canary projection (M2.3) is one
  transaction per record; partitioned consumers, aggregate transactions and CNPG
  credit grants remain.
- [ ] 1.10 (was `unify-sweep-results-proto` 5.7) Copy poison events and diagnostics to the durable DLQ, wait for its
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
  Remaining as of the move (2026-11-02): the catalog, states, deleter and redrive
  remain a follow-up. The security-quarantine stream and the minimal generic
  dead-letter in the notes below are the only DLQs that exist; task 3.5's other
  routes still depend on the rest.
  MINIMAL INSPECTION LANDED for the security-quarantine route only: its stream
  keeps every record (`MaxAge` disabled, `DiscardNew`), an EventWriter consumer
  logs each one with its stream sequence and slot and writes nothing, the
  stream's retained bytes are polled so `ServiceRadarEdgeRecordSecurityQuarantine`
  fires on any held record, and `docs/edge-record-quarantine-runbook.md` gives
  the `nats stream get` path. The catalog, stable DLQ IDs, states, deleter and
  redrive above remain open.
  OPERATOR ACTIONS LANDED (#6421): Settings -> Cluster "Dead letters" groups the
  held dead letters by contract and reason from the stream itself and replays or
  purges a group, for `settings.edge.manage` and audited on the coordinator when
  it starts and when it ends (`Replay.operator_action/3`, resource
  `edge_record_dead_letters`). A purge is an operator's waive decision: until the
  catalog exists the audit event is its only record, and it deletes message by
  message because the core identity is denied purging the stream. The catalog,
  stable DLQ IDs, states and synthetic-lane redrive remain open.
  MINIMAL GENERIC DEAD-LETTER LANDED (2026-11-02, epic #6271) for EventWriter
  projection failures of every contract: at the edge-record stream's
  `dead_letter_after_deliveries` threshold (lowered to `max_deliver - 1`) the
  record's original bytes and transport headers plus `Sr-Edge-Dlq-*` failure
  headers go to `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK`
  (`telemetry.edge-record-dlq.v1.bulk.pNN.<contract>.v<version>`, R3, limits,
  `DiscardNew`, `MaxAge` disabled) with a PubAck, and only then is the source
  ACKed; a refused copy leaves the source NAKed with backoff
  (`ServiceRadar.EventWriter.EdgeRecordDeadLetter`). A counter by contract and
  reason, three managed alerts, `EdgeRecordDeadLetter.Replay` (republish to the
  source subject, idempotent through the ledger) and
  `docs/edge-record-dead-letter-runbook.md` cover inspection and replay. The
  gateway-side poison DLQ, the `result_dlq_record` catalog, its states, the
  authorized deleter, the synthetic redrive lane and the pause-without-ceiling
  policy for transient failures remain open here. This change owns them, and
  they SHALL subsume the minimal dead-letter rather than run beside it.
- [ ] 1.11 (was `unify-sweep-results-proto` 5.9) Add bounded current-state, raw-history, execution-summary, and rollup
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
  exhaustion. Add an integration test proving (a) whole-window retirement drops
  old delivery-slot/sweep-batch-slot/agent-terminal-slot/service-ingress-slot and
  ledger partitions by a single ordered-time-window range drop/detach WITHOUT
  touching current-window partitions, and (b) newly bound slots in the current
  window land in the correct `hash_subshard`.

## 2. Validate

- [ ] 2.1 Run the Go, Elixir and Bazel suites for every touched target and
  `openspec validate add-edge-record-stream-partitioning --strict`.
