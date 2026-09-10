# Tasks: Build the durable extensible edge producer data plane

> **ACTIVE WORK-ORDER GATE:** Until task 0.12 is checked, implementation and
> review SHALL follow its scope and the review contract in `design.md`. An
> unchecked task elsewhere in this file remains owed; it does not become a
> prerequisite merely because it is nearby or more general.

## Active milestone coordination gate

- [ ] 0.12 **FIRST GREEN VERTICAL SLICE -- ACTIVE MILESTONE AND SCOPE FREEZE.**
  Drive ONE committed BULK `SweepObservationBatchV1` fixture on ONE valid durable
  route through the REAL composed path:

  ```text
  record -> agent spool -> mTLS gRPC -> gateway -> JetStream PubAck
         -> EventWriter -> idempotent CNPG transaction -> query
  ```

  This is a COORDINATION AND ACCEPTANCE task. It owns work order and the composed
  acceptance target; tasks 2-5 retain semantic ownership of spool, transport,
  gateway, publication, and projection behavior. Closing this task does not
  close those parent tasks or the ABI freeze.

  IN-SCOPE IMPLEMENTATION is limited to: the minimum production sender over the
  existing agent spool; task 3.3's restart-overlap and post-handoff
  request-fencing defects; the `EdgeRecordIngestService.Stream` caller/server
  and validation needed by this fixture; one real JetStream route, stream, and
  durable consumer; the Sweep record decoder plus the minimum ingest ledger,
  immutable delivery-slot and sweep-batch-slot bindings, and atomic domain
  projection; and introduction and registration of the exact Bazel target
  `//integration_tests/edge_record:vertical_slice_test`. That target does not
  exist yet; this milestone SHALL create it using real NATS and a scratch CNPG
  database and run it in the required `BazelCI` check. Required CI or
  migration-baseline repair MAY land in a separate enabling PR so the target can
  run; it SHALL NOT broaden the slice.

  "REAL composed path" means the target starts the production supervision and
  configuration, provisions the production stream/durable, uses the production
  spool/sender, registered mTLS gRPC service, gateway publisher, and EventWriter
  entry points, and queries the committed CNPG tables. Manually calling the
  component modules in sequence is not closure. `edge-records:v1` remains
  disabled outside this guarded target; inside it, readiness becomes true only
  after the required stream and durable are writable. Committed synthetic
  certificates, keys, grants, and contract inputs are permitted, but the
  production mTLS handshake, principal resolver, trust/grant/route/contract
  validation, and authorization ordering SHALL execute. One mismatched identity
  control that differs from the accepted fixture only in the authenticated
  principal SHALL pass the mTLS trust gate, fail with the asserted
  identity-mismatch outcome, and be refused before NATS publication.

  MECHANICAL CLOSURE is CONJUNCTIVE. The following SIX groups are the complete
  acceptance matrix; every listed observation SHALL be made through the composed
  target:

  **A. PRODUCTION COMPOSITION AND TRUST.** The positive fixture reaches the
  production EventWriter and its unique fixture identities are asserted absent
  from the scratch database before the send and exactly present afterward. The
  queried Sweep domain row SHALL match independently committed expected values
  for every required fixture field. The mismatched-identity control above SHALL
  pass every preceding gate and fail for that named reason. The target fails if
  any production entry point, required stream/durable provisioning, or readiness
  gate is bypassed.

  **B. EXACT BYTES.** Read the committed record through the public spool read
  path and fetch the stored message through the JetStream consumer. Those two
  independently observed byte strings SHALL be identical. Comparing two aliases
  of the fixture, or values produced by the same helper without those two reads,
  is not evidence.

  **C. IDEMPOTENT CNPG TRANSACTION.** Force consumer redelivery of the SAME
  stored JetStream message and observe the EventWriter/ledger path enter twice;
  JetStream de-duplication at publish time is not replay evidence. Exact before,
  first-commit, and second-delivery database snapshots SHALL show one event
  ledger row, one immutable delivery-slot binding, one sweep-batch-slot binding,
  no duplicate domain rows, and the same exact expected Sweep field values. A
  validly signed, digest-consistent second frame that differs from the accepted
  fixture only in record content and its corresponding `record_sha256`, while
  reusing the same delivery slot, SHALL pass every preceding gate, reach
  EventWriter, fail with the asserted delivery-slot-conflict outcome, and leave
  the first immutable binding unchanged.

  **D. FAILURE AND WATERMARK ORDER.** Cut the real NATS connection after spool
  commit, invoke the production sender for that exact entry, and observe its
  publish attempt take the withholding/failure path: no gateway durability
  acknowledgement and an unresolved spool entry. Force the CNPG transaction to
  roll back after broker delivery and observe that EventWriter sends no broker
  ACK and the stored message is redeliverable. After the positive publication's
  PubAck, observe the production gateway write the spool-ID/session-nonce-bound
  cumulative `EdgeDeliveryAckV1` and the agent advance its remote resolved
  prefix. That gateway acknowledgement or remote prefix alone SHALL NOT
  physically reclaim the spool record. Task 0.12 proves successful remote
  progress and that negative reclaim rule; implementing and positively
  exercising agent-local terminal reclaim remains with its existing lifecycle
  owner after this slice.

  **E. RESTART OVERLAP.** While one publish request is in flight, restart the
  lane publisher/pool and prove replacement state does not reopen capacity still
  occupied by that request. After that request's termination is observed, the
  replacement SHALL admit work within the original grant. Waiting for an
  eventual sibling restart, permanently disabling the replacement, or checking
  only the final empty window does not satisfy this group.

  **F. POST-HANDOFF FENCING.** After a reservation is handed to its request
  owner, attempt a retry of that publication and observe refusal until the
  previous request is fenced by observable owner/start/termination state. After
  that fence, the same publication SHALL be admitted once and proceed. A passed
  deadline, an absent PubAck, or permanently disabling retries does not satisfy
  this group.

  OUT OF SCOPE UNTIL THIS TASK IS GREEN: another producer or traffic class; MTR;
  recovery or spool rollover; exhaustive refusal/DLQ/redrive behavior; full
  64-partition production sizing; generalized contract dispatch; benchmarks;
  dashboards; migration/canary/rollout; soak; new mutation or fixture axes not
  required by groups A-F; and final ABI/archive completeness. Inputs are
  out-of-scope only when they are unreachable through the declared v1 boundary,
  not merely absent from the positive fixture. Normative requirements applicable
  to groups A-F or to a concrete V2 boundary-safety finding, plus all existing
  required checks, remain binding; they do not create a seventh acceptance group
  or require completion of an owning parent task.

  An actionable non-blocking defect SHOULD be recorded once in an existing named
  task or a separate issue and, when recorded, linked once in the implementation
  PR's consolidated deferred summary. Logging or listing it is not an approval
  prerequisite and cannot start another review round. This scope block may
  change only with explicit maintainer approval in a separate docs-only
  amendment. Implementation and review agents MAY propose an amendment; they
  SHALL NOT promote it into the milestone themselves.

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
- [ ] 0.7 Capture representative Wasm metric/event/inventory output, native
  add-on telemetry and OTLP relay, and embedded Armis discovery fixtures.
  Measure producer-to-agent copies, JSON/base64 amplification, queue-loss
  windows, peak memory, records/bytes per run, and downstream row/write cost.
- [ ] 0.8 Approve which existing outputs are durable records, ephemeral state,
  command/action traffic, or blob/media traffic. Publish a migration inventory;
  no existing queue is promoted to durable merely because it contains telemetry.
- [ ] 0.9 Reconcile dependent active proposals before wire or adapter
  implementation begins. Amend `add-external-inventory-wasm-plugin-contract`
  from one complete `plugin_result.v1` snapshot to bounded typed pages plus
  terminal activation, and amend `add-event-writer-processor-contributions` so
  edge dispatch uses the trusted binary contract envelope on fixed platform routes rather
  than package-selected subject filters. Validate each dependent change
  independently and document its rebase/archive order.
- [ ] 0.10 Treat the existing `usp-02` through `usp-23` implementation slices as
  a review prototype, not an approved ABI. Stop new implementation slices until
  this revised proposal is approved; then amend or replace every slice whose
  frame, lane, route, header, authorization, cost, registry, spool, gateway, or
  EventWriter assumptions use the closed sweep/MTR contract. Do not merge the
  closed `EdgeResultPayloadKind` or sweep/MTR-specific lane topology and attempt
  to generalize it later.
- [x] 0.11 Withdraw the unimplemented
  `add-configurable-sysmon-payload-limit` proposal. Its per-tenant 15 MiB
  `GatewayServiceStatus` exception contradicts the single-installation model,
  bounded records, and JetStream-first sysmon migration; sysmon now
  uses the common producer sink and contract paging/flush bounds.

## 1. Define versioned wire contracts

> **BOUNDARY:** tasks 1.1-1.7 and 1.13-1.15 MOVED to the separate
> `freeze-edge-record-v1-abi` change, which owns the wire ABI and its freeze gate.
> Task 1.3 was SPLIT: its ABI/schema/correlation half went with them; the durable
> storage, replay/repair state machine, conflict resolution, retention, GC, and
> lookup-outcome transitions remain runtime work and are tracked there as
> downstream. The ORIGINAL task 2.20 (implement the frozen classification spans in
> both runtimes) was FOLDED into that change's 1.6a so the proto shape,
> both validators, the byte checks, and the fixtures land atomically. THIS change
> DEPENDS ON that one and MUST NOT re-freeze any contract it owns.

- [ ] 1.8 Add `ProducerRunEventV1` and typed
  `DeviceInventoryObservationBatchV1` contracts with provider/source identity,
  bounded pages, stable item keys, page ordinal/content digest, cursor, start,
  checkpoint, complete/partial/aborted terminal manifest, and absence/deletion
  semantics that activate only after a valid complete terminal. Bind a bounded
  ordered Merkle/checkpoint root, assignment-authorized coverage scope, and
  provider snapshot token/revision or contract-specific consistency proof;
  without completeness proof, a run is upsert-only.
- [ ] 1.9 Define an approved extension-record batch whose schema reference,
  bounds, cost model, and selected platform-owned projector are frozen in a
  versioned output-contract registry. Reuse
  `add-event-writer-processor-contributions`; forbid package-supplied executable
  consumers, SQL/DDL, table names, and arbitrary NATS filters.
- [ ] 1.10 Define the signed package output request and assignment-compiled
  effective grant: contract/version/digest, producer/package identity, run
  shape, maximum record/frame/run/outstanding bytes and counts, rate, route
  profile, immutable traffic class, cost model, revocation epoch, and recovery
  behavior. Define one registry epoch consumed by agent, gateway, and
  EventWriter readiness. Hash the complete historical contract bundle including
  canonicalization/unknown-field policy, validator, authority rules, partition
  rule, cost model, projector configuration, retention/classification, domain
  identity/revision semantics, and error policy. Retain it through every
  offline/spool/replay/DLQ/redrive horizon and distinguish planned retirement
  from fail-closed security revocation.
- [ ] 1.11 Define the signed registry lifecycle and activation protocol with
  `candidate`, `ready`, `active`, `draining`, `retired`, and
  `security-revoked` states. Require readiness evidence for the target agent
  cohort, every authoritative gateway route/map generation, and every required
  EventWriter validator/cost/projector before one atomic active-epoch switch;
  assignment compilation MUST NOT grant a candidate or partially active epoch.
  Planned retirement stops new grants while exact historical bundles drain to
  bounded watermarks. Security revocation stops both production and delivery
  fail-closed until an approved safe replacement/redrive or waiver exists.
  Define rollback, stale-component fencing, bundle retention, and GC rules.
- [ ] 1.12 Define a deterministic platform-owned cost API and golden fixtures
  for each output contract. The agent SHALL compute the trusted conservative
  charge or reserve the grant maximum, the gateway SHALL validate that trusted
  stamp against the active bundle without trusting caller metadata, and
  EventWriter SHALL recompute decoded actual rows/write bytes before refund or
  commit. Underdeclared, unknown-model, overflow, or nondeterministic cost is a
  protocol failure, never authority to perform a partial write.
- [ ] 1.16 Runtime integration of the publication-identity codec at the trust
  boundaries (requires live infra; separate from the pure codec in 1.14): (a) at
  ingress, extract EXACTLY ONE value per required publication-identity header with
  CASE-INSENSITIVE name matching, rejecting missing/duplicate headers fail-closed;
  (b) resolve the provenance `route_map_version` against an active or retained
  immutable route-map generation, verify the authenticated publisher class,
  subject, physical stream, route profile, and traffic class agree with it, fail
  readiness (no ACK/NAK) on unknown/unavailable history, and fail closed as a
  transport-integrity failure on a known placement mismatch; (c) enforce THREE
  DISTINCT identity checks -- (i) GATEWAY ingress: the authenticated mTLS AGENT
  identity equals the record/slot `authenticated_agent_id`; (ii) EDGE EventWriter:
  the publisher is the authorized GATEWAY class/subject (the gateway credential ID
  need NOT equal the agent principal); (iii) SERVICE EventWriter: the
  credential-derived service identity equals BOTH the record `origin_principal_id`
  AND the `service_slot` principal. `ValidateHeaderSet` performs the
  record-vs-provenance cross-check (scope, origin kind, publisher class, principal)
  and applies the credential-vs-principal comparison ONLY on the service-ingress
  path -- it NEVER compares the gateway credential to the agent principal for edge
  records; (d) route ALL untrusted edge-protobuf decoding at these boundaries
  through the total `ServiceRadar.Edge.WireDecode` boundary, which exposes ONLY a
  FINITE set of stage decoders (`decode_client_message/1`, `decode_frame/1`,
  `decode_record/1`) -- the generic decode engine is PRIVATE, so a caller-defined
  struct decoder can never yield `{:ok, fake_struct}` -- each enforcing its FROZEN raw
  byte bound (the frozen `MaxRecordBytes` / `MaxFrameBytes` / `MaxClientMessageBytes`) BEFORE invoking protobuf, and accepting a decode result only
  when `is_struct(decoded, target)`. The frame bound is RELATIONAL, not just a total: the
  NON-record overhead (delivery capability + spool/sha/sequence + framing) MUST fit the
  `MaxDeliveryEnvelopeBytes` budget independently, so a tiny `record_bytes` with a
  bloated delivery capability / issuer id is rejected even though the total is under
  `MaxFrameBytes` (enforced by Go `ValidateDeliveryFrame` on the send/validate path AND
  at the decode boundary). Do NOT generate bound fixtures here: the N/N+1 vectors for
  record / frame / client-message and the relational-envelope vector are produced and
  owned by ABI task 1.7. This task CONSUMES that frozen corpus and asserts this decode
  boundary returns the same verdicts. It returns a TYPED outcome: `{:error, :too_large}`
  (raw bytes over the stage bound -- a PERMANENT rejection checked BEFORE decode) and
  `{:error, :poison}` (the decoder's DELIBERATE `Protobuf.DecodeError`, or -- INTERIM,
  until task 1.5, see the KNOWN LIMITATION below -- an unmapped edge-enum value) resolve a
  DECODABLE per-delivery slot as permanently dead (pre-slot
  resolution is stage-specific, per (e)); `{:error, :not_ready}` (an expected edge schema
  not yet deployed) and `{:error, :systemic}` (a decoder BUG, or an AMBIGUOUS `MatchError`
  -- a raise/throw/exit NOT proven to be malformed wire) leave the delivery UNRESOLVED
  for replay. Classification is STACK-INDEPENDENT: it keys on the exception's OWN value
  (`%Protobuf.DecodeError{}` -> poison; a `%FunctionClauseError{}` whose `module` is a
  generated edge ENUM -> poison; a `%MatchError{}` is AMBIGUOUS -- raised by malformed
  wire AND by non-data codegen/metadata bugs, so `:systemic`, NEVER permanent poison,
  until a project-owned typed malformed-wire result (task 1.5) can disambiguate it;
  anything else -> systemic), NOT the stacktrace, so a permanent data-loss verdict cannot
  flip under `:erlang.system_flag(:backtrace_depth, _)`. (KNOWN LIMITATION, resolved by
  task 1.5: an unmapped NEGATIVE enum is protobuf-valid data Go retains then SEMANTICALLY
  rejects, whereas protobuf-elixir cannot decode it, so WireDecode classifies it `:poison`.
  This is NOT truly equivalent to Go's reject -- Go's structural semantic reject is a
  `permanent_rejection` while a decode-time `:poison` is an `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE` -- so the
  interim `:poison` is a STOPGAP ONLY: AFTER task 1.5 lands, a negative enum DECODES
  (retained as an integer) and the SAME explicit semantic validator rejects it as a
  `permanent_rejection`, SUPERSEDING the interim `:poison`/quarantine. task 1.5 must align
  BOTH the mechanism AND the disposition and is a prerequisite of live task 1.16.)
  **P0 -- the boundary MUST run BEFORE the generated gRPC codec, not in the handler.**
  `EdgeRecordIngestService.Stream(stream EdgeRecordClientMessage)` binds the RPC to the
  DECODED `EdgeRecordClientMessage` (a `lane_open`/`delivery_frame` oneof), so the
  generated server codec eager-decodes the whole client message -- including
  `lane_open.traffic_class` -- and raises on a negative enum BEFORE any handler could
  call `WireDecode`. Because the candidate wire ABI's `Stream(stream EdgeRecordClientMessage)`
  RPC shape is fixed (and will be FROZEN at the task-1.7 freeze gate, so this codec must
  preserve it, not change it), task 1.16 MUST register a custom
  `GRPC.Codec` for the edge-ingest server that: (i) IDENTIFIES as content-type `proto` so
  a STOCK generated Go client (`application/grpc+proto`) interoperates unchanged; (ii)
  REPLACES the default codec ONLY for the edge-ingest `GRPC.Server` (not the global codec
  registry), leaving co-hosted services and the FIXED CANDIDATE
  `Stream(stream EdgeRecordClientMessage)` signature (frozen only at task 1.7) UNCHANGED -- it MUST NOT retype the
  RPC payload to a `bytes` envelope; (iii) returns the RAW inbound message bytes to the
  handler for `decode_client_message/1`; and (iv) DELEGATES OUTBOUND encoding to the
  standard protobuf codec. **P0 -- the RAW-SIZE bound MUST be enforced at the TRANSPORT,
  BEFORE buffering, not only inside WireDecode.** The streaming path frames each message
  with a 5-byte gRPC length prefix (1 compression flag + 4-byte big-endian length) and
  BUFFERS chunks until the full declared length arrives; `max_body_size` covers only the
  unary `read_full_body` path, NOT this stream. So task 1.16 MUST, per inbound frame,
  REJECT a declared length exceeding `MaxClientMessageBytes` BEFORE appending any chunk
  (never buffer toward an attacker-declared 32-bit length), and MUST DISABLE gRPC message
  compression on the edge-ingest lane -- a message whose compressed-flag is set MUST be
  REJECTED immediately (no bounded-decompression fallback, since compression is applied
  before the codec sees the bytes)
  so a peer cannot force unbounded buffering or a decompression bomb ahead of the size
  check. It MUST PROVE (using `poison_client_message_negative_enum.bin`) that a
  negative-enum client message is CONTAINED by the transport rather than crashing it and --
  because task 1.5 is a PREREQUISITE of this task -- that it DECODES into a struct PRESERVING
  the negative integer which the shared semantic validator then rejects as a
  `permanent_rejection` (decode-preserved, matching Go); the pre-1.5 interim `:poison`/quarantine
  is retained only as NON-NORMATIVE history, not a co-requirement. The proof MUST be STAGE-SPECIFIC,
  because `poison_client_message_negative_enum.bin` is a LANE-OPEN and a lane-open has NO delivery
  slot: a semantic failure there CLOSES THE HANDSHAKE and emits NO `EdgeDeliveryAckV1` disposition,
  whereas the SAME semantic failure at a KNOWN delivery slot RESOLVES the sequence as
  `EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT` (reject-audit DLQ). Both cases MUST be proven; a lane-open MUST NOT be
  asserted to produce a per-delivery disposition. It MUST ALSO prove that LAST-ONE-WINS is honoured
  -- a negative enum FOLLOWED BY a valid member decodes to the VALID member and is ACCEPTED, exactly
  as Go accepts it -- so the retention fix cannot regress into a first-occurrence rejection.
  AND add a REAL generated-Go-client interoperability test (a
  stock Go `EdgeRecordIngestService` client streams to the edge server through the custom
  codec and the raw bytes decode identically). The pre-buffer/pre-decompress guard MUST be
  TESTED with the actual attacks, not only a post-buffer size check: (i) a FRAGMENTED length
  prefix declaring N+1 and a near-2^32 length with the body WITHHELD -- rejected/closed
  before the body is buffered (asserting bounded retained memory, not accumulation to the
  declared length); (ii) a set compression flag on the edge lane -- rejected immediately;
  (iii) N (at-bound, accepted) / N+1 (over-bound, rejected) across multiple HTTP/2 DATA
  fragments; (iv) a COHOSTED gRPC service on the same server -- proving its codec and its
  own (larger) message limits are UNCHANGED by the edge-lane codec/guard. Ingress is then
  TWO-STAGE:
  `decode_client_message/1` on the raw bytes, navigate to the nested `delivery_frame`,
  then `decode_record/1` on the raw `frame.record_bytes`. (e) Poison/too_large RESOLUTION
  is STAGE-SPECIFIC and follows ONE frozen envelope-poison split, because a poisoned outer
  message may have NO delivery slot to resolve: (i) NO TRUSTWORTHY SLOT -- a poisoned/oversize
  or SEMANTICALLY INVALID (e.g. unknown/negative enum) LANE-OPEN handshake, which has no
  spool/sequence, or a DELIVERY ENVELOPE with NO recoverable
  authenticated lane/sequence coordinates -- REJECT and CLOSE the lane, writing only bounded
  audit/fingerprint data (never an unbounded quarantine of the raw bytes) and carrying NO
  per-delivery disposition (a lane-open failure MUST NOT be reported as a per-delivery
  disposition of any kind); (ii) WIRE POISON WITH A TRUSTWORTHY SLOT -- an admitted wire-
  hygiene / unknown-field / group malformation in the DELIVERY ENVELOPE (the client-message
  `delivery_frame`, or the frame itself) OR in the INNER RECORD (`frame.record_bytes`, under a
  valid outer frame), with recoverable coordinates (the gateway-authenticated session plus the
  frame's own spool/sequence, IF they decoded) -> `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE` + quarantine-DLQ PubAck
  (the sequence RESOLVES; poison is quarantined, NOT permanently rejected); (iii) OVERSIZE or
  DECODED SEMANTIC/PROTOCOL INVALIDITY at a trustworthy slot -- an oversize frame/record
  (`:too_large`), an invalid signature/structure, an envelope-to-grant mismatch, or a decoded-
  but-semantically-invalid value (e.g. a negative/unknown enum) -> `EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT` +
  reject-audit PubAck (the sequence RESOLVES). A `:not_ready`/`:systemic` outcome at ANY stage
  yields NO positive ACK and NO terminal resolution (pause + replay). RECONCILE the transport
  signal with the ONE frozen disposition table: a PRE-SLOT transport failure (a poisoned/
  over-length lane-open, an over-length transport frame rejected before buffering, or a
  poisoned envelope with NO recoverable lane/sequence coordinates) is signaled at the
  LANE/TRANSPORT level -- tear the lane down for reconnect (or, for a decodable pre-slot
  reject, close the handshake) -- and carries NO per-delivery `EdgeDeliveryAckV1`
  disposition, because there is no sequence to resolve. Only a DECODABLE per-delivery slot
  emits a disposition, drawn from exactly THREE cases: (1) a TRANSIENT at a decodable slot
  (`:not_ready`/`:systemic`, unavailable key, not-ready fence) -> `EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE` (the
  sequence stays UNRESOLVED, no watermark advance); (2) ADMITTED WIRE POISON at a trustworthy
  slot -- an inner record (`:poison` under a valid outer frame) OR an envelope/frame wire-
  hygiene poison -> `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE` + quarantine-DLQ PubAck (the sequence RESOLVES --
  poison is quarantined, NOT permanently rejected); (3) an OVERSIZE frame/record at a known
  slot (`:too_large`), an invalid key/signature/structure, an envelope-to-grant mismatch, or
  DECODED semantic/protocol invalidity (e.g. a negative/unknown enum) -> `EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT`
  + reject-audit PubAck (the sequence RESOLVES). So `no ACK/NAK` means "no per-delivery disposition" (a pre-slot or paused
  case), NOT a contradiction with the per-delivery
  `EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE`/`EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE`/`EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT` signals. (NOTE:
  `WireDecode` currently has NO production callers -- it is the boundary to be wired in
  HERE; the shipped golden fixtures exercise the raw client-message and record stages,
  not yet the live gRPC codec, which this task adds.) (Service lane/sequence DURABILITY
  is owned by the governed service publisher, NOT the gateway/EventWriter; see task
  4.6.)
## 2. Stream completed observations from the agent

> The ORIGINAL task 2.20 moved into `freeze-edge-record-v1-abi`'s task 1.6a. The
> number is REUSED below for the runtime half of the split task 1.3 -- implementing
> the durable assignment mapping -- so "2.20" in this change means that, not the
> classification-span work.

- [ ] 1.16a **Freeze the producer-facing sink/run API (displaced from the ABI
  change's task 1.7).** That change freezes the agent-gateway TRANSPORT ABI only.
  The producer-facing API is a separate freeze and depends on Wasm and native-relay
  fixtures the ABI change does not own: freeze contract handles, producer-local
  receipts, credits/backpressure surface, and the run lifecycle only after those
  fixtures cover them. The ABI change's 1.7 SHALL NOT be read as freezing this.

- [ ] 2.1 Refactor sweep execution so completed host windows feed the result
  pipeline continuously while scanning continues; remove full-run result JSON
  construction and delivery ownership from `GetSummary`.
- [ ] 2.2 Implement byte-aware protobuf builders that flush near 256 KiB, never
  exceed `MaxRecordBytes`, honor short flush timers, and apply secondary 2,000-host and
  128-trace guards plus hard 10,000 sweep-row and 5,000 MTR-row projection
  budgets; group hosts only when their exact attempted-check dictionaries match.
- [ ] 2.3 Emit stable execution start, bounded progress/watermark, completion,
  and aborted evidence, with each data frame independently decodable and useful;
  integrate scheduler lease recovery so an agent crash produces authoritative
  lost/expired/superseded attempt state and a retriable WHOLE range window (v1 has no
  sparse-remainder representation -- see task 2.3c).
- [ ] 2.3a Fetch/validate/cache only bounded immutable target-plan pages per
  assignment. Keep CIDR/range inputs compact and forbid an execution-wide target
  array in config, command, agent memory, or terminal evidence.
- [ ] 2.3c **v1 retry/supersession replays the WHOLE range window.** The frozen ABI
  gives each plan range ONE CONTIGUOUS plan-global ordinal window and gives an
  assignment ONE window, so a SPARSE REMAINDER is not representable: a retry that
  covered "only what is left" would have to renumber or omit ordinals, and its
  completion proof requires exactly `{1..ordinal_count}`. Reassignment therefore
  replays the complete window under a new authority epoch. Anything narrower needs the
  deferred bounded-subset representation and its own frozen grammar -- do NOT
  approximate it by shrinking `ordinal_count`, which the plan relation rejects.

- [ ] 2.3b **Produce the MTR completion proof in `go/pkg/edge/execstate`, and
  verify it against real plan state.** DEPENDS ON 2.3a, which fetches, validates and caches the
  bounded immutable plan pages -- that IS the validated plan state this task folds
  over and verifies against, so it cannot start first. OWNS the producer half the
  ABI change deliberately did not land. Today `execstate.Tracker` builds every lifecycle event
  but NEVER touches the completion accumulator -- it sets only the
  `expected_mtr_*`/`emitted_mtr_*` counters -- so no COMPLETED event this repository
  produces carries a real proof.
  PRODUCER: fold `MtrCompletionLeaf`s through `edgerecord.MtrCompletionAccumulator`
  as ordinals reach a terminal disposition, and emit `Root` on the terminal event.
  A plan admitting NO MTR targets emits `edgerecord.ZeroMtrCompletionRoot` -- the
  proof is MANDATORY (frozen by "A zero-MTR completion is a mandatory canonical
  proof, not an absence"), so omitting it is not an option the producer has.
  CONSUMER: `edgerecord.VerifyCompletionAgainstPlanState` is a comparison PRIMITIVE
  whose caller supplies every authoritative value, so a caller that derives them
  from the event gets a VACUOUS check. Real verification needs the expected ordinal
  count and `mtr_ordinal_range_commitment` to come from a validated, authenticated
  plan/assignment carrier -- which is task 1.3's authoritative assignment record in
  the ABI change. GATED ON 1.3; do not claim consumer verification before it lands.
  Elixir has no completion verifier at all beyond the `HashGrammar` primitive, so
  the consumer side must name which runtime performs the check.
  ALSO: both plan-derived relations are now RESOLVED upstream -- `range_root_sha256`
  is RETIRED (tag 20 reserved) in favour of the assignment record's resolvable
  `target_range_id` + `target_range_sha256`, and the assignment's required MTR
  expectation states the admitted ordinal count. Verify against the ASSIGNMENT's
  expectation, never the plan-wide commitment.

- [ ] 2.4 Implement an fsynced segmented agent spool that persists encoded bytes,
  event IDs, sequence state, checksums, retry/quarantine state, and survives
  restart without overwriting unacknowledged data; cover record/tail checksums,
  directory fsync, private permissions, never-reused sequence high-water,
  `ENOSPC`, `EIO`, torn-tail recovery, corrupt-segment quarantine, and emergency
  metadata capacity. Implement journalled, content-addressed loss-manifest/new-spool
  rollover with a durable phase journal; an AGGREGATE scratch reserve sized for
  destination segment + attribution sidecar + BOTH journal copies +
  manifest/tombstone pages + old->new mapping + filesystem metadata, times the
  bounded number of concurrent recoveries (NOT a one-segment reserve); fsynced
  old-to-new copy watermarks; replacement delivery capabilities; and per-segment
  delete-after-COVERAGE ordering, where coverage means every unreclaimed ALLOCATED
  sequence in `(durable_local_reclaim_watermark, sequence_high_water]` is either a
  FULLY COMMITTED, SENDER-VISIBLE destination slot or a PubAcked frozen
  classification span WHOSE COVERED SEQUENCES ARE EACH BACKED BY DURABLE PER-SEQUENCE
  LOSS EVIDENCE WHOSE JOURNALED CLASSIFICATION MATCHES THE SPAN'S COMPLETE ONEOF BODY
  -- a destination fsync plus mapping is NOT sufficient, and neither is the PubAck
  alone, since a widened span cannot show whether an omitted sequence was lost or
  preserved, nor whether the body it carries is the one the coordinator journaled. Never enumerate an outage-sized recoverable tail;
  re-enqueue it with stable semantic identity and make affected coverage partial.
  Bind every recovery generation and manifest page immutably, SPLIT an overlarge
  manifest across recoveries rather than coarsening proven attribution into an
  uncertain scope (known attribution is never relabelled UNATTRIBUTABLE to shed
  bytes), enforce page/manifest byte ceilings against EXACT RECEIVED bytes, and
  retain both recovery
  journal copies until a signed, consumer-committed `RecoveryResolvedV1` (or its
  idempotent query result) is durable locally. Put every lane, quarantine,
  journal copy, segment/metadata overhead, rollover amplification, and scratch
  reservation under one atomic filesystem byte allocator with an unborrowable
  minimum-free-space floor for recovery/control and terminal evidence.
- [ ] 2.5 Add a bounded bidirectional gRPC sender with independent finite
  platform-owned bulk/interactive and reserved recovery-control sequence/credit
  lanes, cumulative resolved
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
- [ ] 2.7 Add byte-based fair interleaving across network/site scopes, agents,
  producer assignments, runs/executions, and control-plane-attested traffic classes
  at the agent and site scheduler. Use a finite platform-owned set of bulk,
  interactive, and recovery spool/credit lanes so one sweep, MTR, inventory,
  plugin, or integration run cannot monopolize the record window; callers
  cannot promote their own work or create a lane. Reserve an
  unborrowable interactive agent-execution floor across probe workers, sockets/
  file descriptors, ICMP tokens, DNS concurrency, CPU, spool, and sender credits.
- [ ] 2.8 Emit the small MTR summary on its correlated sweep host and the complete
  trace through `MtrTraceBatchV1` for every producer mode; allow an independently
  revisioned MTR-mode fragment to follow ICMP/TCP without suppressing it, and
  flush rather than mixing different authorization contexts in one trace batch.
  Feed each completed trace directly into the bounded builder/spool and release
  its working memory in scheduled, sweep-profile, ad-hoc, and on-demand paths;
  forbid an interval-wide or execution-wide `[]trace` accumulation.
- [ ] 2.9 Advertise producer-plane protocol, registry epoch/bundle, encoder,
  validator, cost-model, route-profile, and spool-reader support in Hello and
  select one exact sticky output-contract bundle per run from the compiled grant
  plus end-to-end readiness; do not use a config hash as the gate and never emit
  a second authoritative representation for one semantic event.
- [ ] 2.10 Implement the agent-owned producer sink and run API for in-process
  collectors. Validate the effective output grant, bind trusted agent/package/
  assignment/scope identity, allocate stable event and spool coordinates,
  derive conservative cost/routing metadata, DERIVE the `RecoveryAttribution` for
  the append from the record's own authenticated fields (output contract bundle
  digest, producer context assignment/run/shard, production and source claim
  authority, the PRODUCTION scope as `production_scope_id` + `scope_sha256`, the
  SOURCE IDENTITY -- signed source KIND, `context_id`, `source_scope_id`, AND
  `source_scope_sha256`, all four jointly, or their JOINT ABSENCE -- the
  `attribution_kind` (ACTIVE/PASSIVE) discriminant, and, for ACTIVE, the
  `range_sha256`) and submit it with the append so the spool can verify the
  semantic join, and return success only after the exact record bytes, the bound
  attribution, and the producer idempotency binding are fsynced under one commit
  marker. Compute
  `submission_sha256` over the producer's UNCOMPRESSED contract-payload
  submission and perform the retry/receipt lookup BEFORE compression/re-encoding.
  On a HIT return the ORIGINAL durable artifact (its original `payload_sha256`/
  `record_sha256`) WITHOUT re-compressing or re-encoding; only on a MISS compress
  once and fsync the producer idempotency binding, which keys ONLY on `(package
  digest, producer assignment, host-issued run, output contract, producer
  idempotency key)` and stores/immutably-compares `submission_sha256` (never a
  key component).
  Return
  explicit retryable backpressure without accepting-and-dropping. Use bounded
  byte/time group commit so many producers share fsync throughput while each
  receipt is released only after the exact batch containing its record is
  durable; cap waiters and retained binaries so group commit cannot become an
  unbounded mailbox or memory queue.
  Atomically journal the binding keyed ONLY by `(package digest, producer
  assignment, host-issued run, output contract, producer idempotency key)` ->
  `(event ID, stored `submission_sha256`, original `payload_sha256`/
  `record_sha256`, receipt)` with the spool append, expose receipt lookup after
  uncertain outcomes, and return the original receipt and artifact for a
  same-key/same-`submission_sha256` retry. Retain the binding through the grant-declared
  producer retry horizon after spool reclamation and until the run/epoch is
  durably closed and fenced. After safe GC, reject a late retry against that
  closed handle as `retry_horizon_expired` rather than creating a new event;
  reject same-key/different-`submission_sha256` conflicts while preserving the
  original binding and audit evidence.
- [ ] 2.11 Add a versioned Wasm binary host ABI and SDK for opening runs,
  publishing bounded records, checkpointing, committing, aborting,
  and observing byte/frame credits. Permit one bounded guest-to-host copy;
  remove protobuf-to-base64-to-JSON wrapping and reject ungranted contracts,
  caller-selected identity/routing, oversize output, and ignored backpressure.
  Define retry-after notification, cancellation with uncertain fsync, permanent
  error classes, and host-enforced pause/fuel/CPU controls against busy loops.
- [ ] 2.12 Add one generic native add-on bidirectional record relay with bounded
  credits and cumulative agent-local durability ACKs. Migrate durable
  `StreamTelemetry` and `RelayOtlp` output to the common spool while retaining
  only explicitly classified runtime counters on a lossy path. Test add-on
  restart before and after the local ACK so neither loss nor unbounded duplicate
  amplification occurs. Bind each relay to package assignment, host-issued
  session nonce, peer identity, and resume watermark; fence stale sessions.
- [ ] 2.13 Adapt embedded integration sources to the producer sink, beginning
  with Armis inbound discovery. Preserve provider pagination/mapping but emit
  typed inventory pages as they arrive and a terminal manifest; remove repeated
  JSON sizing/encoding, `StreamStatus`, ERTS, Jason decode, and whole-run
  coalescing from the new path.
- [ ] 2.14 Keep bounded, coalescible check/status summaries on
  `GatewayServiceStatus`, but move persistent metrics, traces,
  inventory, events, enrichment, and other durable output out of
  `serviceradar.plugin_result.v1` and drain-before-send memory queues. Document
  and enforce the durable/ephemeral boundary in every producer SDK.

- [x] 2.15 **Correct `fairsched`: derive lanes from the platform taxonomy.**
  MERGED as PR #4735 into `usp-01-proposal`. It hardcoded sweep/MTR lanes; lanes
  now come from the finite (route profile, traffic class) taxonomy via an injected
  `LaneTaxonomy`, with `LaneKey`, an explicit recovery lane, positive bounded
  weights, and typed `ErrLaneInvalid`/`ErrLaneNotReady`/`ErrTaxonomyInvalid`.
  Unknown enum members are rejected generically through `protoreflect` descriptor
  membership rather than a switch, so a member added to the proto is accepted by
  regeneration alone. Regressions cover taxonomy-driven scheduling of an
  unknown-to-the-scheduler lane and rejection of undeclared enum numbers.
- [x] 2.16 **Correct `gwprefix`: separate dispositions and separate remote
  resolution from local reclaim.** MERGED as PR #4736 into `usp-01-proposal`. All
  five frozen dispositions stay distinguishable (the tracker uses
  `EdgeRecordDispositionKind` directly rather than a local copy), only the four
  resolving kinds advance the remote prefix, and a `retryable_rejection` caps the
  prefix PROVISIONALLY -- a later resolving kind for the same sequence supersedes
  it, so a retry cannot permanently wedge the prefix. `ResolvedThrough` and
  `ReclaimableThrough` are separate watermarks and a PubAcked prefix does not
  advance local reclamation.
- [ ] 2.17 **Correct `admission`: free bytes on durable terminal outcome only.**
  It releases reserved bytes when the gateway resolves, which reclaims evidence
  before the agent can prove the outcome survived its own restart. Release MUST
  follow the durable terminal record and the coverage proof. Test that a crash
  after PubAck but before the terminal record leaves the bytes present.
  STATUS -- DELIBERATELY UNCHECKED. The ADMISSION-SIDE boundary MERGED as PR #4739
  into `usp-01-proposal`: bytes are charged to an immutable `SlotKey{Spool, Seq}`,
  nothing releases them except a SEALED `ReclaimAuthorization` (an opaque carrier
  with no exported fields and deliberately NO producer, so no caller can mint one
  today), applied monotonically per generation. `NoteGatewayResolved` was REMOVED
  outright, so admission holds no remote-resolution state at all. Do NOT redo that
  work. This box stays unchecked because the END-TO-END demonstration -- producing
  the authorization and proving it across a crash -- is task 2.28, and 2.17 is not
  a completed freeze prerequisite until then.
  SCOPE: this task covers the ADMISSION side of that boundary only -- charging
  bytes to an immutable slot identity, refusing to release on gateway resolution,
  and consuming an opaque monotonic reclaim authorization it cannot construct.
  PRODUCING that authorization, and proving it holds across a crash end to end,
  is task 2.28. Admission MUST NOT own, store, or infer gateway resolution --
  that lifecycle is `gwprefix`'s (task 2.16), and holding an unread copy of it
  here is duplicate state that can only drift. It MUST NOT own spool generation
  lifecycle (task 2.21), redundant commit evidence or restart classification
  (task 2.23), the reserve/allocation capacity primitives (task 2.26), or
  coverage computation (task 2.28); modelling any of them here means inventing
  semantics for an owner that does not exist yet and then keeping two
  definitions in agreement by hand.
- [ ] 2.18 **Correct `projection`: use the v2 idempotency and cost model.** It
  applies the wrong idempotency key and cost model for v2 records. Align both with
  the record identities and the versioned cost contract, and test replay
  idempotence plus cost accounting against the v2 model.
- [ ] 2.19 **Hold PR #4685 until 2.15-2.18 are demonstrated.** The edge feature
  branch carries `fairsched`, `admission`, `gwprefix`, and `projection` as PARTIAL
  SCAFFOLDING: they compile and pass their tests against the v2 contract without
  being semantically correct under it. This is a temporary integration gate, not a
  durable requirement, which is why it lives here and not in the spec. Promotion of
  the edge feature branch to `staging` is BLOCKED until each correction is
  demonstrated against the specification rather than against compilation success.
- [ ] 2.20a **OWN the assignment mapping's tagged VALUE shape.** The ABI change froze
  the KEY only; it explicitly does NOT freeze the value, because no message there
  represents a POSITIVE / EXPLICIT_NEGATIVE body or a durable negative reason. Define
  the tagged body here -- POSITIVE (execution/plan/range identities and digests, shard,
  epoch, contract-specific correlation operand) or EXPLICIT NEGATIVE (durable negative
  evidence and reason, no positive-only fields). A single untagged schema cannot
  express both, because a durable negative means there is no execution.

- [ ] 2.20 **Implement the durable assignment mapping (runtime half of the split
  1.3).** The `freeze-edge-record-v1-abi` change freezes the KEY ONLY --
  `(trust_namespace, span_identity)`. It does NOT freeze the tagged POSITIVE /
  EXPLICIT-NEGATIVE value shape: no message there represents one, so the earlier
  claim described prose rather than a contract. Task 2.20a above OWNS that shape, and
  this task implements everything over it: durable storage; idempotent replay of both value
  forms; a DIFFERING second candidate as an integrity conflict; an APPEND-ONLY
  conflict-resolution record that SELECTS one candidate as the projection while
  RETAINING the rejected one, with its own replay semantics and resolver fencing
  (same-selection replay, a later record selecting the other candidate,
  stale/future resolver, conflicting resolution records); MISSING repair requiring
  evidence that a backfilled record is the ORIGINAL authoritative pre-accept
  mapping; commit-before-any-accepted-record ordering; retention that outlives
  spool recovery, redrive, and lifecycle GC on a SAFETY rather than time basis; and
  the six lookup outcomes with their consumer transitions (FOUND; NOT_SCHEDULED as
  a durably committed negative, never a miss; TEMPORARILY_UNAVAILABLE leaving
  recovery pending with no terminal ACK; MISSING fencing the generation; CORRUPT
  and CONFLICTING quarantining the slot -- the last three each BLOCKING
  `RecoveryResolvedV1`). Without this task the durable requirement below has no
  implementer: the ABI change's 1.3 covers only schema and correlation, and 2.22
  CONSUMES the join rather than implementing the mapping.
- [ ] 2.21 **Scope generations to lanes and freeze one identity per lane.** Bind
  each generation to ONE (route profile, traffic class) lane drawn from the finite
  platform taxonomy, with its own open generation, sequence space, and reclamation
  state, so bulk, interactive, and recovery run CONCURRENTLY — not one open
  generation per agent. Freeze that lane's `network_scope_id` and authenticated
  agent identity for every record in the generation, and enforce single-scope as a
  stable AUTHENTICATED-AGENT invariant rather than by serializing scopes. A valid
  transition that merely requires rotation MUST answer `ROTATION_REQUIRED` as a
  RETRYABLE outcome so the producer can retry the same append; PERMANENT is
  reserved for a malformed lane or an unauthorized scope/agent identity.
  Closed-but-unreclaimed generations must remain independently recoverable under
  their own frozen identity. Test concurrent lanes, per-lane rotation isolation,
  and that rotation is retryable while unauthorized identity is permanent.
- [ ] 2.22 **Bind attribution to the accepted record in the spool
  (`usp2-05b-spool-attribution`; needs companion ABI task 1.3, plus local 2.10, 2.20 and 2.21).** It CONSUMES the durable assignment mapping that local task 2.20
  implements; without that dependency 2.22 could be checked against a mapping that
  does not exist. INVOKE the validators task 1.3 implements rather than restating their
  rules here -- 1.3 owns the correlation RULES and enforcement; THIS task owns the shared
  validated-attribution RESULT that wraps them: its type, its production from each body's
  own operands, and its consumption. FIRST verify the SEMANTIC
  JOIN, field by field, refusing the append as a PERMANENT error on any mismatch
  and never storing a mismatch as unattributable: attribution
  `contract_bundle_sha256` == the record's `EdgeOutputContractRef` bundle digest;
  `producer_assignment_id`/`run_id`/`run_shard` == its `EdgeProducerContext`;
`authority_epoch` == each APPLICABLE claim;
  `production_scope_id` + `scope_sha256` == the PRODUCTION scope ONLY;
  `source_scope_id` + `source_scope_sha256` == the SOURCE scope, compared ONLY when
  a source authorization is present -- source presence is INDEPENDENT of the
  ACTIVE/PASSIVE classification, and `ATTRIBUTED_PASSIVE` does NOT imply absent
  source authorization (recovery-control work is source-authorized with no produced
  range). Do NOT invent source claims to satisfy a comparison; for
  correlation, the per-variant operands the body actually carries (NOT a
  `run_id == context_id` equality, which is false); the attribution's SOURCE
  IDENTITY -- signed source KIND, `context_id`, `source_scope_id`, and
  `source_scope_sha256`, or their JOINT ABSENCE -- == the record's signed source
  authorization, rejecting partial combinations (ONE scope member cannot satisfy
  both sides: the canonical accepted record has production `digest32(0x75)` against
  source `sweepRangeSha()`); and for ACTIVE attribution
  `range_sha256` == the signed source range or the frozen contract-owned range
  derivation. THEN persist a sequence -> `RecoveryAttribution`
  relation under the FROZEN local binding grammar (own domain literal, numeric
  version, ordered transcript, active/passive discriminant, and the generation's
  TRUST NAMESPACE -- `network_scope_id` AND the authenticated agent identity, which
  neither lane nor spool generation subsumes -- alongside lane/spool generation
  identity, sequence, `event_id`, record hash, and the complete attribution tuple
  including both logical scope IDs; follow the EXACT transcript in the spec rather
  than this summary);
  checksum it independently of `record_bytes`; and make it readable when the
  record segment is corrupt. Dictionary/RLE encoding per segment is allowed. Both
  the record and its bound attribution MUST pass one durability barrier before the
  producer receipt is issued. Include a corrupt-segment test proving every lost
  sequence still resolves to its authority, and TWO distinct binding-failure tests: an
  APPEND-TIME semantic-join mismatch, which MUST be a permanent refusal with
  nothing stored; and LATER CORRUPTION of a binding that verified at append time,
  which MUST degrade the span to unattributable rather than to a wrong authority.
- [ ] 2.23 **Make restart resolution total over redundant commit evidence.**
  Store commit evidence with redundancy INDEPENDENT of the record segment, each
  copy carrying a MONOTONIC EVIDENCE GENERATION and a digest over its own
  contents, so copies can be COMPARED and not merely read. Never classify evidence
  discardable because its only marker copy became unreadable. Copies cannot be
  updated atomically with respect to each other, so a crash between writing copy A
  as COMMITTED and updating copy B leaves two READABLE copies in DIFFERENT states:
  agreeing valid copies -> the agreed state; ANY valid-copy DISAGREEMENT ->
  AMBIGUOUS ALLOCATED SLOT, regardless of which copy holds the higher generation
  (a higher generation proves only that one write landed, not that the append was
  acknowledged). Withhold the producer receipt until ALL required evidence copies
  AND the directory metadata that makes them discoverable are durable. Resolve
  every slot to exactly one outcome over wrapper, sequence high-water, producer
  idempotency/receipt binding, attribution binding, and record bytes:
  - evidence intact + bindings valid + bytes intact -> COMMITTED (sender-visible);
  - evidence intact + binding VERIFIES FOR SLOT + span REPRESENTABLE + bytes
    missing/corrupt -> ATTRIBUTED LOSS;
  - evidence intact + binding VERIFIES FOR SLOT + span NOT representable ->
    UNATTRIBUTABLE(`DISCRIMINATOR_UNREPRESENTABLE`);
  - evidence intact + attribution/wrapper/receipt binding missing or unverifiable
    -> AMBIGUOUS ALLOCATED SLOT;
  - evidence missing/corrupt where the append may have been ACKNOWLEDGED —
    including a high-water-allocated sequence with no marker, and a COMPLETE
    prepared record with no marker -> AMBIGUOUS ALLOCATED SLOT;
  - no evidence, no allocation, no complete record -> DISCARDABLE PREPARATION.
  An AMBIGUOUS ALLOCATED SLOT enters rollover coverage: ATTRIBUTED only when BOTH
  frozen predicates hold -- `binding_verifies_for_slot` AND `span_is_representable`.
  Verified-but-unrepresentable is UNATTRIBUTABLE(`DISCRIMINATOR_UNREPRESENTABLE`),
  which is the only path that makes that reason reachable at runtime; anything else
  is UNATTRIBUTABLE with the reason its frozen precedence selects. Add a
  verifies-but-unrepresentable regression. The sender exposes
  committed entries only; ambiguous/quarantined sequences are never reused; the
  scan is bounded by segment count. Tests: crash-injection at each barrier
  position; a single corrupted marker copy does not cause discard; an
  allocated-but-unmarked sequence reaches rollover coverage rather than vanishing;
  a SPLIT-WRITE crash injected BETWEEN writing copy A as COMMITTED and updating
  copy B yields AMBIGUOUS ALLOCATED SLOT (not COMMITTED, and not discarded) in
  both orderings; and no producer receipt is observable when any required copy or
  its directory metadata is not yet durable.
- [ ] 2.24 **Bound segments on keys, runs, AND manifest size.** Rotate on
  whichever binds first. Include an ALTERNATING-attribution test (keys A,B,A,B,…)
  proving the run bound triggers rotation where a distinct-key bound alone would
  not, and that the manifest for any single corrupt segment stays within the
  recovery grammar's page and byte ceilings.
- [ ] 2.25 **Preserve attribution across relocation.** Carry the bound relation
  through rollover, compaction, and scratch copies; re-verify the binding and
  re-checksum at the destination BEFORE the source becomes eligible for release;
  degrade a span that cannot be verified to unattributable rather than dropping or
  blindly copying it.
- [ ] 2.26 **Implement the reserve and allocation primitives (no coordinator
  dependency).** Reserve a budget excluded from producer admission and sized for
  the AGGREGATE a recovery must durably write — destination segment, attribution
  sidecar, BOTH journal copies, manifest/tombstone pages, old->new mapping, and
  filesystem metadata — multiplied by the bounded number of CONCURRENT recoveries.
  Provide the allocator, the unborrowable floor, and the admission refusal path.
  Make ENOSPC and EIO FAIL-STOP with explicit tests: exhausting the reserve or
  failing a barrier write must stop recovery deterministically, never silently
  proceed or partially delete. This task depends only on the spool, so it does NOT
  wait on the coordinator.
- [ ] 2.27 **Resume the saved rollover work as the agent recovery coordinator
  (needs companion ABI task 1.6a plus local 2.10 and 2.21-2.26).** The paged-manifest/tombstone implementation
  preserved at `rescue/usp13-v2-wip-20260725` (`9a3a701f`) already builds pages,
  links them, and defers every digest to `edgerecord`'s `ManifestPageDigest` /
  `ManifestRoot`. Convert it into the agent-owned coordinator that freezes, pages,
  hashes, and JOURNALS — never signs (no agent-signature ABI exists) and never the
  sender. It MUST emit the frozen `classification_spans` from 1.6a, not the
  retired `lost_ranges`/`affected` pairing.
  IT ALSO OWNS COARSENING, WHICH 1.6a ONLY CONSTRAINS. Merge only CONTIGUOUS LOST
  intervals whose COMPLETE oneof bodies are equal. Merging across a not-lost gap
  declares a preserved sequence lost, and because the widened span is PubAcked and
  can reach reclaim coverage, it can authorize reclaiming a sequence that survived.
  THE GUARD IS COORDINATOR-SIDE AND CANNOT BE A RECEIVER CHECK: a received page
  `[1,3]` is byte-identical whether it was formed legally from lost `[1,1] + [2,3]`
  or illegally from lost `[1,1] + [3,3]` while sequence 2 survived, and the wire
  carries no commitment to the pre-coarsening loss set. So the coordinator SHALL
  REFUSE THE MERGE at construction, against its DURABLE PER-SEQUENCE loss and
  classification evidence, and SHALL PRESERVE/JOURNAL that evidence so the refusal is
  auditable rather than asserted. The SAME construction-time-only argument applies to
  BODY EQUALITY: a merged `[1,2]` does not reveal whether its precursors carried one
  body or two, and an erased source body cannot be recovered from the final span, so
  equality is also enforceable only while the journaled evidence exists. Vectors --
  all four constructed from journaled per-sequence evidence, not from a final page:
  adjacent `[1,1]` + `[2,2]` with EQUAL bodies MERGES; `[1,1]` + `[3,3]` with
  sequence 2 preserved stays SEPARATE; adjacent ATTRIBUTED inputs differing in ONE
  identity or `range_sha256` member stay SEPARATE; adjacent `UNATTRIBUTABLE` inputs
  with DIFFERENT `reason` values stay SEPARATE.
- [ ] 2.28 **Integrate post-coordinator reclamation behind the coverage proof
  (needs 2.26 and 2.27).** A source segment is deleted only when a durable
  coverage proof accounts for EVERY UNRECLAIMED ALLOCATED SEQUENCE in
  `(durable_local_reclaim_watermark, sequence_high_water]` — not merely every
  committed slot — as either a FULLY COMMITTED,
  SENDER-VISIBLE destination slot — its own commit evidence covering the new
  wrapper/coordinates, rebound attribution, old->new mapping, destination
  high-water, and directory metadata — or a FROZEN loss span whose required
  recovery pages have PubAcked AND whose covered sequences are each backed by the
  coordinator's DURABLE PER-SEQUENCE loss evidence WHOSE JOURNALED CLASSIFICATION
  MATCHES THAT SPAN'S COMPLETE ONEOF BODY. A PubAcked span is NOT self-authorizing on
  either axis. On membership: a widened `[1,3]` is byte-identical whether sequence 2 was lost
  or preserved, so accepting the span alone as coverage would let an
  incorrectly-constructed merge buy deletion of a sequence that survived. On BODY: a
  span may cover a genuinely lost sequence while carrying a body DIFFERENT from the
  journaled classification, and deleting the record/binding evidence would destroy
  the proof of that mismatch. Add a WRONG-BODY vector -- journaled
  `UNATTRIBUTABLE(BINDING_CORRUPT)` versus a PubAcked attributed or different-reason
  span -- which SHALL block deletion. Check both relations before any destructive
  step. Journalling a manifest alone
  MUST NOT authorize deletion. Persist phase and delete INTENT before any destructive step and resume
  from it after a crash; retain both journal copies and page proofs until a
  durable `RecoveryResolvedV1`. Test: deletion blocked on an fsynced-but-
  uncommitted destination; deletion blocked without PubAck; crash mid-phase
  resumes from intent; a full-spool recovery completes against the reserve; and
  the SEQUENCE 9/10 case — sequence 9 committed, sequence 10 allocated and
  MARKERLESS in the same segment — where covering only sequence 9 MUST NOT
  authorize deletion, and sequence 10 MUST appear in the coverage proof rather
  than disappearing with no manifest entry.

## 3. Make the gateway a durable authenticated relay

- [x] 3.1 Add the dedicated mTLS bidirectional record RPC and advertise the
  `edge-records:v1` capability only when all required streams are writable. The
  RPC SHALL carry the small delivery wrapper plus each already encoded canonical
  `record_bytes` as an opaque bounded byte string, so transport decoding does
  not reconstruct or re-encode the semantic record before publication.
  LANDED: `ServiceRadarAgentGateway.EdgeRecordIngestServer` terminates the RPC,
  requires an authenticated `:agent` identity, gates `lane_open` on
  `ServiceRadarAgentGateway.EdgeRecordCapability` readiness, and is
  `JetStreamPublisher.publish_record/2`'s first production caller. See that
  module's moduledoc for its deliberately narrow scope: it does NOT discharge
  3.2 (full grant/contract verification), 3.4 (exact-byte/retained-memory
  binding), 3.5 (complete outcome-to-disposition mapping), 3.9 (transport-
  provenance stamping), or 3.10 (two-watermark reclaim state machine), all of
  which remain unchecked below and are required before 0.12 can close.
- [ ] 3.2 Derive installation trust, network scope, agent, gateway, and partition
  authority from the canonical deployment-CA/certificate-subject edge identity
  resolver without
  requiring SPIFFE; locally verify the production capability, exact effective
  grant, and any authorization-kind-required source authorization from the
  record, plus any renewable delivery capability from the wrapper. Reject
  identity, contract, scope, route/class, range, generation, expiry, or fence
  conflicts without a per-frame core/DB lookup. Generic telemetry, event, and
  inventory records
  SHALL NOT be required to invent a scanner collection capability. Permit
  stale-epoch immutable replay only under an exact
  event-ID/`record_sha256`-bound delivery capability and stamp it for audit-only/fenced
  projection.
- [ ] 3.3 PARTIALLY LANDED: **#4733** (`usp-19`) is MERGED into `usp-01-proposal`.
  Check what it actually delivered before starting -- duplicating it is how the
  earlier 22-PR chain accumulated, and its scope is NARROWER than this task.
  ALREADY LANDED in `ServiceRadarAgentGateway.JetStreamPublisher`: the publish
  request and PubAck parsing.
  (a) and (b) ARE NOW DONE and this text is updated to match, because the previous
  version described a publisher that no longer exists. `publish_record/2` takes ONLY
  the verified publication and DERIVES the route, so there is no arity that accepts a
  caller's subject, header, partition, or version; `Nats-Msg-Id` and
  `Sr-Edge-Delivery-Id` are asserted against the shared ABI vectors BY HEADER NAME, and
  `Nats-Expected-Stream` is set from the resolved route and re-checked against the
  returned PubAck. Refusal disposition was also corrected: only PROVEN poison is
  terminal, and an expected-stream refusal (`err_code` 10060) withholds source progress
  rather than routing to the DLQ.
  STILL OPEN, and REQUIRED before this task may be checked: (c)'s pipelining is
  now IMPLEMENTED -- `ServiceRadar.Edge.PublishPipeline` publishes asynchronously
  under the hard frame/byte/PubAck-deadline window, records out-of-order PubAcks
  through `ResolvedPrefix`, and exposes only the contiguous resolved prefix, with
  both closure criteria re-proven under concurrency. What is NOT yet true is that
  anything OFFERS to it: the gateway's per-lane session is task 3.1's mTLS
  bidirectional record RPC, and `JetStreamPublisher.publish_record/2` still has no
  production caller either, so the whole chain is exercised by tests rather than
  running. This task stays UNCHECKED on that basis; whether a pre-production
  implementation discharges (c) is a judgement for the change owner, not something
  to settle by ticking the box. The separate pools below are landed. The property this task relies on is that the
  transcript commits both `record_sha256` and the semantic digest, so a slot reused
  with different bytes gets a distinct Msg-Id. Limit NATS
  headers to transport concerns; do not duplicate the semantic envelope as
  dozens of ASCII/base64/hex headers. Use separately bounded NATS publisher
  connections/pools for bulk, interactive, and recovery traffic. Pipeline
  asynchronous publishes under hard outstanding frame/byte/PubAck-deadline
  windows rather than serializing every frame on one request; record out-of-
  order PubAcks and expose only the contiguous resolved edge prefix.
  CLOSURE CRITERIA, because bounded RESERVATIONS are not the hard window and an
  earlier pass nearly checked this task on that basis. Reservations, attempt
  phases, and per-lane pools are landed; what remains is 3.3's own, NOT 3.4's
  (exact-byte/retained-memory binding) and NOT 3.5's (outcome-specific PubAck
  validation and prefix advancement). This task MAY NOT be checked until BOTH
  hold, each covered by a scenario under `ingestion-routing`'s "Backpressure and
  fairness are bounded at every hop":
  (i) RESTART OVERLAP -- CLOSED, and now under CONCURRENCY as well. An earlier
  version of this note said the invariant was proven only against the serial
  publisher, which was the honest state at the time: with one caller able to hold
  exactly one outstanding request, "old and replacement requests together cannot
  exceed the grant" was a claim about a single request. `PublishPipeline` now
  drives several workers through one window, and the criterion is exercised with
  FOUR requests on the wire when the generation dies -- every charge survives, and
  the replacement transport is refused for want of capacity rather than handed a
  fresh grant. A lane restart MUST NOT reopen capacity that an in-flight request
  still occupies.
  How it is discharged: the lane is split into a STABLE accountant and a
  REPLACEABLE transport under `LaneSupervisor`'s `:rest_for_one`, accountant
  FIRST. Transport death therefore cannot reach the ledger -- a replacement
  inherits the credits the previous generation consumed rather than a fresh
  grant. Each attempt records the transport `generation` it was issued on, and
  when a generation dies `PublishWindow.fence_generation/2` ends its attempts
  while KEEPING their reservations charged: generation death proves the request
  cannot complete on that transport, and proves nothing about whether the bytes
  reached the broker. Affected publications become idle-but-charged and may retry
  on the charge they already hold. Only a validated resolving PubAck releases
  credits.
  The converse is fail-closed: a replaced accountant has an empty ledger, so
  `:rest_for_one` terminates the transport subtree first, and the accountant
  additionally starts CLOSED -- `admit` returns `:no_transport` until a new
  generation registers, which cannot happen until the previous send capability is
  gone.
  (ii) POST-HANDOFF FENCING -- CLOSED. Once a reservation is handed to a caller, a
  retry MUST NOT be admitted until the previous attempt is fenced by its REQUEST
  (owner, start, termination). A passed deadline or an absent PubAck is NOT
  sufficient evidence: neither distinguishes "never sent" from "in flight",
  "delayed", or "acknowledged with the acknowledgement lost". Correlation from 3.5
  may assist RECOVERY but does not discharge this obligation.
  How it is discharged: `PublishWindow` records the OWNER pid at `admit/5`; the
  START is the `:pending` -> `:active` transition in `activate/2`, before which no
  request can have been issued; TERMINATION is the owner itself calling
  `attempt_failed/3` or `settle/4`, both of which match on `^owner`. Under
  concurrency this is carried rather than re-argued: `PublishPipeline` hands out
  WORK and never reservations, so each worker owns its own attempt end to end, and
  a retry offered by a genuinely separate process while an attempt is in flight is
  refused -- which is the case this criterion was written for and which a serial
  publisher could not produce.
  `PublisherPool` takes the owner from the call's `from`, so a caller has no
  parameter in which to name a different process. `expired/2` stays reports-only
  and a sweep holding `{key, token}` cannot act on it -- the deadline is now
  observable but never authorising. Owner DEATH is deliberately NOT treated as
  termination, because a process can die after its request reached the socket;
  that leaves a dead owner's reservation charged.
  CORRECTION, now that (i) is implemented: an earlier version of this note said (i)
  would free such a reservation. It does not. Fencing fires on the death of a
  TRANSPORT GENERATION, not on the death of an owner, so an owner that dies while
  its transport stays healthy still leaves its reservation charged with no attempt
  against it. That is deliberate -- owner death is not evidence the record was not
  published -- but it is a real retention gap and it remains OPEN. Bounding it needs
  evidence that the specific request terminated, which is the correlation work in
  3.5, not a supervision change here.
- [ ] 3.4 Bounded-decode and verify the bounded binary record against the mTLS
  session, grant, registry, route, cost, size, and digest, but publish the exact
  `EdgeDeliveryFrameV1.record_bytes` unchanged to JetStream, never the delivery
  wrapper or a larger spool-record encoding. Supply both immutable-semantic and
  delivery/placement digests to the bounded audit/ledger path without adding
  gateway-local durable state; bound asynchronous publication
  by frame count, encoded bytes, and measured retained gateway memory including
  the original record binary, bounded decode state, minimal headers, NATS
  request state, mailboxes, and TLS buffers. Evict volatile per-sequence
  disposition evidence only after the ordered cumulative `EdgeDeliveryAckV1`
  covering it is successfully written, and prove the retained-memory bound on a
  long-lived lane even when that written ACK is lost and its slots replay or an
  early retryable gap prevents the cumulative prefix from advancing. Add a golden
  test proving the exact
  `EdgeRecordV1` bytes fsynced inside the agent spool equal the JetStream body.
- [ ] 3.5 Compute the INTERNAL publication outcome, then MAP it to the generated
  wire disposition returned on the RPC. There are SIX internal outcomes and FIVE
  generated `EdgeRecordDispositionKind` members, so the mapping is not one-to-one:
  `primary_publication` -> `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE`,
  `audit_publication` -> `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY`,
  `quarantine_publication` AND `security_quarantine_publication` -> BOTH
  `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE`, `permanent_rejection` ->
  `EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT`, and `retryable_rejection` ->
  `EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE`. `EdgeDeliveryAckV1` carries the
  GENERATED member only; the internal names are never wire values. Because both
  quarantine variants collapse onto one wire member, the SECURITY-QUARANTINE ROUTING
  PATH SHALL be preserved separately -- a compromise-revoked key must still reach the
  security-quarantine DLQ, which the wire disposition alone cannot express.
  Advance the contiguous resolved prefix only across
  primary-stream PubAcks, audit-publication PubAcks, quarantine-publication DLQ
  PubAcks, SECURITY-quarantine DLQ PubAcks, and permanent-rejection reject-audit DLQ
  PubAcks (each only after its required PubAck). The security-quarantine PubAck is
  listed EXPLICITLY: it resolves like any other accepted disposition, and omitting it
  from an exhaustive list would let a compromise-revoked record reach its DLQ and then
  pin the resolved prefix forever. Never advance across a `retryable_rejection` or an
  unresolved sequence; withhold progress on NATS unavailability, stream refusal,
  or publisher saturation. After volatile evidence eviction, duplicate replay and
  reconnect MUST deterministically reproduce the same disposition and contiguous
  prefix through the same validated idempotent publication and PubAck path, without
  subscribing to stored records or recovering private gateway state; evidence
  eviction MUST NOT surface as an ambiguous disposition state to the agent.
- [ ] 3.6 Ensure this lane never enters `StatusBuffer`, never acknowledges an
  ERTS/Core NATS handoff as durable, and remains stateless across restarts.
- [ ] 3.7 Add byte-bounded fair queues and rate limits across network/site scope,
  agent, producer assignment, run/execution, and attested traffic class so a
  noisy stream cannot starve other edge sessions before JetStream partitioning.
  Preserve separate bulk, interactive, and recovery credits through every
  gateway queue; output-contract or package cardinality MUST NOT allocate more
  lanes, connections, subjects, streams, consumers, or processes.
- [ ] 3.8 Load the same signed output-contract/route registry epoch as the agent
  and EventWriter. Reject unknown, revoked, digest-mismatched, route-conflicting,
  candidate, partially activated, or downstream-not-ready contracts before
  PubAck; report signed readiness for an atomic epoch switch and fence stale
  active generations. Continue planned-retirement backlog only under its exact
  draining bundle and watermark, but hold security-revoked backlog. Verify the
  provenance stamped by the trusted agent sink against the authenticated
  session and never trust guest-supplied subject, agent, scope, class, cost, or
  database destination claims.
- [ ] 3.9 Stamp the `Sr-Edge-Transport-Provenance` header on every gateway publish,
  alongside `Nats-Msg-Id` and `Sr-Edge-Delivery-Id`, over the edge slot. Its slot
  kind, framed members, delivery-proof presence rule, `delivery_mode` constants, and
  `route_map_version` validity are the ABI-frozen grammars from task 1.14 and are NOT
  re-declared here. This task owns the RUNTIME behaviour: computing each header from
  the verified record, stamping it on the publish, and treating a missing, duplicate,
  or unknown-version provenance header as a distinct `provenance_missing`
  quarantine rather than silent acceptance. Assert the stamped headers against the
  ABI-owned vectors; do NOT generate a second cross-language corpus.
- [ ] 3.10 Implement the two-watermark state machine and keep the two watermarks
  strictly separate. The REMOTE terminal-disposition-through watermark
  (`EdgeDeliveryAckV1.resolved_through_sequence`) advances only across resolved
  terminal dispositions per task 3.5 and never references any agent-local action.
  The SEPARATE agent-local reclaim watermark advances only on the agent's own
  durability/quarantine reclaim actions and governs spool reclamation. A resolved
  remote disposition MUST NOT by itself reclaim agent spool, and an agent-local
  reclaim MUST NOT advance the remote resolved prefix; the
  `EdgeDeliveryAckV1.resolved_through_sequence` comment SHALL describe ONLY the
  remote watermark. Reporting or evicting gateway disposition evidence advances
  NEITHER watermark and MUST NOT authorize agent reclaim. Add Go/Elixir
  cross-language golden vectors mapping fixed
  disposition/reclaim event sequences to the expected remote and agent-local
  watermark values.

## 4. Provision the JetStream durability boundary

- [ ] 4.0 Reconcile runtime NATS provisioning with the completed single-customer
  control-plane split: audit and remove customer-prefixed runtime subjects,
  per-customer accounts/capacity cells, shared-platform imports/mirrors, database
  routing from subject prefixes, and synthetic `default`-customer inference.
  Seal and drain any declared legacy prefixed backlog under an explicit watermark;
  quarantine ambiguous records rather than inventing authority.
- [ ] 4.1 Add fixed installation-local, versioned platform route-profile plus
  bulk/interactive, result-recovery, and class-preserving result-DLQ subjects
  with 64 stable logical data/DLQ
  partitions and documented versioned hashes. Define a complete non-overlapping
  `(traffic_class, route_profile, pNN) -> physical stream` map shared by
  gateways and
  consumers, exact subject/credential ACLs, installation admission quotas, and
  no authoritative cross-account result mirror/import. `network_scope_id` is a
  signed site/address namespace, not a broker-account or capacity-cell key.
- [ ] 4.2 Provision separate file-backed physical stream shards by the finite
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
- [ ] 4.3 Define the authoritative durability domain for hub and NATS-leaf
  deployments. The gateway remains the sole NATS publisher for agent-originated
  records and plugins/add-ons receive no NATS credentials. Document whether an
  edge-local stream may produce the authoritative PubAck and its explicit
  replication/site-loss RPO; do not call a leaf PubAck durable if the admitted
  RPO requires hub replication first.
- [ ] 4.4 Provision initially one registry-dispatching shared persistence durable
  per physical stream shard/route profile with byte-bounded pulls, bounded
  ack-pending, unlimited
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
- [ ] 4.6 Give cluster-local durable producers the same canonical
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

## 5. Implement replay-safe domain projectors

- [ ] 5.1 Add strict envelope/domain decoders that validate version, checksum,
  the semantic-envelope digest under the FROZEN grammar owned by the edge record v1
  wire ABI (not restated here), and minimal transport
  headers, actual streaming-decompression output and
  ratio, trailing frames, protobuf depth, projected rows, count/string/byte
  bounds, observation time against the original signed production interval and,
  when the authorization kind requires one, its source-action/collection/
  execution interval plus attested clock tolerance (not a symmetric gateway-
  receipt age window), homogeneous contract-specific authorization context,
  decoded execution/check/command/range equality, and every scan target's
  authoritative plan/range membership before allocating or writing. Persist and
  independently verify bounded canonical production capability bytes/key ID plus
  any required source-authorization bytes/key ID; a generic contract with no
  source action SHALL validate without inventing collection proof.
- [ ] 5.2 Add a retirement-bucket-partitioned ingest ledger keyed ONLY by
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
  HOP ASN PROJECTION IS OWNED HERE, assigned by `freeze-edge-record-v1-abi` task 1.5-e. The
  admitted semantics are defined by that change's requirement "An MTR hop's ASN is diagnostic
  enrichment, not an allocation claim" and are NOT restated here. This task owns only how the
  admitted values are stored:
  - `mtr_hops.asn` is currently `INTEGER` (signed 32-bit), created at
    `elixir/serviceradar_core/priv/repo/migrations/20260228090000_create_mtr_traces_hypertables.exs:104`.
    It cannot hold the upper half of `uint32`, which includes the ENTIRE 32-bit private-use
    range (4200000000-4294967294). Projection SHALL use a 64-bit integer column, or the
    storage width silently narrows the frozen ABI.
  - Zero means unavailable, so it SHALL be projected as SQL `NULL` rather than as `0`, which
    would otherwise read as a real observation of AS 0.

  NANOSECOND->MICROSECOND PROJECTOR INTEGRATION AND SCHEMA ARE ALSO OWNED HERE, assigned by
  `freeze-edge-record-v1-abi` task 1.5-c. That change fixes the MATHEMATICS (the canonical value
  names the CONTAINING microsecond bucket, computed without forming an unrepresentable
  intermediate), the ORDER relative to the two contract hashes, and the consumer list. It does
  NOT wire anything up. This task owns:
  - CALLING the conversion at the projection boundary for `mtr_traces.time` and `mtr_hops.time`
    -- each `TIMESTAMPTZ`, each the AUTHORITATIVE OBSERVATION TIME, canonicalized for storage
    and ordering. NEITHER IS THE PARTITION IDENTITY: `trace_identity_time` is, it is UUIDv7
    MILLISECOND derived, and it SHALL NOT be routed through the nanosecond canonicalizer.
    `mtr_hops` references the trace's physical identity rather than re-deriving one. There is
    no PRODUCTION caller today -- the only importer of `go/pkg/edge/projection` is
    1.5-c's shared-vector suite, which exercises the helper without wiring it into any
    projector.
  - Any DDL the conversion implies, including retaining the original signed nanosecond value
    separately wherever sub-microsecond fidelity is part of the domain or audit contract.
  - `trace_identity_time` is NOT part of this conversion. It derives from the UUIDv7
    MILLISECOND timestamp, not from a wire nanosecond, and must not be routed through the
    nanosecond canonicalizer.

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
- [ ] 5.6 Implement the idempotent recovery consumer with DURABLE KEYS that contain
  IDENTITY ONLY, never comparison values: the page key is
  (`network_scope_id`, `agent_id`, `recovery_id`, `page_index`) and it COMPARES one
  fixed page digest; the recovery key is (`network_scope_id`, `agent_id`,
  `recovery_id`) and it COMPARES the COMPLETE immutable tombstone identity --
  abandoned/prior spool, `new_spool_id`, manifest root, and page count. There is NO
  `coarsened` value to compare: 1.6a removes it from the tombstone AND from the page
  (tag `7` reserved), because its set/clear rule could not be made deterministic. The
  manifest root remains the commitment to the pages.
  `new_spool_id` is signed by the tombstone scope, so leaving it out lets a
  same-key replay naming a DIFFERENT destination look identical. Putting the digest or root INTO the key defeats the idempotency it exists
  for: a replay carrying a different digest would miss the row and INSERT a second
  one instead of raising an integrity conflict. Broker publication IDs MAY still
  include content digests, so conflicting bytes reach the consumer at all. Add
  same-key/different-page-digest, same-key/different-root,
  and same-key/different-new-spool regressions. There is deliberately NO
  same-key/different-coarsened regression: after 1.6a no such field exists on either
  the tombstone or the page.
  ALSO OWNED HERE: `RecoveryResolvedV1` replay semantics -- its durable key, what is
  COMPARED, and the verdict when the same recovery/root arrives with a different
  `applied_through_sequence` (conflict, monotonic progress, or valid replay), plus
  whether `resolved_at_unix_nano` participates in the comparison. Calling the
  consumer idempotent without freezing those is not a definition. This is
  deliberately NOT frozen in 1.6a: 1.6a freezes the SCALAR'S MEANING, this task
  owns its replay behaviour. The
  tenant/agent namespace stays in BOTH keys; the recovery stream is shared. It
  SHALL NOT be keyed on a singular `lost-range`: after 1.6a the loss is the ordered
  span union and no single interval describes it. Persist chained
  pages idempotently, validate the bounded terminal copy manifest, then in one
  transaction persist the loss audit, mark affected attempts/ranges partial or
  lost, fence unsafe authority, and enqueue scheduler retry intent before ACK;
  retain durable state and alert if recovery-stream expiry approaches. After
  commit, expose/emit a signed idempotent `RecoveryResolvedV1` bound to recovery
  ID, manifest root, and applied state; a recovery-stream PubAck alone MUST NOT
  authorize agent journal deletion. Handle the three classification spans
  distinctly: `ATTRIBUTED_ACTIVE` marks its produced range partial/lost;
  `ATTRIBUTED_PASSIVE` marks the delivery interval lost WITHOUT asserting a
  produced range; `UNATTRIBUTABLE(reason)` MUST durably record the span in the
  loss audit/quarantine store, FENCE the affected agent/scope generation, and
  enqueue scheduler reconciliation, and MUST BLOCK `RecoveryResolvedV1` for that
  recovery until those actions are durably committed. Never treat an
  unattributable span as merely uncounted, and never infer passive from record
  kind -- lost terminal/lifecycle evidence is unattributable when its attribution
  cannot be proven.
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
  exhaustion. Add an integration test proving (a) whole-window retirement drops
  old delivery-slot/sweep-batch-slot/agent-terminal-slot/service-ingress-slot and
  ledger partitions by a single ordered-time-window range drop/detach WITHOUT
  touching current-window partitions, and (b) newly bound slots in the current
  window land in the correct `hash_subshard`.
- [ ] 5.10 Add registry-driven dispatch that verifies the exact output contract,
  complete bundle digest, cost model, route, and approved platform-owned
  validator/projector before decode. Preload candidate bundles and publish
  signed readiness, then atomically select only the control-plane active epoch;
  retain exact draining bundles for planned-retirement backlog and hold
  security-revoked records. Recompute decoded row/write cost before credit
  refund or side effects, reject underdeclared/overflowing cost without partial
  projection, and distinguish deployment-not-ready pause from deterministic
  payload poison. Unknown contracts never fall back to dynamic code or generic
  SQL.
- [ ] 5.11 Implement the DIRE-aware inventory projector for bounded pages and
  terminal manifests. Stage each immutable page idempotently by source instance
  and scheduler-owned generation with no current/absence side effect; allow an
  early terminal to wait pending; validate every ordinal/hash/object key and
  ordered root; then atomically fence older generations and swap the current
  snapshot pointer. Preserve provider ownership and stable source keys, activate
  absence/deletion only for a valid consistency-proven complete terminal, keep
  prior current inventory on partial/aborted/missing/conflicting runs, poison
  late or conflicting terminals, and boundedly GC abandoned staging after its
  repair horizon.
- [ ] 5.12 Implement approved extension-record projection through the bounded
  declarative contribution registry with database-enforced idempotency, strict
  row/write limits, typed validation errors, and the same CNPG credit/DLQ/replay
  controls as built-in contracts. Reject any package attempt to execute code,
  SQL, DDL, or choose physical storage at ingestion time.
- [ ] 5.13 Implement the projection-fence race handler as the final, first-match
  pipeline step. In the SAME transaction as the domain effects and the ledger row,
  `SELECT ... FOR UPDATE` / conditional-UPDATE the fence/assignment row: a current
  fence commits `authoritative_apply`; a stale/advanced fence commits an atomic
  `ledger_only` with NO domain projection. Transport/conflict/poison decisions sit
  ABOVE this downgrade, so a stale fence never masks a conflict or poison and a
  conflict/poison never authoritatively projects. Database unavailability at any
  commit point yields NO ACK and NO TERM/poison; pause new pulls and let the
  reservation lapse at the bounded processing deadline via `AckWait` expiry
  (redelivery, not counted toward finite `MaxDeliver`), with agent ownership NOT
  restored. Add Go/Elixir cross-language golden vectors for concurrent
  current-vs-stale fence ordering producing deterministic
  `authoritative_apply` / `ledger_only` outcomes.
- [ ] 5.14 Add a concurrent CNPG fence-activation-vs-projection race integration
  test that runs a projection transaction and a fence-activation (epoch bump)
  concurrently against a live CNPG instance and asserts the projection either
  commits authoritative rows under the read epoch (`authoritative_apply`) OR
  atomically downgrades to `ledger_only` when the fence advanced first -- never a
  stale `authoritative_apply` and never a lost ledger row.

## 6. Integrate scheduling and producer migrations

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
- [ ] 6.6 Compile imported Wasm/native package output requests into explicit
  assignment grants only after contract, capacity, capability, and downstream
  readiness approval. Retire grants monotonically and stop new output
  immediately; planned retirement MAY retain delivery-only authority for
  already-spooled immutable records under the exact draining bundle, while a
  security revocation MUST hold matching backlog until an approved safe
  replacement/redrive or waiver exists.
- [ ] 6.7 Migrate durable Wasm plugin and native add-on outputs contract by
  contract. Compare authoritative record counts/digests and projected state against
  the legacy path, then disable the corresponding JSON/base64, lossy queue, or
  specialized relay; never run two authoritative projectors for one event.
- [ ] 6.8 Migrate Armis inbound discovery to inventory pages/manifests and prove
  stable provider ownership, duplicate-page replay, crash/resume, partial-run
  non-deletion, complete-run absence semantics, and million-device bounded
  memory. Keep the outbound Armis updater in the idempotent command/Oban plane;
  only its receipts/audit/telemetry may use this record plane.
- [ ] 6.9 Publish SDK examples for a bounded scanner, continuous telemetry
  producer, inventory snapshot producer, and large integration run. Examples
  MUST use the producer sink and approved contracts, handle `WOULD_BLOCK`, and
  MUST NOT construct transport frames or receive broker/database credentials.

## 7. Roll out and retire legacy paths

- [ ] 7.1 Deploy additive schema, database identity/slot keys, class-separated
  streams/consumers/DLQ, registry, sink, gateway publisher, and separately
  governed cluster-local publisher support.
  Enforce a minimum producer-plane agent and gateway version before assigning
  affected new work; do not build an unpatched-agent bridge, a patched legacy
  sender, or a new-execution legacy-format selector. Upgrade each enabled cohort
  as a unit and drain only data accepted before its cutover.
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
  Prove read/graph parity before switching reads; retain read-only legacy
  consumers solely to drain already-accepted backlog to the persisted
  pre-cutover watermark.
- [ ] 7.2 Canary by explicit agent/cohort configuration and compare event counts,
  execution totals, current device state, OCSF rows, scanner/banner metrics,
  MTR/AGE field fidelity, mapper promotion, per-agent availability, ad-hoc rows,
  latency, memory, lag, storage, network-scope-safe UI/SRQL reads, and retained-history
  graph parity against a non-writing legacy shadow.
- [ ] 7.3 Exercise the supported minimum-version and offline-agent upgrade
  policy; older binaries receive no affected new assignments and must upgrade
  before rejoining the cohort. Keep new-format consumers/readers until all
  stream backlog and agent spools are drained. Rollback stops new admissions and
  reverts read selection only after compatible consumers have drained or remain
  available; it never converts a durable v1 record back to JSON.
- [ ] 7.4 Remove agent-side duplicate sweep/MTR metric projections only after
  real-time consumer and persistence parity is demonstrated.
- [ ] 7.5 Remove legacy JSON `GatewayServiceStatus{source: "results"}` emission,
  decode, ERTS routing, and volatile fallback only in a separately gated
  cleanup release.
- [ ] 7.6 Update architecture, operations, capacity, installation-local NATS,
  network-scope identity, result-state, and failure-recovery documentation after
  the conflicting active proposals are withdrawn, amended, or rebased in tasks
  0.5, 0.9, and 0.11.
- [ ] 7.7 Roll out each registry epoch as candidate, collect target-cohort agent,
  gateway-route, and EventWriter readiness, and switch it active atomically
  before issuing producer grants. Canary output contracts independently, seal
  planned-retirement grants, and retire their historical bundle only after
  agent-spool, JetStream, DLQ, redrive, and receipt-binding watermarks drain.
  Rollback MUST fence the failed epoch and MUST NOT reactivate a
  security-revoked bundle.
- [ ] 7.8 Remove durable Wasm output from base64/JSON `plugin_result`, native
  durable output from drain-before-send telemetry queues and specialized OTLP
  relay ownership, and Armis inventory from JSON/ERTS/coalescing only after
  contract-by-contract shadow parity and rollback drains complete. Preserve
  explicitly ephemeral status/counter paths without describing them as durable.

## 8. Verify correctness, scale, and failure behavior

- [ ] 8.1 Add unit, fuzz, property, and cross-language tests for sizing,
  boundaries, unknown versions, corrupt checksums, decompression bombs,
  identity spoofing, sequencing, cumulative dispositions, spool recovery,
  changed bytes or schema/row-cost/epoch/authorization/range semantic-envelope fields
  under one event ID inside and outside the broker dedup window,
  a same-slot / same-semantic-digest / different-`record_sha256` reuse inside the
  broker dedup window that MUST receive a distinct `Nats-Msg-Id`, MUST NOT be
  suppressed by JetStream deduplication, and MUST be rejected by EventWriter's
  delivery-slot binding as a transport-integrity violation, while a byte-identical
  same-lane retry IS deduplicated,
  conflicting batch-slot bindings in both arrival orders with immutable
  conflict state, exclusion of protocol-invalid alternatives, and fenced repair,
  delivery-slot reuse with changed semantics, terminal-slot conflicts and data
  outside a closed `[1,N]`, production/source/delivery proof expiry and fencing,
  source-authorization-optional plugin and continuous telemetry records,
  out-of-range targets, mixed-context MTR batches,
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
  cost fixtures, exact record bytes, minimal transport headers, capability
  rotation/revocation, and deterministic IDs.
- [ ] 8.2 Add integration tests for continuous scan/data/completion interleaving,
  mixed agents, gateway/NATS/core/CNPG restarts, PubAck loss, five forced
  redeliveries, a greater-than-64-MiB logical execution carried as independently
  durable frames no larger than the frozen `MaxFrameBytes` bound, minimum-version assignment
  rejection, gateway/consumer poison DLQ PubAck loss, bulk poison at DLQ and
  quarantine capacity while an interactive failure still obtains its reserved
  disposition path, fleet-wide bad-decoder circuit/pause/repair/redrive,
  indefinite transient retries, stale sessions/assignments, key rotation with
  queued frames, stale-gateway installation stream-map migration, concurrent
  zero-window bulk RPC/NATS publisher saturation while separately connected
  interactive and recovery traffic progress, maximum-record/minimal-header compression frames
  with delayed PubAcks and measured retained gateway memory, an ordered cumulative
  ACK written and then lost followed by duplicate replay to the same gateway and
  reconnect replay to a replacement gateway, bounded retained evidence across a
  long-lived lane with an early retryable gap while later PubAcks arrive, concurrent
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
- [ ] 8.6 Add Go/Elixir/Wasm golden and adversarial tests for output-contract
  refs, registry bundles, producer context, inventory pages/manifests, and
  extension records. Prove plugins cannot spoof agent, package, assignment,
  source, network scope, route, class, partition, cost, subject, or destination;
  the sink either derives/replaces trusted fields or rejects before spool
  acceptance, and EventWriter rechecks body claims and recomputes cost before
  side effects. Exercise unknown and underdeclared cost models, arithmetic
  overflow, candidate/partial/stale registry activation, planned-retirement
  drain, security revocation with queued backlog, failed activation rollback,
  and stale component fencing without poisoning otherwise valid traffic.
- [ ] 8.7 Prove uncertain local receipts return the same durable identity,
  same-key/different-`submission_sha256` reuse is an immutable conflict, post-GC retry on a
  closed handle cannot create a new event, native reconnect resumes without
  loss, and a complete consistency-proven inventory terminal applies absence
  once while missing-page/partial/invalid/stale/conflicting terminals apply
  none. Benchmark removal of Wasm base64/JSON allocation and Armis whole-run
  coalescing. Show a maximum-size plugin/inventory run cannot starve interactive
  or recovery traffic and that thousands of approved package contracts do not
  create proportional lanes, subjects, streams, consumers, connections,
  processes, or RAFT groups.
