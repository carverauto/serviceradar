## 1. Freeze the edge record v1 wire ABI

Scope: the wire contract and the grammars that identify it. Everything runtime --
producer sinks, spool mechanics, gateway relay, JetStream, projectors, migration --
stays in the downstream `unify-sweep-results-proto` change and is NOT reviewed
here.

- [ ] 1.1 Add a producer-neutral authoritative `EdgeRecordV1`, a separate
  `EdgeDeliveryFrameV1`, the typed disposition and resolved-watermark
  contracts, and lane-opening/session handshake. The disposition enum on the wire
  is `EdgeRecordDispositionKind`, and its GENERATED members are the only wire
  values: `EDGE_RECORD_DISPOSITION_KIND_UNSPECIFIED` plus
  `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE`, `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY`, `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE`,
  `EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT`, and `EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE`. Lowercase names such as
  `primary_publication` or `security_quarantine_publication` are RUNTIME-INTERNAL
  outcomes owned downstream; each MUST map onto exactly one generated member, and
  NONE of them is a wire value. `EdgeRecordV1` SHALL carry an
  exact `EdgeOutputContractRef` (contract ID/version, immutable bundle digest,
  registry epoch, registry-snapshot digest, and effective-grant digest), finite
  platform-owned payload family and route profile, compression, a canonical
  binary semantic envelope, trusted
  projected-row/projected-write-byte costs plus a cost-
  model version, host-attested producer/package/assignment/run provenance,
  authoritative `network_scope_id`, immutable control-plane-granted traffic
  class, typed authorization context, the signed production capability, optional
  source authorization, and versioned signing/key-rotation metadata around the
  canonical domain payload. A renewable delivery capability SHALL NOT appear in
  `EdgeRecordV1`. Broker publication SHALL use only separately bounded,
  transport-minimal headers. `EdgeDeliveryFrameV1` SHALL carry only mutable
  delivery coordinates and proof (`spool_id`, sequence, and delivery capability)
  plus the immutable encoded `record_bytes`; the lane is negotiated by the RPC
  session and route/class remain immutable record facts. Rollover/recovery can
  therefore change delivery coordinates without changing semantic bytes or
  identity. Add
  `SpoolLossTombstoneV1` and structured
  rejection contracts. Use canonical 16-byte UUIDs or strictly validated
  lowercase UUID text for every UUID-backed identifier. Require RFC 9562 UUIDv7
  for every v1 semantic event ID and v1 MTR trace ID; derive the
  metadata retirement bucket and trace identity time from them, validate their
  timestamps against signed production and, where applicable, source-action/
  collection/execution intervals, and prove in
  cross-language fixtures that an ID cannot change partitions.

  ALSO IN 1.1 -- THE HELLO CARRIER, NAMED. Both `AgentHelloRequest` and
  `ControlStreamHello` in `proto/monitoring.proto` exist today and both expose only
  `repeated string capabilities`, which cannot carry a typed protocol/family/
  encoding/compression/spool-reader/frame-bound/registry set. FREEZE THIS:
  (a) define ONE shared typed submessage, `EdgeRecordCapabilitiesV1`, in
  `proto/edge/v1/record.proto`;
  (b) IMPORT it into `proto/monitoring.proto` and add it as an optional field to
  BOTH `AgentHelloRequest` and `ControlStreamHello` -- both are agent->server hellos
  on different RPCs, and an agent may use either, so carrying it in only one leaves
  the other path unable to negotiate;
  (c) PRECEDENCE when both are present in one session: they SHALL be EQUAL, and a
  difference SHALL be rejected as a capability conflict rather than resolved by
  preferring one RPC. Equal-or-reject is the only rule that does not make capability
  depend on which stream a peer happened to open first;
  (d) the existing `repeated string capabilities` SHALL NOT be extended or
  reinterpreted to carry any of it.
  This is a PREREQUISITE of the 1.7 freeze: 1.7 cannot freeze a capability
  negotiation whose carrier is undecided.

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
  AUDIT (1.1-1.6, post-#4739): the plan header/pages and `SweepExecutionEventV1`
  EXIST, but the authoritative assignment-record message DOES NOT -- there is no
  such message in `proto/edge/v1`. It must be designed before the 1.7 freeze or
  explicitly cut from it, because it is an append-only authoritative contract on
  the frozen ABI. It is also what binds a span's `producer_assignment_id` to the
  scheduler's `execution_plan_id`, which is why the span itself does not carry
  the plan identity.
  SPLIT (boundary reset): this task is now the ABI/SCHEMA/CORRELATION half only --
  the append-only authoritative assignment-record CONTRACT, the frozen
  `SweepObservationBatchV1` correlation matrix (per permitted
  `SweepExecutionSource`: which field is the signed context, whether
  `source_run_id` is required or forbidden, which mismatch is rejected, with a
  positive and a mismatch vector per variant), and the assignment-mapping KEY,
  which must be frozen with the span because the span omits execution and plan
  identity on the strength of it. DOWNSTREAM (runtime change): the mapping's
  durable storage, replay/repair state machine, conflict resolution, retention,
  GC, and lookup-outcome transitions. Today only `context_id == execution_id`
  (`domain.go:210`) and shard/epoch (`domain.go:215`) are proven; nothing compares
  `run_id`, and it MUST NOT -- see the withdrawn equality in the span requirement.

- [ ] 1.4 Add lossless `MtrTraceBatchV1` and `MtrTraceEventV1` contracts covering
  every current trace/hop/ECMP/MPLS/ASN/DNS/timing/outcome/source/correlation
  field without generic metric attributes. Require every batch to share one
  network-scope/agent/source/authorization/execution-or-command/range/traffic-
  class context. Define MTR completion via `MtrCompletionDigestVersion = 2`: a
  versioned, bounded, order-independent-to-arrival proof over deterministic plan
  order that folds three additive 256-bit accumulators by big-endian 256-bit
  modular add (mod 2^256, carry flowing toward the most-significant byte) over
  per-leaf content, leaf ordinals, and `(ordinal, range_sha256)` membership pairs
  -- NOT per-block Merkle roots composed in order. The completion ROOT is
  `SHA-256(version || expected || plan_root_sha256 ||
  mtr_ordinal_range_commitment || leaf_accumulator)`, so `plan_root_sha256` is
  committed inside the root; the leaf-ordinal and `(ordinal, range_sha256)`
  membership accumulators are verification GATES (checked against the expected
  count and `mtr_ordinal_range_commitment`) and are NOT hashed into the root.
  Each leaf uses a fully frozen
  byte grammar: a leading `u64` grammar-version constant (`MtrCompletionDigestVersion
  = 2`) committed into the hashed preimage (the MTR leaf carries NO string sub-tag;
  the ordinal and member elements each carry their own str sub-tag), a FIXED field
  order (no per-field numeric tags), 8-byte big-endian integers, 8-byte big-endian
  length prefixes, and recursive field-by-field framing, so
  completion never depends on arrival order, on per-block buffering, on a
  `proto.Marshal` re-encode, or on execution-wide trace materialization. Allocate and durably record UUIDv7 trace
  IDs before probing and add cross-language UUIDv7/identity-time fixtures.
  AUDIT (1.1-1.6): the proof machinery is implemented in both runtimes, but the
  completion-leaf disposition is declared NOWHERE in the protos -- it is a Go
  `iota` block (`MtrTerminalDisposition`) and separately a set of literal
  integers in Elixir guards. Declare it ONCE as the generated enum
  `MtrCompletionDisposition`, with the members and numbers frozen by the requirement "MTR completion disposition is one generated enum". Distinct from the per-hop `MtrOutcome` numbering
  (REACHED=1, PROBE_FAILED=3, NOT_ADMITTED=5, QUARANTINED=6, SCHEDULER_LOST=7),
  which it SHALL NOT reuse. Go's `MtrTerminalDisposition` constants and Elixir's
  integer guards become CONSUMERS of the generated enum. NO new leaf message is
  needed: the disposition is a field of the existing leaf grammar. Reject zero,
  negative, and unknown-positive values BEFORE widening to `u64` and hashing, and
  keep later-declared values rejected until the completion grammar version itself
  changes. The number is hashed into the frozen leaf preimage, so a hand-maintained
  pair can produce two different roots for one completion. (This target was
  previously duplicated inside checked task 1.13; it lives here and in 1.15 only.)

- [ ] 1.5 Define compatibility rules for unknown fields/enums, unsupported
  versions, timestamp units, optional zero-valued measurements, ASN range,
  ENUM COMPATIBILITY (cross-language parity): Go retains an unknown/negative int32 enum
  as its integer and REJECTS unknown values in the explicit SEMANTIC validator
  (`knownTrafficClass`/`knownRouteProfile`/...), whereas protobuf-elixir's generated enum
  fallbacks -- BOTH `value/1` (`deps/protobuf/lib/protobuf/dsl/enum.ex` ~line 50) AND
  `key/1` (~line 72), each `when is_integer(tag) and tag >= 0` -- RAISE on a negative int,
  so `WireDecode` currently classifies a negative enum `:poison`. This is NOT truly
  equivalent to Go's reject: Elixir raises at DECODE time and yields a poison
  CLASSIFICATION, while Go accepts the decode and rejects SEMANTICALLY -- two
  different classifications for the same bytes -- so the divergence MUST be closed.
  WHAT THIS TASK FREEZES is parity of the DECODE result, the effective enum VALUE,
  and the semantic-rejection verdict between the two runtimes. It does NOT freeze a
  disposition for either classification: a poison classification's disposition is
  resolved per stage and slot downstream (the committed lane-open negative-enum case
  is PRE-SLOT and has no per-delivery disposition at all), and which DLQ or stream a
  disposition routes to is likewise downstream. It is in fact WORSE than a
  classification mismatch: because protobuf resolves a repeated singular field LAST-ONE-WINS and the
  generated decoder walks fields IN ORDER, a message carrying `traffic_class = -1` FOLLOWED BY
  `traffic_class = BULK` -- effective value BULK, which Go ACCEPTS -- raises on the FIRST
  occurrence, so Elixir REJECTS A MESSAGE GO ACCEPTS. **PROVEN MECHANISM (two layers; the enum
  verdict MUST NOT live in a raw wire walker, which cannot reproduce effective-value semantics --
  last-one-wins, oneof resolution, embedded-message merging -- without reimplementing the
  decoder):** (1) a project-owned, deterministic POST-GENERATION TRANSFORM
  (`scripts/patch_edge_enum_negatives.exs`) -- NOT a protobuf fork and NOT a custom generator
  template -- injects negative identity clauses for `key/1` and `value/1` into the 15 edge enum
  modules so a negative int is RETAINED exactly as Go retains it. The clauses are declared in the
  module BODY because the Protobuf DSL appends its own at `@before_compile` (so body clauses win for
  negatives and every other tag falls through unchanged); `defoverridable` CANNOT be used, as the
  functions do not exist at that point. The transform runs in BOTH `generate-proto-elixir` and the
  clean-temp `verify-proto-edge-elixir` path BEFORE formatting/comparison so the byte-exact drift
  gate stays meaningful, and it is IDEMPOTENT and FAILS CLOSED on generator-version,
  module-inventory, or source-shape drift. (2) the SAME explicit semantic validator as Go
  (`ServiceRadar.Edge.SemanticValidate`, mirroring `knownTrafficClass`/`knownRouteProfile`/...,
  with UNSPECIFIED excluded exactly as Go excludes it) then REJECTS a retained non-member on the
  DECODED struct, where the effective value is already resolved, so a retained negative/unknown enum
  can never be silently ADMITTED. Cross-language N (known, accepted) and negative/unknown (rejected)
  vectors are tested in BOTH directions. Task 1.5 is a PREREQUISITE of the live runtime integration
  (task 1.16). ALSO introduce a project-owned
  typed MALFORMED-WIRE preflight/decoder before live integration (P1): a deterministic
  malformed `MatchError` currently maps to `:systemic`, so at a KNOWN delivery slot it
  would stay retryable forever and pin the cumulative-prefix watermark (fuzz: ~3-4% of
  malformed inputs). The preflight SHALL recognize genuine malformed SHORT-READ/overrun
  cases as `:poison` (bad bytes -- a poison CLASSIFICATION whose disposition is resolved
  per the stage/slot, never prejudged as quarantine here) while leaving genuine codegen/metadata
  failures `:systemic`, so no decodable slot is retryable forever; it too is a PREREQUISITE
  of task 1.16. ADDITIONALLY, a project-owned RECURSIVE STRUCTURAL validator
  (`ServiceRadar.Edge.WireValidate`, run on the raw bytes BEFORE the generated decoder) SHALL
  REJECT, RECURSIVELY at EVERY
  message depth -- the outer frame, the inner record, and every nested capability/message -- the FULL
  set of wire-hygiene inputs that protobuf-elixir MASKS or SILENTLY DISCARDS while Go REJECTS them:
  (a) protobuf GROUPS (wire types 3/4; Elixir drops an unknown group, Go retains + rejects it as an
  unknown field); (b) OUT-OF-RANGE FIELD NUMBERS (> 2^29-1 = Go's MaxValidNumber; Elixir leniently
  accepts, Go rejects); and (c) 10-BYTE UINT64-OVERFLOW VARINTS (a 10-byte varint whose TERMINAL chunk is
  > 1, i.e. bits at or above bit 64 are set, INCLUDING the `2^64 + N` aliases, in any varint position --
  tag, wire-0 scalar, or length prefix; the pinned protobuf-elixir decoder MASKS such a varint to its low
  64 bits, so `2^64 + N` aliases to `N`, whereas Go/protowire rejects it as overflow. A varint LONGER than
  10 bytes is already rejected by BOTH runtimes and is not part of this parity gap). Without this, a frame whose
  record or nested capability carries ANY of these -- which Go rejects -- would decode `{:ok, ...}` in
  Elixir. (The TOP-LEVEL scanner in `WireDecode` closes all three at the FRAME level:
  `raw_frame_envelope_check` fails a malformed frame envelope to `:poison` (distinguishing it from an
  absent record), `peel_last_field`/`scan_client_message` bound the field number to `@max_field_number`
  (== Go's MaxValidNumber, inclusive), and `take_varint` rejects a 10th-byte varint overflow -- but that
  covers only the frame TOP level, NOT the same inputs nested inside the record or capabilities, which
  is why the RECURSIVE validator is required for full Go parity.) It SHALL additionally validate PACKED
  repeated scalar payloads (varint elements get the overflow rule; fixed-width elements MUST exactly
  fill the payload), gated on `repeated?` so a SINGULAR scalar arriving length-delimited -- a wire-type
  mismatch Go PRESERVES as an unknown field -- is never poisoned. Its nesting bound SHALL equal the
  pinned Go runtime's (`protowire.DefaultRecursionLimit` = 10,000, counting the ROOT, so 10,000
  messages are accepted and the 10,001st is rejected). It SHALL make NO value-level judgement (see the
  enum mechanism above) and SHALL report a codegen/metadata failure -- including a raise, THROW, or
  EXIT from schema metadata -- as `:systemic`, or `:not_ready` for an undeployed nested schema, NEVER
  as the destructive `:poison`. This too is a PREREQUISITE of task 1.16.
  Also cover unsupported versions,
  timestamp units, optional zero-valued
  measurements, ASN range,
  string/count/byte/relational-row bounds, the FROZEN field-framed
  semantic-envelope digest grammar (NO domain tag; leads with the committed `u64`
  constant `semanticDigestVersion = 3` -- not a wire field, fixed by the record-schema
  ABI; FIXED field order, no per-field numeric tags; 8-byte big-endian integers;
  8-byte big-endian length prefixes; 1-byte presence markers; `u64` (8-byte) oneof
  discriminants; `u64` repeated-element counts; recursive field-by-field nested
  framing; NO `proto.Marshal` at any depth),
  streaming
  compression expansion, recursion, and trailing-frame rejection. OPEN CANDIDATE
  PR for the compression-admission half: **#4734** (base `usp-01-proposal`) --
  awaiting review, NOT merged; check it before starting that piece. Define the
  immutable semantic-envelope digest separately from gateway receipt, physical
  placement, spool coordinates, and renewable delivery proof; define broker
  publication identity separately. Make projected row cost cover every
  synchronous ledger/domain/outbox/work/current-state mutation and canonicalize
  nanoseconds to PostgreSQL microseconds before identity/order comparison.
  AUDIT (1.1-1.6): the negative-enum divergence this task exists for IS closed --
  `WireValidate` structural preflight then `SemanticValidate.disposition/2`
  mapping to `EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT`, with the LAST-ONE-WINS case covered by the
  SHARED fixture `lane_open_negative_then_valid.bin` referenced from both
  runtimes. The residual clauses (timestamp units, optional zero-valued
  measurements, ASN range, unsupported-version handling) were NOT verified
  clause-by-clause and remain open. The exact-received-bytes rule also applies
  here: `ScheduledPlanPageV1` still measures its ceiling on a re-marshal.

- [ ] 1.6 Generate Go and Elixir modules, update Bazel targets, and add
  cross-language golden fixtures proving equivalence across Go and Elixir for the
  semantic-envelope digest (`semantic_digest_version = 3`), payload digest,
  capability signing bytes (`capability_version = 1`), plan/range/
  recovery content hashes (`plan_grammar_version = 1` / `recovery_grammar_version
  = 1`), MTR completion proof (`MtrCompletionDigestVersion = 2`), and the
  publication identity transcripts for BOTH the edge-slot and service-slot
  variants (`Nats-Msg-Id` `msgid_version = 1`, domains `serviceradar.edge.msgid`
  / `serviceradar.edge.msgid.service`; `Sr-Edge-Delivery-Id`
  `delivery_id_version = 1`, domains `serviceradar.edge.delivery-id`
  / `serviceradar.edge.delivery-id.service`) and the
  `Sr-Edge-Transport-Provenance` header
  (`serviceradar.edge.transport-provenance`, `provenance_version = 1`) for both
  the `edge` and `service-ingress` slot kinds -- proving delivery-proof-present
  (late/renewal/rollover) and delivery-proof-absent (fresh/service) presence-byte
  encodings and the base64url(no-pad) framed-envelope header -- plus
  the unknown-version fail-closed vector ASSIGNED BY EACH OBJECT'S PROOF CLASS
  below (Class-B objects have no input version and SHALL NOT be asked for an
  unsupported-input vector) (never whole-record byte equality; protobuf has no canonical wire form,
  so two compliant encoders MAY emit different `record_sha256` for the same
  semantics).
  AUDIT (1.1-1.6): equivalence IS proven -- Elixir reads the SAME
  `proto/edge/v1/testdata` corpus as Go, and both regeneration drift guards run
  in `proto-abi.yml`. The gap is the fail-closed half. Exactly ONE grammar has an
  unsupported-version fixture today: transport provenance's `unknown-version` row in
  `pubid_reject_vectors.txt`. (`lane_open_unknown_group.bin` is an unknown
  protobuf GROUP/field fixture, not an unknown-VERSION vector.)
  The gate is OBJECT-LEVEL, not per version family, and it has TWO exhaustive
  proof classes, because most versions are compile-time preimage constants no
  sender can present:
  CLASS A -- DIRECT UNSUPPORTED-INPUT-VERSION REJECTION. The object decodes a
  version from its input; set it unsupported and require rejection. Members:
  capability (`EdgeSignedCapabilityV1.capability_version`); recovery manifest page
  (`EdgeLossManifestPageV1.digest_version`); tombstone
  (`SpoolLossTombstoneV1.digest_version`); MTR completion
  (`SweepExecutionEventV1.mtr_completion_digest_version`); plan header
  (`ScheduledPlanHeaderV1.digest_version`); plan page
  (`ScheduledPlanPageV1.digest_version`); and `Sr-Edge-Transport-Provenance`,
  whose framed envelope carries a decodable version (DONE).
  CLASS B -- ALTERED-VERSION PREIMAGE/DIGEST/HEADER MISMATCH. The version is a
  constant inside the preimage and the received value is a digest or opaque
  identifier, so there is no version input to corrupt: recompute the object with an
  altered version constant and require the resulting digest/header to be REJECTED
  as a mismatch. Members: semantic envelope (`semantic_digest_version = 3`);
  `Nats-Msg-Id` edge and service (`msgid_version = 1`); `Sr-Edge-Delivery-Id` edge
  and service (`delivery_id_version = 1`); `RangeDigest` and `PlanRoot`
  (`plan_grammar_version = 1`); `ManifestRoot` (`recovery_grammar_version = 1`);
  and EACH of the three recovery-operation scope transcripts SEPARATELY -- tombstone
  scope, manifest-page scope, resolved scope (`RecoveryScopeDigestVersion = 1`) --
  which are three objects, not one family.
  `ManifestPageDigest`, `PlanHeaderDigest`, and `PlanPageDigest` belong ONLY to
  Class A: they are the digests OVER those messages, and the version they commit is
  the `digest_version` field the message itself carries, so the Class-A vector
  already exercises them. Listing them in both classes double-counted one object.
  An earlier revision of this task classified `Nats-Msg-Id` and
  `Sr-Edge-Delivery-Id` as Class A. That was WRONG: their received values are
  digests and their versions are compile-time constants, exactly like the semantic
  envelope. EVERY Appendix A object SHALL appear in exactly ONE class.

- [ ] 1.6a **Freeze the loss-classification span shape BEFORE the 1.7 ABI freeze.**
  Replace the ad-hoc `lost_ranges` + `affected` pairing on
  `EdgeLossManifestPageV1` with ONE ordered classification-span representation.
  Each span carries a PHYSICAL sequence interval plus exactly one classification:
  `ATTRIBUTED_ACTIVE` (asserts a produced target range), `ATTRIBUTED_PASSIVE`
  (asserts none -- but still carries its lost DELIVERY interval), and
  `UNATTRIBUTABLE(reason)`. `classification_spans` REPLACES both `lost_ranges` and
  `affected` -- there is NO separate lost-range array for spans to agree with, and
  a page carrying one MUST be rejected. Total loss is exactly the union of the
  pages' spans. The list MUST be strictly ordered and internally well-formed (no
  overlaps, duplicates, or out-of-order spans; at least one span per page; each
  span primitively valid on its own with `from_sequence >= 1` and
  `through_sequence >= from_sequence`; and ordering total across the WHOLE page
  chain, page N ending strictly below page N+1's start), enforced in BOTH
  runtimes. The page's derived first-to-last quantity is its EXTENT, never
  "coverage" -- coverage elsewhere is per-sequence evidence that can authorize
  reclamation, and an extent legally contains not-lost gaps. GAPS ARE LEGAL and
  mean "not lost", within a page and at a page boundary alike.
  ALSO ATOMIC -- the RECOVERY-OPERATION SCOPE family is separately named and is NOT
  covered by "every `recovery_grammar_version = 1` reference"; name it explicitly:
  `RecoveryScopeDigestVersion = 1`, Go `TombstoneScopeDigest`, Elixir
  `HashGrammar.tombstone_scope_digest`, the goldens `tombstone_scope.bin` and
  `tombstone.bin`, and their cross-language regeneration. `SpoolLossTombstoneV1`
  SHALL lose `lost_from_sequence` / `lost_through_sequence`, their scope-digest
  members, their Appendix A transcript entries, and the `ValidateTombstone`
  equality against the manifest's global min/max.
  TWO FROZEN ABI CHOICES this removal creates: (a) `RecoveryScopeDigestVersion`
  STAYS `1` -- the grammar is an unshipped candidate rewritten atomically, and
  bumping a version would preserve a compatibility story for bytes no agent has
  ever emitted; (b) EVERY retired tag is RESERVED, by NUMBER and by NAME, and later
  tags are NOT renumbered -- on `SpoolLossTombstoneV1` tags `3` and `4`
  (`lost_from_sequence`, `lost_through_sequence`), and on `EdgeLossManifestPageV1`
  tags `7`, `9`, and `10` (`coarsened`, `lost_ranges`, `affected`), all of which this
  task retires in the same pass. Reserving stops stale candidate bytes being reinterpreted as a future field
  and stops a retired name being reused for a different meaning. The two manifest
  tags were not named in an earlier revision of this task, which reserved only the
  tombstone's -- the same reasoning applies to both messages, so both are reserved.
  TWO SIGNED SCALARS NEED ONE AUTHORITATIVE MEANING IN THE SAME PASS:
  (i) `RecoveryResolvedV1.applied_through_sequence` stays in the signed scope
  transcript, but with the tombstone range gone and gaps legal it could mean the
  maximum span end, a contiguous processed prefix, or the allocated high-water --
  which differ for `[1,1]` plus `[100,100]`, and the value GATES durable local
  journal release. FREEZE it as the consumer's DURABLY APPLIED CONTIGUOUS PREFIX
  over the ALLOCATED sequence space: the highest S such that EVERY allocated
  sequence at or below S is either durably applied by the consumer transaction, or
  ABSENT FROM a VALIDATED COMPLETE span union (the union is the LOST set, so only
  absence from a complete union establishes not-lost -- an earlier revision of this
  task said "proven not-lost by the span union", which is backwards). The gapped
  fixture SHALL supply COMPLETE inputs -- prior watermark, allocated high-water,
  per-sequence durable state, and the validated union -- and an EXPECTED value; a
  bare `[1,1]` + `[100,100]` pair pins nothing. It is NOT the maximum span end -- that would
  release a journal over sequences the consumer never processed. Add a
  gapped-union vector (`[1,1]` + `[100,100]`) pinning the value. This meaning is
  FROZEN in the normative delta; if it proves unimplementable that is a SPEC
  AMENDMENT, not an implementation-time choice between alternatives.
  (ii) Tombstone `coarsened` is REMOVED, and tag `8` plus the name are reserved.
  Retaining it would leave a SEPARATELY SIGNED aggregate of a fact the pages already
  declare -- the same dual-schema defect this task removes by deleting
  `lost_ranges`, and a signed field excluded from the identity comparison is a
  replay hole of the same shape as the `new_spool_id` one. The PAGE `coarsened` bit
  (tag `7`) is removed in the same pass, so there is no manifest coarsening flag to
  derive and none to retain: its set/clear rule could not be made deterministic
  without freezing a canonical pre-coarsening partition the page does not carry.
  Tag reservation prevents SOURCE reuse but does NOT by itself prove old bytes are
  rejected at runtime, and the grammar keeps version 1 -- so add SHARED Go/Elixir
  REJECT fixtures, ONE PER RETIRED TAG so a surviving acceptance cannot hide behind a
  sibling: an old-candidate tombstone carrying tag `3`, one carrying `4`, one
  carrying `8`; and an old manifest page carrying tag `7` (`coarsened`), one carrying
  `9` (`lost_ranges`), and one carrying `10` (`affected`). The tag-`7` vector is
  INDEPENDENT and must not be folded into the `lost_ranges`/`affected` case -- a
  decoder that rejects the retired repeated fields while silently accepting a stale
  boolean would pass a combined fixture and still admit a page whose digest cannot be
  reproduced. Those are the
  executable gate that a same-version atomic rewrite cannot admit stale candidate
  bytes. With gaps legal that min/max is not the loss, and because the
  tombstone scope is SIGNED, keeping it would leave an AUTHENTICATED second source
  of truth -- strictly worse than the page arrays this task removes. The complete replacement schema is FROZEN in the
  normative delta -- oneof member tags, `EdgeUnattributableReason` numbers with its
  two RESERVED entries, span fields, per-page/per-manifest bounds, unknown-field and
  closed-set unknown-enum handling, the recovery digest version, and the Appendix A
  transcripts for both the manifest page and the tombstone scope -- so this task
  IMPLEMENTS that schema rather than deciding it.
  IMPLEMENTATION SURFACE (audited; an earlier revision of this task listed only the
  digest functions and undercounted it): the proto plus BOTH generated bindings;
  `edgerecord/recovery.go` and its `validate.go` comment; `hash_grammar.ex`, whose
  `manifest_page_digest/1` and `tombstone_scope_digest/1` BOTH change; a NEW Elixir
  RELATIONAL recovery validator -- Elixir has only `HashGrammar` today, so the
  relational half is not a port of `recovery.go` but new code; `semantic_validate.ex` with its
  schema-root/policy coverage; the Go enum-policy predicates and manifest contexts;
  `scripts/patch_edge_enum_negatives.exs` and its test, whose hard-coded inventory
  goes from 15 enums to 16; `enum_policy_manifest.txt`; SIX transitively changing
  fixtures (`manifest_page`, `manifest_page_scope`, `tombstone`, `tombstone_scope`,
  `recovery_resolved`, `resolved_scope`) before the new gap/stale/bloat/reject
  vectors; and the Go and Elixir golden AND semantic-validation suites.
  The RAW-BYTE CEILING needs a real recovery-page decode/validation entry point in
  BOTH runtimes: hashing or re-marshalling a decoded message cannot prove a bound on
  the bytes actually received, which is the defect at `recovery.go:168` today. Byte ceilings MUST be
  measured against EXACT RECEIVED page bytes -- the current Go validator
  re-marshals decoded pages, so duplicate fields and non-minimal varints evade
  the physical ceiling.
  A PER-PAGE ENTRY POINT IS NOT SUFFICIENT, because `MaxManifestBytes` is an
  AGGREGATE budget. Two pages can each be under the cap in received bytes, exceed it
  TOGETHER, and then collapse back under it when re-encoded -- so a per-page raw
  check plus a re-encoded total still admits an over-budget manifest. The CHAIN
  boundary SHALL receive and PRESERVE each page's exact raw length and SUM those
  lengths with OVERFLOW-SAFE arithmetic. Vector: two individually valid, individually
  sub-cap pages whose AGGREGATE RECEIVED size is `MaxManifestBytes + 1` and whose
  decoded/re-encoded aggregate falls BELOW the cap -- so the test fails on any
  implementation that sums re-encoded sizes, which is the property being proven.
  State explicitly whether the new raw recovery-page boundary EXTENDS the finite
  stage API in `wire_decode.ex` or deliberately supersedes that ingress invariant;
  adding a second unrelated raw-bytes ingress without saying so would leave two
  boundaries claiming the same guarantee. Add cross-language vectors for each classification, each
  unattributable reason, and the non-canonical-bloat case. Instead of the
  now-meaningless "partition violations" (gaps no longer partition a declared
  interval), use this explicit matrix -- REJECT: empty page; zero or inverted
  interval; overlap, duplicate, or out-of-order spans WITHIN a page; the same
  ACROSS a page boundary. ACCEPT: gaps within a page; gaps across a page boundary;
  adjacent spans; a span bounded at `MaxUint64` (no overflow arithmetic).
  The page's EXTENT (never "coverage") is DERIVED from the ordered spans -- first
  lower bound through last upper bound; do NOT add a second declared range for the
  spans to agree with. An
  attributed span carries the frozen assignment identity in the PRODUCER's
  naming: `producer_assignment_id`, `run_id`, `run_shard`,
  `authority_epoch`, `production_scope_id` + `scope_sha256` (the PRODUCTION scope,
  ALWAYS present), `contract_bundle_sha256`, and `range_sha256` on ACTIVE only;
  plus the SIGNED SOURCE IDENTITY -- KIND + `context_id` + `source_scope_id` +
  `source_scope_sha256` -- ALL FOUR jointly present when the record carried a
  source authorization and ALL FOUR jointly absent otherwise, with the absence
  itself part of the identity and partial combinations rejected. IDs travel WITH
  their digests: the wire signs and validates each independently and nothing
  derives one from the other.
  ALSO IN 1.6a: correct the still-live proto/code comments that equate an absent
  source authorization with "passive output" (`record.proto` lines 82-86 and
  234-237, the `absent = passive output` comment on `source_authorization`, and
  `go/pkg/edge/edgerecord/validate.go:785`, which still says a nil source
  authorization means a passive record -- generated comments follow the proto
  edit, hand-written ones do not).
  After this change "passive" means ONLY "asserts no produced target range";
  leaving those comments gives the word two incompatible meanings in one file. `run_shard`
  and `authority_epoch` equal `execution_shard` / `assignment_epoch` ONLY where the
  originating contract carries them -- `SweepObservationBatchV1` and
  `MtrSweepContextV1` do; the scheduled-check, ad-hoc, and command MTR variants
  carry neither. `run_id` is INDEPENDENT and is NOT REQUIRED to equal
  `execution_id`. A span does NOT embed `execution_plan_id`.
  SCOPE: the exact-received-bytes ceiling fix in this task covers the RECOVERY
  MANIFEST PAGE only. `ScheduledPlanPageV1` has the SAME re-marshal bypass
  (`go/pkg/edge/edgerecord/plan.go`, `MaxPlanPageBytes` measured over a
  `proto.Marshal` of the decoded page) and is NOT fixed here -- it is recorded
  under 1.3/1.5. This task MUST NOT claim to have closed the bypass for all paged
  contracts.
  This must land BEFORE 1.7 because 1.7 freezes the transport ABI these pages
  travel on, and it gates 2.21-2.28 (the ORIGINAL PRE-SPLIT task 2.20 is folded into
  this task; the downstream change reuses the number 2.20 for a distinct runtime
  task, which is NOT folded).
  FOLDED IN FROM TASK 2.20 -- the proto shape, BOTH runtimes' validators, the exact
  byte checks, and the fixtures land ATOMICALLY in this task. Splitting them let a
  frozen shape ship without the validators that enforce it:
  Update `ValidateManifestChain` and `ValidateTombstone` so an
  `UNATTRIBUTABLE` span validates WITHOUT a covering affected scope, so
  `ATTRIBUTED_PASSIVE` validates with a delivery interval and no produced range,
  and so the FROZEN span rules are enforced (strict ascending order,
  non-overlapping, non-duplicate, primitively valid intervals, at least one span
  per page, and ordering total ACROSS the page chain). There is NO "exact-partition
  rule": gaps are legal and mean "not lost", so the spans do not partition a
  declared interval. Today's validators reject an
  unattributable manifest outright, so recovery of a corrupt segment cannot be
  reported at all until this lands — it gates 2.21-2.28.

- [ ] 1.7 Freeze the agent-gateway frame and lane handshake as an internal,
  producer-neutral transport ABI. PREREQUISITE RULE -- COMPLETE, not a hand-listed
  subset: this task SHALL NOT be checked while ANY OTHER TASK IN THIS CHANGE is
  open. That is tasks 1.1-1.6a and 1.13-1.15, and it is stated as a rule precisely
  because an earlier draft named a subset and silently omitted 1.1 and 1.2, which
  define the frozen messages.
  ARCHIVAL GATE: 1.7 SHALL NOT be checked until this change contains a NORMATIVE
  delta defining the authoritative assignment-record schema and the frozen
  `SweepObservationBatchV1` correlation matrix (task 1.3). A task that requires a
  contract is not a substitute for the contract; if that delta is not authored,
  narrow 1.3 and this gate rather than freezing over a missing schema.
  NOT A PREREQUISITE: the durable assignment mapping's EXISTENCE and state, which
  is runtime task 2.20 downstream. This gate SHALL NOT wait on it.
  DISPLACED: the PRODUCER-FACING sink/run API freeze is NOT part of this task and
  SHALL NOT be performed here -- it depends on Wasm and native-relay fixtures this
  change does not own. It is downstream task 1.16a, which owns that freeze together
  with its receipts, credits, and fixtures. An earlier draft both declared it
  downstream AND imperatively required it inside 1.7.
  BOUND GATE -- OWNED HERE, not downstream: 1.7 SHALL NOT be checked until
  cross-language N/N+1 vectors exist for ALL FOUR frozen raw bounds
  (`MaxRecordBytes`, `MaxDeliveryEnvelopeBytes`, `MaxFrameBytes`,
  `MaxClientMessageBytes`) AND for the relational envelope budget -- each accepted
  at N and rejected at N+1, on RAW received bytes, before unmarshal. This change
  claims ownership of the cross-language freeze gates, so it cannot rely on
  downstream task 1.16 to execute its own bound tests; otherwise the ABI can be
  declared frozen without its bounds ever being exercised.
  FREEZE CONDITION: freeze only after Go/Elixir golden fixtures cover
  `EdgeOutputContractRef`, authenticated `EdgeProducerContext`, production,
  optional source, and delivery authority, registry epochs, and finite platform
  route profiles.

- [x] 1.13 Restack prerequisite -- IMPLEMENTED as the stacked CANDIDATE slices.
  SCOPE: item (7) is MOVED OUT to tasks 1.4/1.15 and is NOT delivered here, so no
  statement in this task asserts the generated `MtrCompletionDisposition` enum
  exists or that the freeze prerequisite it represents is met. Slices:
  `usp-v2-02-wire-contract` (#4713), `usp-v2-03-ci-harness` (#4714), and
  `usp-v2-04-publication-identity` (#4715). This is a field/schema CANDIDATE (draft PRs,
  reviewable), NOT a frozen/accepted cross-runtime ABI: the freeze/accept gate is task 1.7
  (still unchecked), consistent with task 0.10 (the implementation is a review candidate,
  not an approved ABI). `proto.Marshal` was removed from every signed/hashed preimage
  (`go/pkg/edge/edgerecord/semantic.go`, `capability.go`, `claims_framing.go`,
  `recovery.go`) and MTR completion field-framed (`domain.go`), with Go+Elixir
  cross-language fixtures regenerated. The candidate ABI and code changes were:
  - (1) Expanded `EdgeRecordDispositionKind` to its frozen six generated values
    (`EDGE_RECORD_DISPOSITION_KIND_UNSPECIFIED` plus `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE`,
    `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY`, `EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE`, `EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT`, and
    `EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE`) and wired the typed disposition end to end. Runtime
    outcome names map ONTO these; they are not additional wire values.
  - (2) Eliminate `proto.Marshal` from `semantic.go` `msg()` (the
    `output_contract` / `EdgeOutputContractRef` sub-message) and from
    `capability.go` claims, replacing each with the Appendix A field-by-field
    framing (outer 1-byte presence, recursive framing, 8-byte big-endian
    integers, 8-byte big-endian length prefixes, no per-field numeric tags).
  - (3) Field-frame `EdgeDeliveryClaimsV1`'s `transition` oneof (u64 discriminant
    = 5 renewal / 6 rollover / 0 none, plus the framed member
    `EdgeDeliveryRenewalV1` / `EdgeDeliveryRolloverV1`) instead of whole-message
    `proto.Marshal`, removing the protobuf-go oneof-order hazard one level down.
  - (4) Unify the capability claims-oneof binding: BOTH the `capability()`
    sub-frame and the Ed25519 signing preimage commit the u64 member field-number
    discriminant (7/8/9), the signing preimage additionally commits the `purpose`
    (`EdgeCapabilityPurpose`) enum, and BOTH field-frame the claim member (no
    `proto.Marshal`).
  - (5) MTR completion ROOT already commits `plan_root_sha256`
    (`SHA-256(version || expected || plan_root_sha256 ||
    mtr_ordinal_range_commitment || leaf_accumulator)`) -- keep it, no change.
  - (6) Implement the `Nats-Msg-Id`, `Sr-Edge-Delivery-Id`, and
    `Sr-Edge-Transport-Provenance` grammars plus their `service-ingress` slot
    variants (`serviceradar.edge.msgid.service` /
    `serviceradar.edge.delivery-id.service`) per tasks 1.6 and 1.14.
  - (8) Rewrite the semantic-envelope (`semantic_digest_version = 3`),
    capability-signing (`capability_version = 1`), plan/range
    (`plan_grammar_version = 1`), recovery (`recovery_grammar_version = 1`), and
    MTR-completion (`MtrCompletionDigestVersion = 2`) hash/signing code to the
    Appendix A byte-frozen field-framed grammars and the frozen MSet-Add-Hash
    completion framing, eliminating `proto.Marshal` from every preimage at every
    depth; then regenerate ALL Go and Elixir golden preimage/signature/completion
    fixtures (including the Elixir peers) and add the new grammar/vector fixtures
    so two clean-room implementations produce identical bytes.
  THE RESTACK SLICES ACTUALLY LISTED ABOVE -- items (1)-(6) and (8); there is no
  item (7), which was moved to tasks 1.4/1.15 -- are IMPLEMENTED with matching
  cross-language Go/Elixir fixtures, so THOSE SLICES no longer block the wire-ABI
  FREEZE gate. This says nothing about the other freeze prerequisites: the
  generated `MtrCompletionDisposition` enum (tasks 1.4/1.15), the 1.3
  assignment-record contract, 1.5's residual clauses, 1.6's version vectors, and
  1.6a all remain open, and the freeze itself is task 1.7.

- [x] 1.14 Define and implement the `Sr-Edge-Transport-Provenance` header grammar
  and the service-slot variants of the two publication transcripts, per the frozen
  Appendix A field-framed framing (fixed field order, no per-field numeric tags,
  8-byte big-endian length prefixes, u64 slot-kind/oneof discriminants, 1-byte
  presence markers). The provenance header carries the domain
  `serviceradar.edge.transport-provenance`, `provenance_version = 1`, a `slot_kind`
  discriminant (`0` UNSPECIFIED rejected / `1` EDGE / `2` SERVICE_INGRESS), the slot tuple,
  the exact `record_sha256`, a delivery-proof presence byte plus (when present) exactly one
  32-byte `delivery_proof_digest` (absent for FRESH and SERVICE records, present for
  RENEWAL/ROLLOVER/LATE_FENCED_DELIVERY), a publisher-attested `delivery_mode` (`1` FRESH /
  `2` RENEWAL / `3` ROLLOVER / `4` LATE_FENCED_DELIVERY; `0` rejected, replacing the old
  `source_kind`), and `route_map_version` (nonzero), framed
  and base64url(no-pad)-encoded into a header bounded to <= 512 ASCII bytes; a
  missing FRESH/service delivery proof is NOT poison. Define `service_slot =
  (network_scope_id, authenticated_service_id, publication_lane_id,
  publication_sequence)` and its Msg-Id (`serviceradar.edge.msgid.service`) and
  Delivery-Id (`serviceradar.edge.delivery-id.service`) domains alongside the
  edge-slot `serviceradar.edge.msgid` / `serviceradar.edge.delivery-id`. Provide
  Go and Elixir implementations and cross-language golden vectors for both slot
  kinds, both delivery-proof states, and unknown-version fail-closed rejection.
  IMPLEMENTED as the single-source pure codec in `usp-v2-04-publication-identity`
  (`go/pkg/edge/edgerecord/publication_identity.go` +
  `ServiceRadar.Edge.PublicationIdentity`): validated encoders, a strict decoder
  (canonical base64url incl. CR/LF rejection, exact EOF, bounded length prefixes,
  known domain/version/kind/mode), a `ValidateHeaderSet` trust-context validator,
  and Go/Elixir vectors covering every mode, raw preimages, values above 2^32,
  sequence exhaustion, and the shared malformed-header reject battery.

- [ ] 1.15 Add Go and Elixir cross-language vector fixtures for the frozen
  completion-leaf disposition enum. The inventory is NOT "one per value": VALID
  leaf/preimage vectors, naming values by the numbers the enum requirement freezes
  (this is a COVERAGE inventory, not a second declaration), for
  `MTR_COMPLETION_DISPOSITION_TRACE_ALLOCATED=1` (the
  only value carrying a UUIDv7 `trace_id`), `..._NOT_ADMITTED=2`,
  `..._PROBE_FAILED=3`, `..._QUARANTINED=4`, and `..._SCHEDULER_LOST=5`; plus
  REJECT vectors for `MTR_COMPLETION_DISPOSITION_UNSPECIFIED=0`, `-1`, `6`, and
  `999`. Zero is rejected BEFORE hashing, so an accepted leaf vector for it would
  contradict the normative rule. The numbering is distinct from the per-hop
  `MtrOutcome`.
  ZERO-MTR (`expected == 0`) IS AN OPEN DECISION, NOT A SELECTION. Two candidates:
  (A) no completion proof required, `mtr_ordinal_range_commitment` EMPTY, and any
  computed root over zero leaves (all three 32-byte accumulators zero,
  `plan_root_sha256` still committed); or (B) a proof always required, with a
  defined zero-leaf root the accumulator accepts. Choose ONE before writing
  vectors.
  BLOCKER, MUST BE RESOLVED BEFORE 1.4/1.15 AND THE 1.7 FREEZE: the zero-MTR
  behaviour described here CONTRADICTS all three implementations. Verified at this
  base: `NewMtrCompletionAccumulator` sets an error when `expected == 0`
  (`go/pkg/edge/edgerecord/domain.go:722`); the Elixir verifier rejects zero
  (`hash_grammar.ex`); and the Go lifecycle validator requires a 32-byte
  completion digest, a matching digest version, and 32-byte plan/range roots for
  EVERY COMPLETED event unconditionally (`domain.go:182-186`), so a COMPLETED
  sweep with no admitted MTR targets can neither omit a proof nor construct a
  valid one. Record ONE authoritative behaviour -- candidate (A) with the lifecycle
  validator relaxed, or candidate (B) -- and add vectors, before
  either task proceeds. Do NOT freeze the ABI over an unreconciled rule.
  UNSUPPORTED-VERSION coverage is the vector ASSIGNED BY EACH OBJECT'S PROOF CLASS
  in task 1.6 -- Class-B objects have NO version input and SHALL NOT be asked for
  an unsupported-input vector. Add matching field-framed grammar
  vectors proving Go/Elixir byte equality for the `EdgeOutputContractRef`
  output-contract grammar, the `EdgeProductionClaimsV1` / `EdgeSourceClaimsV1` /
  `EdgeDeliveryClaimsV1` claim grammars (including the field-framed `transition`
  oneof and its framed member), the plan grammars (`RangeDigest` /
  `PlanPageDigest` / `PlanRoot` / `PlanHeaderDigest`, `plan_grammar_version = 1`),
  and the recovery grammars (`EdgeLossManifestPageV1` / `SpoolLossTombstoneV1` /
  `RecoveryResolvedV1`, `recovery_grammar_version = 1`). FOR UNSUPPORTED-VERSION
  coverage do NOT restate a per-grammar list here -- use the EXHAUSTIVE Class-A /
  Class-B gate frozen in task 1.6, which assigns every Appendix A object to exactly
  one proof class -- each Appendix A object carries the rejection vector ASSIGNED BY
  ITS CLASS, and Class-B objects have no input version so they SHALL NOT be asked
  for one. The shorter list here omitted objects such as `ManifestRoot` and the
  manifest-page scope digest while requesting an unsupported-INPUT vector for
  objects that have no version input.
