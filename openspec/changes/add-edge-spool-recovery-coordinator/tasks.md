# Tasks: Add the agent spool recovery coordinator

## 1. Moved from `unify-sweep-results-proto`

Each task keeps its original text and number from `unify-sweep-results-proto`; its last line states what remained
when it moved.

- [ ] 1.1 (was `unify-sweep-results-proto` 2.4) Implement an fsynced segmented agent spool that persists encoded bytes,
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
  PARTIALLY LANDED: commit `2c816c114e` gave
  `go/pkg/edge/spool` its first production caller, the agent's edge-record
  sender, and added the `Resolved()` watermark read. The segmented recovery,
  rollover, and allocator obligations above are not implemented, so this task
  stays unchecked.
  Remaining as of the move (2026-11-02): plus prepaid terminal evidence (#6198) and
  the permanent-rejection quarantine (#6208). Segmented recovery, rollover and
  the single allocator remain (with 2.27, 2.28); follow-up.
- [ ] 1.2 (was `unify-sweep-results-proto` 2.17) **Correct `admission`: free bytes on durable terminal outcome only.**
  It releases reserved bytes when the gateway resolves, which reclaims evidence
  before the agent can prove the outcome survived its own restart. Release MUST
  follow the durable terminal record and the coverage proof. Test that a crash
  after PubAck but before the terminal record leaves the bytes present.
  STATUS -- DELIBERATELY UNCHECKED. The ADMISSION-SIDE boundary MERGED
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
  Remaining as of the move (2026-11-02): unchanged: the admission side is merged, but
  `go/pkg/edge/admission` has no importers and the end-to-end authorization is
  task 2.28.
- [ ] 1.3 (was `unify-sweep-results-proto` 2.20a) **OWN the assignment mapping's tagged VALUE shape.** The ABI change froze
  the KEY only; it explicitly does NOT freeze the value, because no message there
  represents a POSITIVE / EXPLICIT_NEGATIVE body or a durable negative reason. Define
  the tagged body here -- POSITIVE (execution/plan/range identities and digests, shard,
  epoch, contract-specific correlation operand) or EXPLICIT NEGATIVE (durable negative
  evidence and reason, no positive-only fields). A single untagged schema cannot
  express both, because a durable negative means there is no execution.
  Remaining as of the move (2026-11-02): follow-up (recovery coordinator prerequisite).
- [ ] 1.4 (was `unify-sweep-results-proto` 2.20) **Implement the durable assignment mapping (runtime half of the split
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
  Remaining as of the move (2026-11-02): follow-up (recovery coordinator prerequisite).
- [ ] 1.5 (was `unify-sweep-results-proto` 2.21) **Scope generations to lanes and freeze one identity per lane.** Bind
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
  Remaining as of the move (2026-11-02): `spool.LaneSet` in
  `go/pkg/edge/spool/lanes.go` implements per-lane generations and the retryable
  `ROTATION_REQUIRED`, with tests; the agent still opens one spool. Wiring is
  follow-up.
- [ ] 1.6 (was `unify-sweep-results-proto` 2.22) **Bind attribution to the accepted record in the spool
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
  Remaining as of the move (2026-11-02): follow-up (needs 2.20, 2.21 wiring).
- [ ] 1.7 (was `unify-sweep-results-proto` 2.25) **Preserve attribution across relocation.** Carry the bound relation
  through rollover, compaction, and scratch copies; re-verify the binding and
  re-checksum at the destination BEFORE the source becomes eligible for release;
  degrade a span that cannot be verified to unattributable rather than dropping or
  blindly copying it.
  Remaining as of the move (2026-11-02): follow-up (needs 2.27).
- [ ] 1.8 (was `unify-sweep-results-proto` 2.27) **Resume the saved rollover work as the agent recovery coordinator
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
  Remaining as of the move (2026-11-02): follow-up; until it lands, an ambiguous sequence
  gap wedges the lane (package `sender` doc).
- [ ] 1.9 (was `unify-sweep-results-proto` 2.28) **Integrate post-coordinator reclamation behind the coverage proof
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
  Remaining as of the move (2026-11-02): follow-up (needs 2.27).
- [ ] 1.10 (was `unify-sweep-results-proto` 5.6) Implement the idempotent recovery consumer with DURABLE KEYS that contain
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
  Remaining as of the move (2026-11-02): follow-up (needs 2.27).

## 2. Validate

- [ ] 2.1 Run the Go, Elixir and Bazel suites for every touched target and
  `openspec validate add-edge-spool-recovery-coordinator --strict`.
