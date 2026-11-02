# Tasks: Harden the edge-record transport and gateway

## 1. Moved from `unify-sweep-results-proto`

Each task keeps its original text and number from `unify-sweep-results-proto`; its last line states what remained
when it moved.

- [ ] 1.1 (was `unify-sweep-results-proto` 1.16) Runtime integration of the publication-identity codec at the trust
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
  Remaining as of the move (2026-11-02): `ServiceRadar.Edge.WireDecode` now has
  production callers (gateway authorization, core projections). The custom
  edge-ingest `GRPC.Codec`, transport-level length check before buffering and
  the compression refusal are not built.
- [ ] 1.2 (was `unify-sweep-results-proto` 2.5) Add a bounded bidirectional gRPC sender with independent finite
  platform-owned bulk/interactive and reserved recovery-control sequence/credit
  lanes, cumulative resolved
  watermarks, accepted/rejected dispositions, nonce-fenced opening handshake,
  bounded frame/byte windows, reconnect/replay, stale-session ACK rejection,
  retry backoff, capability negotiation, collection-expiry-safe
  delivery-capability renewal, and permanent-rejection quarantine. Use an
  independent RPC per lane plus separately pooled bulk, interactive, and recovery
  HTTP/2 connections with reserved connection-level windows; test a zero-window
  stalled bulk connection while interactive and recovery frames progress.
  PARTIALLY LANDED: commit `2c816c114e` added
  `go/pkg/edge/sender`, a minimum single-lane sender over the spool with
  credit-based flow control, wired into `go/cmd/agent`. Per-lane RPCs and pools,
  reconnect/replay and capability renewal are not implemented, so this task
  stays unchecked. Permanent-rejection quarantine landed in its interim form
  (see design "Interim local quarantine"): reclaim copies each permanently
  rejected record into a bounded lane quarantine before it checkpoints past the
  segment, so one rejection no longer stops the spool from reclaiming.
  Remaining as of the move (2026-11-02): a single-lane sender with reconnect replay
  and stale-nonce ack rejection. Per-lane RPCs and pools and delivery-capability
  renewal (M2.0g) remain.
- [ ] 1.3 (was `unify-sweep-results-proto` 3.3) PARTIALLY LANDED: **`usp-19`** is MERGED into `usp-01-proposal`.
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
  (c)'s pipelining is IMPLEMENTED and now has a PRODUCTION OFFERER.
  `ServiceRadar.Edge.PublishPipeline` publishes asynchronously under the hard
  frame/byte/PubAck-deadline window, records out-of-order PubAcks through
  `ResolvedPrefix`, and exposes only the contiguous resolved prefix, with both
  closure criteria re-proven under concurrency. Task 3.1's
  `ServiceRadarAgentGateway.EdgeRecordIngestServer` offers every verified delivery
  frame to its class's pipeline instead of publishing it synchronously per frame;
  the gateway starts one pipeline LAST in each `LaneSupervisor`, handing in
  `JetStreamPublisher.publish_record/2` as its publisher. Each ack is built from
  the outcomes the pipeline pushes to the lane's owning stream, and is sent only
  when the contiguous watermark moves, as the contiguous disposition run the
  agent's `edgerecord.ValidateAck` requires. Proven-permanent decode/integrity
  rejections are recorded in the prefix through
  `PublishPipeline.reject_permanent/3` so they cannot wedge the lane, and retryable
  outcomes still withhold the ack. This task stays UNCHECKED: whether this
  discharges (c) is a judgement for the change owner, not something to settle by
  ticking the box. The separate pools below are landed. The property this task relies on is that the
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
  (i) RESTART OVERLAP -- CLOSED, and now under CONCURRENCY as well; its
  composed-level observation landed in
  commit `76d6eda5e5` (see the note at the end of
  this task). An earlier version of this note said the invariant was
  proven only against the serial
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
  (ii) POST-HANDOFF FENCING -- CLOSED; its composed-level observation landed in
  commit `76d6eda5e5` (see the note at the end of
  this task). Once
  a reservation is handed to a caller, a
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
  COMPOSED OBSERVATION (0.12 Groups E and F):
  commit `76d6eda5e5` makes the vertical slice
  observe (i) and (ii) against the lane ledger, so 0.12 records no deferral
  against this task. Group E holds three requests in flight with PubAcks
  withheld and kills the `:bulk` transport: a replacement generation accepts
  while every request owner is alive and the same accountant still charges their
  reservations, and after each owner's termination the retry is a new attempt on
  the same reservation while new work is admitted within the unchanged grant.
  Group F shows the identical retry refused while the first attempt is active
  under its living owner, and admitted once after that owner reports
  termination. This does not check this task: (c) above is still open.
  Remaining as of the move (2026-11-02): remaining: the owner's decision on (c) and
  the dead-owner reservation gap, which needs 3.5's request correlation.
- [ ] 1.4 (was `unify-sweep-results-proto` 3.4) Bounded-decode and verify the bounded binary record against the mTLS
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
  Remaining as of the move (2026-11-02): exact bytes are proven (vertical slice Group
  B: the spool record equals the JetStream body). The retained-memory bound on a
  long-lived lane is not proven.
- [ ] 1.5 (was `unify-sweep-results-proto` 3.7) Add byte-bounded fair queues and rate limits across network/site scope,
  agent, producer assignment, run/execution, and attested traffic class so a
  noisy stream cannot starve other edge sessions before JetStream partitioning.
  Preserve separate bulk, interactive, and recovery credits through every
  gateway queue; output-contract or package cardinality MUST NOT allocate more
  lanes, connections, subjects, streams, consumers, or processes.
- [ ] 1.6 (was `unify-sweep-results-proto` 3.9) Stamp the `Sr-Edge-Transport-Provenance` header on every gateway publish,
  alongside `Nats-Msg-Id` and `Sr-Edge-Delivery-Id`, over the edge slot. Its slot
  kind, framed members, delivery-proof presence rule, `delivery_mode` constants, and
  `route_map_version` validity are the ABI-frozen grammars from task 1.14 and are NOT
  re-declared here. This task owns the RUNTIME behaviour: computing each header from
  the verified record, stamping it on the publish, and treating a missing, duplicate,
  or unknown-version provenance header as a distinct `provenance_missing`
  quarantine rather than silent acceptance. Assert the stamped headers against the
  ABI-owned vectors; do NOT generate a second cross-language corpus.
  Remaining as of the move (2026-11-02): the gateway stamps
  `Sr-Edge-Transport-Provenance` (`JetStreamPublisher`), and EventWriter decodes
  it (`PublicationIdentity.decode_transport_provenance/1`). Not verified: a
  distinct `provenance_missing` quarantine for missing or duplicate headers.
- [ ] 1.7 (was `unify-sweep-results-proto` 3.10) Implement the two-watermark state machine and keep the two watermarks
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
  Remaining as of the move (2026-11-02): the agent sender keeps the remote watermark
  separate from local reclaim (package `sender` doc), but `go/pkg/edge/gwprefix`
  has no importers and there are no cross-language golden vectors.
- [ ] 1.8 (was `unify-sweep-results-proto` 5.13) Implement the projection-fence race handler as the final, first-match
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
  Remaining as of the move (2026-11-02): `SweepProjection` takes the assignment row
  `FOR SHARE` in the ledger transaction and refuses a fenced assignment
  (`:sweep_assignment_fenced`); it does not commit `ledger_only`, and there are
  no cross-language vectors.
- [ ] 1.9 (was `unify-sweep-results-proto` 5.14) Add a concurrent CNPG fence-activation-vs-projection race integration
  test that runs a projection transaction and a fence-activation (epoch bump)
  concurrently against a live CNPG instance and asserts the projection either
  commits authoritative rows under the read epoch (`authoritative_apply`) OR
  atomically downgrades to `ledger_only` when the fence advanced first -- never a
  stale `authoritative_apply` and never a lost ledger row.
  Remaining as of the move (2026-11-02): follow-up (`lease_miss_commit_race_db_test`
  covers miss-versus-commit, not fence-versus-projection).

## 2. Validate

- [ ] 2.1 Run the Go, Elixir and Bazel suites for every touched target and
  `openspec validate harden-edge-record-transport --strict`.
