## 0. REVIEW SCOPE AND STOPPING RULE (normative for this change)

This section governs what may BLOCK a task or a PR in this change. It exists because the
review loop stopped converging: rounds began finding proof-surface gaps faster than defects,
and a proof surface has no natural end -- there is always one more axis nothing pins.

### A rejection BLOCKS only when it is one of these

  B1  DISAGREEMENT WITH THE NORMATIVE CONTRACT BY EITHER RUNTIME -- on acceptance, on a
      digest, on a (label, gate) pair, or on wire meaning. Cross-runtime disagreement is
      ONE case of this, not the definition. Two runtimes that AGREE on the wrong frozen
      transcript, or that both reject bytes the spec requires be accepted, are a B1: the
      contract is the authority, and "Go and Elixir match" is evidence, not the standard.
      This is what a naive parity rule misses, and a frozen ABI is exactly where it
      matters -- agreement locks the error in.
  B2  A CRASH, a FAIL-OPEN path, or UNBOUNDED WORK -- including a ceiling enforced after
      the work it is meant to bound.
  B3  A REQUIRED TEST MISSING FROM CI OR BAZEL -- a suite no required job runs proves
      nothing about what CI accepts.
  B4  GENUINE NORMATIVE AMBIGUITY -- the spec does not decide something an implementer
      must decide.

### A rejection does NOT block when it is one of these

  N1  AN EQUIVALENT REWRITE -- a different structure with the same observable behaviour.
  N2  MUTATION-SCORE COMPLETION -- "this mutation survives" is not itself a defect unless
      the surviving mutation is a B1-B4 class change.
  N3  REASON ORDERING BETWEEN STATES PROTOBUF CANNOT PRODUCE -- precedence between two
      hand-built-only shapes.
  N4  MORE FORENSIC PROSE -- history belongs in PR bodies and `design.md`, never in the
      ledger or in code comments.

A non-blocking finding is recorded as a follow-up, not held against the checkbox.

### Proof surface: what is DONE being expanded

TOTALITY over `term()` inputs is KEPT -- the public validators accept `term()`, so they must
return `{:error, reason}` rather than raise. What is CLOSED to further expansion is the
proof investment around states PROTOBUF CANNOT PRODUCE: out-of-width integers, improper
lists, arbitrary scalar types, forged struct maps, and precedence between impossible shapes.
Those checks STAY; their mutation coverage does not grow.

THE RULE IS BEHAVIOURAL, NOT AN API SHAPE. This change freezes BEHAVIOUR, so it does not
get to freeze module topology. What is required is: ONLY A RAW-BYTE PATH MAY CLAIM WIRE
HYGIENE OR A PHYSICAL CEILING. A decoded-struct helper may be public, but it SHALL state
what it does not see -- it cannot know what the wire carried, so it cannot claim unknown-
field rejection or a received-byte bound. Exposing a raw ingress is the usual way to satisfy
that; it is not the only one.

### Re-opening a closed area

The CONCRETE-REPRODUCER requirement applies ONLY to the closed area above -- expanding proof
around impossible shapes and mutation-proof completion. There, re-opening needs a wire input
or a production-path trace; "a mutation survives" is not a reproducer.

IT DOES NOT APPLY TO B1-B4. A missing CI or Bazel registration (B3) and ambiguous normative
text (B4) are reported and fixed on sight, with no reproducer, in any area -- a rule that
suppressed them would suppress exactly the findings that keep being right.

### What #4780 finishes, and what it does NOT

#4780 CLOSES with: the current review corrections (Bazel registration, the error-only decode
propagation helper, exact mode-bit membership, the sentinel claim narrowed to ONE
REPRESENTATIVE PER FAMILY rather than an exhaustive branch matrix); 1.2-c step 3 integration
under the translation frozen in that subtask; the five remaining time pairs; non-vacuous
overflow fixtures; 1.3-c's trace vector; and the shared corpus. The transitive golden
changes are reviewed ATOMICALLY, the required gates run, and it merges.

#4780 does NOT wait for 1.5-f. The critical path is `1.5-f -> 1.2-c -> 1.3-f -> 1.15-b`, and
the blocked checkboxes stay UNCHECKED rather than dragging compression admission into this
PR. Compression is the NEXT PR.

### Estimate discipline

The remaining freeze is NOT one to two weeks. SEVEN open parents and TWENTY-ONE unchecked
named subtasks remain (1.3 and 1.17 are closed and do not count), including EIGHT of 1.5's
TWELVE obligations -- twelve, not eleven, because the body's refusal-classification
obligation had no subtask and the exhaustiveness rule below requires one (1.5-l). COMPRESSION ADMISSION (1.5-f) IS CLOSED, and closing it released the
chain it was blocking: 1.2-c, 1.3-f, task 1.3 and 1.15-b are all checked. Three to six
focused weeks remains the honest range for the rest, depending on how much of 1.5 proves
already implemented during closeout.

## 1. Freeze the edge record v1 wire ABI

Scope: the wire contract and the grammars that identify it. Everything runtime --
producer sinks, spool mechanics, gateway relay, JetStream, projectors, migration --
stays in the downstream `unify-sweep-results-proto` change and is NOT reviewed
here.

- [ ] 1.1 Add a producer-neutral authoritative `EdgeRecordV1`, a separate
  `EdgeDeliveryFrameV1`, the typed disposition and resolved-watermark
  contracts, and lane-opening/session handshake.
  ASSIGNED HERE BY TASK 1.3: the OUTER RECORD `event_id` UUIDv7 OVERFLOW vector.
  `validateIdentityTime` now calls the shared CHECKED helper `UUIDv7Nanos`, delivered by 1.3.
  What is still OWED here is the VECTOR: a shared helper proves nothing about a caller that
  does not use it, and nothing currently fails if this call site stops using it. The vector
  must carry a 48-bit timestamp whose unchecked product would WRAP into the production/source
  windows. The disposition enum on the wire
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

  STATUS
  - LANDED: `EdgeRecordV1`, `EdgeDeliveryFrameV1`, the typed disposition enum and the
    lane-open/session handshake shapes are frozen in Appendix A and generated in both
    runtimes; the semantic-envelope digest and record validator are implemented and
    mutation-verified.
  - REMAINING: see subtasks 1.1-a..b below; not restated here.
  - DEPENDS ON: nothing open. 1.15 supplies the shared fixture corpus but does not gate the
    local vector.
  - EVIDENCE: `go/pkg/edge/edgerecord/validate.go`, `proto/edge/v1/record.proto`,
    `proto/edge/v1/testdata/record.bin`.

  SUBTASKS (parent stays unchecked until all close)
  - [ ] 1.1-a the typed Hello carrier
  - [ ] 1.1-b the outer-record `event_id` UUIDv7 overflow vector (assigned by 1.3). The
        shared checked helper `UUIDv7Nanos` exists and `validateIdentityTime` calls it, so
        what is owed is the VECTOR proving this call site rejects rather than wraps -- not
        the fix

- [ ] 1.2 Add compact `SweepObservationBatchV1` and mergeable
  host/ICMP/TCP/MTR-summary messages with exact `(mode, protocol, port)` check
  dictionaries, per-mode revisions/outcomes, per-host observation time,
  plan/range digests, presence, bounds, and stable correlation keys.

  STATUS
  - LANDED: `SweepObservationBatchV1` and the mergeable summary shapes are frozen and
    generated in both runtimes, carry golden fixtures consumed byte-for-byte by the Elixir
    golden test, and have a full Go body validator (`ValidateSweepObservationBatch`).
    ELIXIR NOW HAS BOTH PEERS: the CORRELATION relation (`SweepCorrelate`, landed by 1.3-f)
    and, as of 1.2-c, the RAW stage (`WireDecode.decode_sweep_batch/1` -- extracted-body
    work ceiling, recursive wire hygiene, unknown-field rejection) plus the DECODED BODY
    VALIDATOR (`SweepBodyValidate` -- exact shapes, per-width bounds, enum/domain checks).
    INTEGRATION HAS LANDED TOO: `SweepCorrelate.ingest_own_payload/1` composes the curated
    decode, the full body validator and correlation into ONE call, so a body rejection and a
    correlation rejection no longer reach callers from two places. What keeps 1.2 open is
    1.2-a's closeout audit -- not missing work. 1.2-c's 1.5-f dependency is satisfied.
  - REMAINING: see subtasks 1.2-a..c below; not restated here.
  - DEPENDS ON: nothing open. The 1.5-f CLOSURE dependency is DISCHARGED -- 1.5-f is closed
    and 1.2-c is checked; see 1.5-f for the ownership and the original reason.
    NOT a dependency on 1.3-f; that edge runs the other way, 1.3-f -> 1.2-c.
  - EVIDENCE: `proto/edge/v1/sweep.proto`, `ValidateSweepObservationBatch`; for the raw
    stage `WireDecode.decode_sweep_batch/1` with
    `test/serviceradar/edge/sweep_batch_decode_test.exs`; for the decoded body
    `ServiceRadar.Edge.SweepBodyValidate` with
    `test/serviceradar/edge/sweep_body_validate_test.exs`.
    BOUNDS EVIDENCE is per protobuf integer width -- `uint32`, `uint64`, `int64`, `sint64`
    and `int32` -- each with its own table and its own reported width. COVERAGE IS
    DESCRIPTOR-DERIVED, so the counts live in the test, not here: all EIGHT sweep message
    inventories are pinned against `__message_props__/0` by field number, name, type and
    cardinality, and every integer field in them must appear in exactly one width table
    (`sweep_body_validate_test.exs`). int32 is reachable ONLY through enums, since proto3
    enums are open. `sint64` keeps a helper separate from `int64` despite the shared range.
    The shape/width pass has NO Go peer: Go's generated struct makes those states
    unrepresentable.
    FAMILY -> GO SENTINEL is pinned exactly as data, and BEHAVIOURALLY on the Go side by
    `TestSweepBodyFamilySentinelsAreBehavioural`, which fails if a Go branch changes which
    sentinel it returns. The family strings remain duplicated across runtimes -- the
    sweep-join corpus does NOT close this, since it carries correlation labels rather than
    the body-family mapping -- until a body-family corpus of its own exists.
    ORDER: batch-level and per-host precedence, and the two structure/semantics
    interleavings, are each pinned by multi-invalid vectors.
    DOMAINS ARE BORROWED, never restated: admitted enum members from
    `SemanticValidate.enum_field_policy/0`, the allocated-MTR subset from the NEUTRAL
    `SweepOutcomePolicy`, the source set from `SweepMatrix`, mode-bit NUMBERS from the
    generated `SweepModeBit` (with `TestSweepModeBitTableIsExact` pinning Go's own switch),
    and each enum's atom domain from its own generated `mapping/0`. `SweepOutcomePolicy`
    depends on neither consumer, which is what keeps the 1.2-c <-> 1.3-f edge one-way once
    step 3 routes the body validator into the correlation path.
    INGRESS: `SweepBodyValidate.validate_bytes/1` composes the curated decoder with the body
    validator and returns the validated batch. Claim-variant structure is
    `ServiceRadar.Edge.CapabilityClaims` -- the ONE predicate shared by capability signature
    verification and the sweep recovery-lane preflight, pinned against
    `EdgeSignedCapabilityV1.__message_props__/0` in BOTH directions by
    `test/serviceradar/edge/capability_claims_test.exs`, so a proto-side variant addition
    fails loudly instead of being classified as malformed everywhere. That is the
    ELIXIR-SIDE drift gate; Go pins the same oneof in `TestFrozenSchemaInventories`. The
    CORRELATION half
    is 1.3-f's; its evidence is listed under task 1.3, not duplicated here.

  SUBTASKS (parent stays unchecked until all close)
  - [ ] 1.2-a field-by-field closeout audit against what shipped
  - [x] 1.2-b DECIDED: the CORRELATION peer belongs to 1.3-f and has landed
        (`SweepCorrelate`); the Elixir FULL BODY VALIDATOR belongs to 1.2. This item is
        the DECISION, and it is closed
  - [x] 1.2-c the Elixir FULL BODY VALIDATOR for `SweepObservationBatchV1`: shape, bounds,
        recursive wire hygiene and unknown-field rejection via a curated `WireDecode` entry
        point, under the EXTRACTED-BODY WORK CEILING (32 MiB, mirroring Go's
        `MaxUncompressedBytes`).
        NOT a "received-byte ceiling": 512 KiB is the PHYSICAL bound on the outer record
        and its encoded/compressed payload. A compressed payload under that bound may
        legitimately EXPAND past it, and Go decodes the expanded body with no second
        physical cap -- so a 512 KiB bound at this stage would permanently reject valid
        records. 1.2-c's vectors are inputs to THIS STAGE and assert nothing about
        composed-record reachability.
        Extraction, the ratio rule, trailing frames, the normative 32 MiB freeze and
        composed-record reachability are 1.5-f's -- see 1.5-f. Buildable now, closable only
        after it.
        BOUNDS EVIDENCE SHALL enumerate EACH protobuf integer width separately -- `uint32`,
        `uint64`, `int32`, `int64`, `sint64` -- not a single "bounds checked" claim. A
        `uint32` field guarded against a `uint64` ceiling accepts 2^32, which the wire
        cannot carry -- `digest_version` and `execution_shard` are two such
        fields. `SweepCorrelate` names this as a PRECONDITION
        and does not substitute for it, so 1.3-f's last-gate proof is incomplete until
        this lands -- see 1.3-f's DEPENDS-ON note
        STEPS
        - [x] step 1 RAW DECODER -- `WireDecode.decode_sweep_batch/1`: the work ceiling,
              recursive wire hygiene, unknown fields and groups
        - [x] step 2 DECODED BODY VALIDATOR -- `SweepBodyValidate`: exact shapes, per-width
              bounds, enum/domain checks, in Go's rejection ORDER; see the parent EVIDENCE
        - [x] step 3 INTEGRATION -- LANDED as `SweepCorrelate.ingest_own_payload/1`:
              extracted payload -> curated decode -> FULL body validation -> correlation,
              from one call. `correlate_own_payload/1` could not be this: it decodes with
              the GENERATED decoder and assumes precondition 6 (someone already ran the body
              validator), so a body defect and a correlation defect reached callers from two
              places and nothing made the first actually run. DECODER reasons get their own
              `{:wire, reason}` gate rather than folding into `{:payload, :decode}`, because
              the `:poison` / `:not_ready` / `:systemic` split is the one classification that
              stage exists to make. Mutation-verified, three killed: skipping the body
              validator, passing body reasons through untranslated, and collapsing the
              decoder reasons.
              FIXTURE FINDING: the correlation control batch was never body-VALID -- it
              carried only the fields correlation reads. Before step 3 nothing required one
              batch to satisfy both stages, so the composed tests build a fixture that does,
              without touching any field correlation compares.
              THE SHARED CORPUS IS NOT A 1.2-c REMAINDER -- 1.3-f owns it exclusively, and
              1.2-c does not depend on 1.3-f (that edge runs the other way). With step 3
              landed, and its 1.5-f CLOSURE dependency is now satisfied -- 1.5-f is closed.
              THE RESULT TRANSLATION IS SETTLED IN ADVANCE, as
              `SweepCorrelate.translate_body_reason/1`: `{:source_run_id, label}` ->
              `{:body, label}` and `{:source, :unknown}` -> `{:enum_admission, :source}`,
              because both rules are decided in BOTH validators and a caller matching the
              frozen outcomes must keep working. Every OTHER family enters under the ONE
              added gate, `{:body_validation, {family, detail}}` -- `{:body, label}` is
              frozen to carry a `SweepMatrix.label()`, so routing arbitrary families through
              it would break that invariant. The mapping is TOTAL over the validator's
              family set, so a new family cannot reach the union undecided

- [x] 1.3 Add `SweepExecutionEventV1` start, progress/watermark, completion, and
  aborted evidence per assignment attempt; an immutable scheduler plan that
  uses a bounded header plus content-addressed range pages for arbitrary target
  sets and contains ranges/checks but not future attempts; and append-only authoritative
  assignment records including scheduler-authored lost/expired/superseded
  terminals, shard/range digests, terminal sequences, counts, expected MTR,
  configuration identity, epoch, lease/fence, and authorization metadata.
  `SweepAssignmentRecordV1` exists in `proto/edge/v1/sweep.proto`
  with a REQUIRED `SweepMtrExpectationV1` (`ordinal_count` + `ordinal_range_commitment`
  together), append-only `record_sequence`, scheduler-authored LOST/EXPIRED/SUPERSEDED
  states, lease/fence, a RESOLVABLE range binding (`target_range_id` +
  `target_range_sha256`, NOT an opaque set commitment), and configuration/authorization
  identity, validated by `ValidateSweepAssignmentRecord` and related to the committed
  plan by `ValidateAssignmentAgainstPlan` (plan id/hash, check set, policy,
  scope, and RANGE MEMBERSHIP). The count is CARRIED, never derived from the producer's
  counters, from the non-invertible commitment, or from `mtr_admission_budget` (a
  ceiling).
  IMPLEMENTATION NOTE (non-normative): the received-bytes boundary for the scheduler
  plan page is `edgerecord.ValidatePlanFromRaw` in Go and
  `ServiceRadar.Edge.WireDecode.decode_plan_page/1` in Elixir. These are NOT peers and
  are not claimed to be: the Go entry bounds and validates a whole raw page CHAIN
  against its header, while the Elixir entry bounds and decodes ONE page, with the
  chain relation run afterwards by `PlanValidate`. `edgerecord.ValidatePlanPages`
  measures a RE-MARSHAL and is a deliberately coarse guard for callers holding decoded
  structs -- it is NOT the physical ceiling.
  LANDED (#4775, with the spec freeze and Elixir peers following): the record carries
  `run_id` and the optional source identity; `CompiledSweepAssignmentV1` supplies the
  compiled facts (config generation, typed result format, immutable traffic class,
  check-set identity, validity window) under a scheduler COLLECTION attestation, and the
  record REFERENCES it by id + artifact digest; permission to EXECUTE that carrier is a
  separate HOST `ASSIGNMENT_EXECUTION` grant. Both compiled-assignment digest grammars and
  both claim tables are frozen in Appendix A, with shared Go-authored vectors.

  LANDED in 1.3: the `SweepObservationBatchV1` CORRELATION MATRIX. It was DESIGNED and
  merged (#4779) and is now BUILT -- the 1.3-a..1.3-f checklist below is CANONICAL and every
  item on it is checked. No other passage in this file restates it: one list has one place
  to edit.

  Both Elixir peers have landed. `CompiledAssignmentValidate` covers the CARRIER: structure,
  both self digests, the attestation's binding across every member it commits, the record
  relation, the lease constraint, and the 64 KiB received-byte ceiling via a curated
  `WireDecode.decode_compiled_assignment/1` that also runs the recursive wire-hygiene gate.
  `ExecutionGrantValidate` covers the GRANT: every claim member interpreted against the record
  and carrier, the required plan/range lengths, traffic class equal to the carrier's,
  collection-window containment in the envelope, the exact-carrier binding, source identity
  present exactly when the record's is, and the 16 KiB received-byte ceiling via a curated
  `WireDecode.decode_execution_grant/1`. Freshness is a separate `fresh_at/2`, since it asks
  about an instant rather than a shape.
  Neither peer VERIFIES a signature or AUTHORIZES collection: those need key material, a trust
  resolver, an attested caller and the authoritative record, and belong to the composed
  boundary Go implements as `AuthorizeCollectionNow`. No Elixir peer of that is claimed.
  The last 1.3 work was the correlation matrix alone -- SIX deliverables. This is the
  TRACKING copy: 1.3 was held unchecked until all six were, and the six were checked AS THEY
  LANDED so the ledger never read as if none of 1.3 had shipped. All six are checked, and so
  is 1.3.
  - [x] 1.3-a Go OPERAND SELECTION in `joinSweepAuthority`, consuming the pinned mapping as
        its SOLE kind lookup
  - [x] 1.3-b Go DISPOSITION ENFORCEMENT in `ValidateSweepObservationBatch` (`source_run_id`
        presence, absence, canonical form)
  - [x] 1.3-c the SHARED CHECKED UUIDv7 millisecond-to-nanosecond helper, plus 1.3's own
        sweep-summary `trace_id` overflow vector (the 1.1 and 1.4 call-site vectors are
        assigned to those tasks). The helper landed in slice 1; the vector needed a FULL
        RECORD fixture and lands with the shared corpus as
        `sweep_join_trace_time_overflow.bin`, asserted by both runtimes
  - [x] 1.3-d DECLARE THE LABEL NAMES in both runtimes: the fifteen frozen strings exist as
        one vocabulary in Go (`SweepJoinLabel`, backed by a canonical registry the private
        constructors enforce) and Elixir (`SweepMatrix.labels/0`), and each inventory pins
        the exact SET. NAMES ONLY -- EMISSION and the (label, gate) PAIR belong to 1.3-f,
        which states their current coverage
  - [x] 1.3-e the EXACT MAPPING INVENTORIES in Go AND Elixir. NOT subsumed by the parity
        vectors: the requirement says vectors SAMPLE, and only an exhaustive inventory shows
        the mapping is total, injective, and excludes the two unreachable kinds. An inventory
        and a vector set prove different things
  - [x] 1.3-f the Elixir peer, the SHARED PARITY VECTORS, and any FURTHER fixture changes
        those vectors produce. EXPLICITLY INCLUDES, handed over by 1.3-d: Elixir EMISSION of
        the fourteen correlation labels, and the JOINT (label, gate) vector proof in BOTH
        runtimes -- every LABELLED vector asserts the portable label AND the owning gate's
        typed outcome in ONE assertion, so neither can be changed alone. UNLABELLED vectors
        (UNSPECIFIED, RECOVERY_CONTROL) assert only their owning gate.
        (i), (ii), (iii) AND (iv) HAVE ALL LANDED. NO REMAINDER.
          (i)   DONE -- the FIVE time-label pairs (`batch_time_window`, both host labels,
                both trace labels) now pin label AND gate in one assertion, in both
                runtimes. `uuidv7At/2` was added so a vector can place a trace time outside
                the window or above the ns-conversion ceiling; `uuidv7/1` always carries
                `fixedMillis` and could express neither.
          (ii)  DONE, and CONSTRUCTED AS THE SPEC REQUIRES -- each overflow vector's
                naively wrapped value lands INSIDE the window, so an UNCHECKED
                implementation ACCEPTS it. Proven by verdict, not by label: removing either
                check makes both records validate clean.
                An earlier attempt wrapped OUTSIDE the window and leaned on the label
                changing instead. That contradicted a SHALL, and code does not get to
                replace one silently. The trace path needed only a different timestamp --
                20_230_744_073_710 ms wraps to 1_784_000_000_000_448_384 ns, inside the
                canonical window, because the overflow is in the MULTIPLICATION and a 48-bit
                ms field can reach any wrapped value. The HOST path cannot do this with the
                canonical window at all: the base is ~1.78e18 ns, an overflowing int64 sum
                wraps to about -7.4e18, and returning would need a delta near 2^64. It
                therefore carries its OWN committed positive control with a signed window
                spanning the negative range, and differs from THAT control in exactly one
                comparison -- the delta -- which satisfies both SHALLs rather than trading
                one off against the other.
          (iii) DONE, and REQUIREMENT-complete rather than label-complete. FORTY-NINE shared
                vectors under `proto/edge/v1/testdata/`, written by Go and consumed by
                Elixir through `ingest_own_payload/1`, with the expectation travelling
                beside the bytes in `sweep_join_corpus.txt` so Elixir DERIVES it.
                An earlier seventeen-vector corpus covered all fifteen labels exactly and
                was still far short of the normative inventory: label-completeness proves
                each label is REACHABLE, while the spec requires vectors PER SOURCE ROW, PER
                DISPOSITION ROW and on BOTH SIDES of every window. Manifest-to-disk equality
                only proves two incomplete sets agree.
                The inventory now covers: five per-source POSITIVE controls; five
                selected-context mismatches; five kind mismatches plus INTEGRATION_RUN;
                RECOVERY_CONTROL at the LANE gate, not correlation; the eight disposition
                vectors (two forbidden-presence, three required-absence, three malformed --
                per row, not sampled); UNSPECIFIED and absent-authority; six
                source-independent relations on one representative row; the EIGHT time
                negatives (batch two, host three, trace three); SIX endpoint controls --
                batch, host and trace at BOTH ends, each inside a capability envelope
                widened strictly beyond the collection window, since an observation sitting
                on a collection endpoint that is also an envelope endpoint cannot show which
                window admitted it; the wide-window control; and the NONCANONICAL payload -- a duplicate known
                singular field, 243 carried bytes against 233 re-encoded -- which both
                runtimes must ACCEPT, proving `payload_sha256` is checked against the exact
                carried bytes.
                THE BATCH-TIME NEGATIVES COUNTER-ADJUST THE HOST DELTA. Host absolute time
                is batch time plus the delta, so moving the batch time with a zero delta
                breaks TWO comparisons and proves neither -- delete the batch predicate and
                the host one still rejects. Holding the host instant fixed leaves exactly
                one comparison different, and deleting the batch predicate now ACCEPTS.
                Go asserts the OWNING GATE before writing it to the manifest, including
                not-the-other-gate. A gate name written unchecked is a claim Elixir then
                derives its expectation from.
          (iv)  task 1.2-c, under task 1.2 -- LANDED and CHECKED. Its 1.5-f closure
                dependency is DISCHARGED, so it no longer holds 1.3-f either.
        NO LONGER BLOCKED. It was blocked on 1.2-c, and NOT for the original reason -- that
        reason (a vector cannot satisfy a last-gate proof by stating an UNENFORCED
        precondition occurred) went obsolete once `ingest_own_payload/1` began running the
        body validator on the correlation path, so the corpus consumes an ingress that
        enforces it. What remained was the ordinary ordering dependency, now DISCHARGED:
        1.2-c was unchecked on its 1.5-f closure, 1.5-f is closed, and 1.2-c is checked
        ahead of 1.3-f as required. 1.2-c consumes the matrix semantics already landed in #4779, adds no new
        matrix semantics, and does not depend on 1.3-f, so the only edge is 1.3-f -> 1.2-c.
        The BASELINE regeneration is already LANDED: making the
        canonical sweep fixture valid under the matrix forced it in slice 1, and the 22
        resulting fixture changes are reviewed there. 1.3-f OWNS these vectors; task 1.15
        ACKNOWLEDGES them as parity evidence (1.15-b) and does not own them

  NOT 1.3 work, recorded here only so neither is lost:
  - the tagged POSITIVE / EXPLICIT_NEGATIVE mapping VALUE and its durable negative reason
    belong to task 2.20a. 1.3 froze the mapping KEY only and must not be read as having
    frozen the value.
  - `hash_grammar.ex`'s SHARED unchecked `u64/1` helper aliases out-of-range integers
    (0 and 2^64 frame identically) for the PLAN/RECOVERY grammars. The
    compiled-assignment grammars were moved to CHECKED framing here; the older grammars
    were deliberately not widened into without their own vectors. That belongs to task
    1.6, which owns those grammars.
  The authoritative assignment-record contract must be designed before the 1.7 freeze or
  explicitly cut from it, because it is an append-only authoritative contract on
  the frozen ABI. It is also what binds a span's `producer_assignment_id` to the
  scheduler's `execution_plan_id`, which is why the span itself does not carry
  the plan identity.
  SPLIT (boundary reset): this task is now the ABI/SCHEMA/CORRELATION half only --
  the append-only authoritative assignment-record CONTRACT, the frozen
  `SweepObservationBatchV1` correlation matrix (per permitted
  `SweepExecutionSource`: which field is the signed context, whether
  `source_run_id` is required or forbidden, which mismatch is rejected), and the
  assignment-mapping KEY,
  which must be frozen with the span because the span omits execution and plan
  identity on the strength of it.
  THE MATRIX'S VECTOR INVENTORY IS NORMATIVE AND LIVES IN THE SPEC -- the two matrix
  requirements in `specs/edge-producer-data-plane/spec.md`. It is deliberately NOT restated
  here. A ledger copy would be a fourth inventory to keep in sync, and a shorter one would
  read as a smaller job: the real set is roughly forty vectors.
  NOT 1.3, BUT NOT OWNERLESS EITHER -- ASSIGNED TO 1.5: CONTRACT DISPATCH does not bind the
  record's PAYLOAD FAMILY to the output contract. `dispatchContract` compares only the four
  `EdgeOutputContractRef` members and never reads `payload_family`, so a record may present a
  family the contract does not describe and dispatch will not object.
  This is a SEMANTIC ADMISSION relation and it is OWNED BY TASK 1.5, recorded there as an
  obligation. An unowned gap is closed by default when 1.7 checks that its prerequisites are
  closed, so a named owner is what makes it block. 1.3 does not freeze the relation, and the
  correlation requirement says so explicitly rather than implying dispatch already covers it.
  DOWNSTREAM (runtime change): the mapping's
  durable storage, replay/repair state machine, conflict resolution, retention,
  GC, and lookup-outcome transitions. `joinSweepAuthority` checks: source kind, via the
  frozen matrix as its SOLE lookup; `context_id` against the ONE operand that source selects;
  range identity (`scope_id` and `scope_sha256`); plan and target-range digests; execution
  shard against the attested `run_shard`; assignment epoch against `authority_epoch`; and the
  batch, per-host and MTR-trace collection times. The `source_run_id` disposition is enforced
  in `ValidateSweepObservationBatch`, since it is body-decidable. Nothing
  compares `run_id`, and nothing MAY: the span requirement forbids that equality.

  STATUS
  - LANDED: the assignment record + plan model (#4770), the compiled-assignment carrier and
    host execution grant (#4775), the normative grammar freeze (#4776), both Elixir
    validators (#4777), the correlation-matrix design (#4779), matrix slice 1 -- 1.3-a and
    1.3-b, with the shared `UUIDv7Nanos` helper -- matrix slice 2, 1.3-d and 1.3-e, and
    slice 3a's Elixir correlation peer (`SweepCorrelate`).
    THE JOINT (label, gate) PROOF IS COMPLETE, and the shared corpus has landed.
  - REMAINING: nothing. The 1.3-a..1.3-f checklist ABOVE is CANONICAL for this task and is
    fully checked.
  - DEPENDS ON: nothing open. 1.2-c, the Elixir full body validator that blocked 1.3-f, is
    checked. The durable assignment mapping is task 2.20 downstream and SHALL NOT gate this.
  - EVIDENCE: `sweepSourceMatrix` in `go/pkg/edge/edgerecord/domain.go`;
    `elixir/serviceradar_core/lib/serviceradar/edge/sweep_correlate.ex` and its
    `test/serviceradar/edge/sweep_correlate_test.exs` (slice 3a correlation peer);
    `go/pkg/edge/edgerecord/sweep_matrix_test.go` (slice 1 behaviour);
    `go/pkg/edge/edgerecord/sweep_labels.go` and `sweep_inventory_test.go` (slice 2 Go
    vocabulary + inventory); `elixir/serviceradar_core/lib/serviceradar/edge/sweep_matrix.ex`
    and its `test/serviceradar/edge/sweep_matrix_test.exs` (slice 2 Elixir peer table);
    the per-predicate label vectors in `proto/edge/v1/golden_test.go`; and
    `proto/edge/v1/testdata/sweep_batch.bin`.
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
  The completion-leaf disposition is declared ONCE as the generated enum
  `MtrCompletionDisposition`, with the members and numbers frozen by the requirement "MTR completion disposition is one generated enum". Distinct from the per-hop `MtrOutcome` numbering
  (REACHED=1, PROBE_FAILED=3, NOT_ADMITTED=5, QUARANTINED=6, SCHEDULER_LOST=7),
  which it SHALL NOT reuse. Go's `MtrTerminalDisposition` constants and Elixir's
  integer guards become CONSUMERS of the generated enum. NO new leaf message is
  needed: the disposition is a field of the existing leaf grammar. Reject zero,
  negative, and unknown-positive values BEFORE widening to `u64` and hashing, and
  keep later-declared values rejected until the completion grammar version itself
  changes. The number is hashed into the frozen leaf preimage, so a hand-maintained
  pair can produce two different roots for one completion, which is why one generated enum
  replaces the hand-maintained pair. (This target is owned here and by 1.15 only.)
  CLOSED: `MtrCompletionDisposition` is declared in `proto/edge/v1/sweep.proto`
  and both runtimes now read it -- Go's `MtrTerminalDisposition` is a type ALIAS
  of the generated enum (`domain.go`), and Elixir's completion guards derive
  `@disposition_trace_allocated` / `@dispositions_without_trace` from the
  generated module at compile time (`hash_grammar.ex`), so neither restates a
  number. Both runtimes assert the closed set (`0`, `-1`, `6`, `999` rejected;
  `1..5` accepted). `-1` is expressible in Go because the disposition is the
  generated `int32` enum rather than a local `uint32`, so the negative case is a
  real input the closed set must reject rather than an unreachable one.
  RULE: no unvalidated hasher is reachable from outside either runtime. Elixir's
  `mtr_completion_root/4` is PRIVATE and Go exports no equivalent, so an
  unrecognised number has no path to the frozen preimage. Each runtime ALSO pins every
  symbol->number pair and the exact membership
  (`TestMtrCompletionDispositionSymbolNumbers`; "MTR completion disposition
  symbols are pinned to their exact numbers"). That pin is not redundant with the
  closed set: the closed set fixes which NUMBERS are accepted, so SWAPPING two
  valid members -- `QUARANTINED=4` and `SCHEDULER_LOST=5` -- would leave it green
  while changing which meaning is hashed at those numbers, and a quarantined
  ordinal's completion root would silently become a scheduler-lost one's.
  EVIDENCE: the closed-set and symbol-pin tests in both runtimes. They are separate
  tests on purpose -- a renumbering and a symbol SWAP fail different ones, so neither
  alone pins the mapping. The mutation record proving that is in `design.md`.
  STILL 1.15: the SHARED cross-language leaf fixture both runtimes read. Each runtime
  currently pins the mapping against its OWN generated enum, so a divergence is caught
  only because both generate from one proto; 1.15 replaces that argument with
  per-value vectors both runtimes decode.
  1.4 REMAINS UNCHECKED. Zero-MTR is NOT among its reasons: both runtimes implement the
  mandatory canonical zero-leaf proof, so a COMPLETED sweep admitting no MTR targets has
  exactly one valid representation.
  WHAT BLOCKS 1.4 IS LOCAL ABI/SCHEMA WORK ONLY. Task 1.7 requires every local task
  to close, so anything named here becomes a 1.7 gate; blocking 1.4 on runtime
  wiring would make the ABI wait on `unify-sweep-results-proto`, which waits on the
  frozen ABI. The remaining local work is subtasks 1.4-a..c; it is NOT restated here.
  ONE ITEM IS RECORDED AS CLOSED, because its rationale is a live rule rather than a
  remaining obligation:
  CLOSED by 1.3's assignment record: `range_root_sha256` is RETIRED (tag 20 and
  the name reserved) rather than defined: an assignment's range binding must not be a
  self-reported lifecycle field, and the authoritative binding is now the assignment's
  RESOLVABLE `target_range_id` + `target_range_sha256` -- NOT an opaque set commitment,
  which could not say WHICH ranges were assigned. And the required `SweepMtrExpectationV1` STATES
  the admitted ordinal count, so "32 zero bytes means none admitted" is now written
  down AND checkable -- `ordinal_count == 0` and the 32-zero commitment must agree in
  both directions, which the non-invertible commitment alone could never establish.
  NOT A BLOCKER ON 1.4: that no consumer performs the check.
  `VerifyCompletionAgainstPlanState` is a PRIMITIVE whose caller must supply
  already-validated plan state, and wiring a real carrier is downstream task 2.3b.
  Implementing a verifier is not ABI work, and 1.4 SHALL NOT wait on it.

  STATUS
  - LANDED: `MtrTraceBatchV1`/`MtrTraceEventV1` contracts, the per-variant correlation
    dispatch, `MtrCompletionDisposition` as a generated enum (#4766), and zero-MTR
    completion as a mandatory canonical zero-leaf proof (#4769).
  - REMAINING: see subtasks 1.4-a..c below; not restated here.
  - DEPENDS ON: 1.15's shared per-value leaf vectors.
  - EVIDENCE: `joinMtrAuthority` in `go/pkg/edge/edgerecord/domain.go`,
    `proto/edge/v1/testdata/mtr_batch.bin`.

  SUBTASKS (parent stays unchecked until all close)
  - [ ] 1.4-a the MTR vectors
  - [ ] 1.4-b full-MTR `trace_id` UUIDv7 overflow vector (assigned by 1.3)
  - [ ] 1.4-c full-MTR `event_id` UUIDv7 overflow vector -- SEPARATE from 1.4-b, because the
        two `uuidTimeWithin` calls are independently removable

- [ ] 1.5 Define compatibility rules for unknown fields/enums, unsupported
  versions, timestamp units, optional zero-valued measurements, ASN observation semantics,
  ASSIGNED HERE BY TASK 1.3 (see its ledger): the PAYLOAD FAMILY <-> OUTPUT CONTRACT
  admission relation. `dispatchContract` compares only the four `EdgeOutputContractRef`
  members and never reads `payload_family`, so a record may carry a family the contract does
  not describe and dispatch will not object. 1.5 SHALL either freeze the relation -- with
  vectors, in both runtimes -- or record an EXPLICIT DECISION that v1 requires no such
  relation and why. What it SHALL NOT do is leave it unstated: an unowned gap is closed by
  default when 1.7 checks that its prerequisites are closed, which is how a real hole ships
  inside a freeze.
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
  measurements, ASN observation semantics,
  string/count/byte/relational-row bounds, the FROZEN field-framed
  semantic-envelope digest grammar (NO domain tag; leads with the committed `u64`
  constant `semanticDigestVersion = 3` -- not a wire field, fixed by the record-schema
  ABI; FIXED field order, no per-field numeric tags; 8-byte big-endian integers;
  8-byte big-endian length prefixes; 1-byte presence markers; `u64` (8-byte) oneof
  discriminants; `u64` repeated-element counts; recursive field-by-field nested
  framing; NO `proto.Marshal` at any depth),
  streaming
  compression expansion, COMPRESSION recursion (a frame wrapping a frame -- not protobuf
  MESSAGE recursion, which is 1.5-a's), and trailing-frame rejection. The candidate PR for the
  compression-admission half, **#4734** (base `usp-01-proposal`), is CLOSED WITHOUT BEING
  MERGED -- #4734 itself owns no landed code, and is prior art rather than delivery. The
  obligation is now met by `usp-32-compression-admission`; see 1.5-f. Define the
  immutable semantic-envelope digest separately from gateway receipt, physical
  placement, spool coordinates, and renewable delivery proof; define broker
  publication identity separately. Make projected row cost cover every
  synchronous ledger/domain/outbox/work/current-state mutation, and canonicalize
  nanoseconds to PostgreSQL microseconds ONLY for projection-domain STORAGE AND ORDERING
  coordinates -- no projection hash or identity comparison consumes a canonicalized time --
  and only AFTER the two contract hashes are taken. `payload_sha256`
  hashes the EXACT CARRIED PAYLOAD BYTES; `semantic_envelope_sha256` hashes the frozen
  FIELD-FRAMED TRANSCRIPT, which commits `payload_sha256` and the RAW NANOSECOND values.
  Neither may see a canonicalized timestamp.
  CURRENT STATE: the negative-enum divergence this task exists for IS closed --
  `WireValidate` structural preflight then `SemanticValidate.disposition/2`
  mapping to `EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT`, with the LAST-ONE-WINS case covered by the
  SHARED fixture `lane_open_negative_then_valid.bin` referenced from both
  runtimes. The residual clauses (timestamp units, optional zero-valued
  measurements, unsupported-version handling) were NOT verified clause-by-clause and remain
  open. ASN observation semantics is CLOSED -- see 1.5-e. The exact-received-bytes rule also applies here,
  and for `ScheduledPlanPageV1` it is now SATISFIED: `ValidatePlanFromRaw` (Go)
  and `WireDecode.decode_plan_page/1` (Elixir) bound the RECEIVED bytes before
  decoding, with shared at-limit / one-over vectors. `ValidatePlanPages` still
  measures a re-marshal and is retained only as a coarse decoded-struct guard.

  STATUS
  - LANDED: the enum-compatibility parity analysis and the Elixir `SemanticValidate` /
    `WireDecode` / `WireValidate` gates.
  - REMAINING: 1.5-b, 1.5-d and 1.5-g..1.5-l. 1.5-a, 1.5-c, 1.5-e and 1.5-f are CLOSED. The subtask list is
    exhaustive against this task's body -- see the EXHAUSTIVENESS note under the subtasks.
  - DEPENDS ON: nothing open. Compression admission (1.5-f) is CLOSED, delivered on
    `usp-32-compression-admission`; #4734 remains closed unmerged and is prior art, not
    delivery.
  - EVIDENCE: `dispatchContract` in `go/pkg/edge/edgerecord/domain.go`,
    `elixir/serviceradar_core/lib/serviceradar/edge/semantic_validate.ex`.
    COMPRESSION ADMISSION (1.5-f): the frozen values and stages are the spec requirement
    "Compression admission is frozen by value, stage, and frame shape"; the runtimes are
    `go/pkg/edge/edgerecord/compression.go` + `validatePayloadBinding` in `validate.go` and
    `elixir/serviceradar_core/lib/serviceradar/edge/compression.ex`
    (`validate_payload/2`, `admit_declared/2`, `admit_record/1`); the cross-runtime evidence
    is `proto/edge/v1/testdata/zstd_*.bin` + `compression_corpus.txt` at the FRAME stage and
    `record_admit_*.bin` + `record_admit_corpus.txt` at the RECORD stage, both written by Go
    and derived by the peer, and all four suites are gated in
    `.forgejo/workflows/proto-abi.yml`.
    ASN OBSERVATION SEMANTICS (1.5-e): the requirement "An MTR hop's ASN is diagnostic
    enrichment, not an allocation claim"; the evidence is the 14-vector shared corpus
    `proto/edge/v1/testdata/asn_*.bin` + `asn_corpus.txt`, exercised by
    `go/pkg/edge/edgerecord/asn_corpus_test.go` and
    `elixir/serviceradar_core/test/serviceradar/edge/asn_corpus_test.exs`, both gated in
    `.forgejo/workflows/proto-abi.yml`. No ASN-SPECIFIC allocation-status filter exists in
    either runtime, by decision -- the generic validators still run over these records, and the
    corpus asserts they admit every value.
    TIMESTAMP CANONICALIZATION (1.5-c): the requirement "Nanosecond time is canonicalized to
    microseconds only at the projection boundary"; `projection.CanonicalMicros` and
    `ServiceRadar.Edge.ProjectionTime.canonical_micros/1`; the hand-written table
    `proto/edge/v1/testdata/canonical_micros_corpus.txt` plus the four
    `canonical_hash_*.bin` records, exercised by
    `go/pkg/edge/edgerecord/canonical_micros_corpus_test.go` and
    `elixir/serviceradar_core/test/serviceradar/edge/canonical_micros_corpus_test.exs`, both
    gated in `.forgejo/workflows/proto-abi.yml`.

  SUBTASKS (parent stays unchecked until all close)
  - [x] 1.5-a UNKNOWN-FIELD / UNKNOWN-ENUM ADMISSION -- the VERDICT, not the mechanism.
        SIGNED OFF at 7207c7b1.
        THE RULE is the requirement "An unknown field is refused and an unknown enum is retained,
        and both runtimes reach the same verdict". It freezes ACCEPT vs REFUSE on the same bytes,
        the RETAINED ENUM NUMBER, and the graph boundary "every message depth" means. It freezes
        NEITHER the layer a runtime refuses at NOR the classification a refusal carries -- the
        latter is 1.5-l's, and the two do not overlap: 1.5-a says WHETHER the bytes are refused,
        1.5-l says WHAT a refusal is called and therefore whether it is retryable.
        NO RUNTIME CHANGE: the slice adds Go-authored shared bytes and the requirement above,
        and no validator, inventory or behaviour. See design.md for the audit that established it.
        CLAUSES OWNED HERE, each with its Go / Elixir enforcement and its shared vector:
          (a) UNKNOWN FIELD at any depth -- `hasUnknownFields` (`canonical.go:66`, via
              `DecodeRecord`) / the `WireValidate` walk (`wire_validate.ex:197`). VECTORS
              `wire_compat_unknown_field_{top,nested,depth2}.bin`. The depth-2 vector is what
              separates "the walker recurses" from "the walker looks one level into a known
              carrier".
          (b) GROUPS (wire type 3/4) -- Go retains the group as an unknown field; protobuf-elixir
              silently DISCARDS it, so nothing downstream of the decoder can see it. VECTOR
              `wire_compat_unknown_group_nested.bin`, which carries the SAME undeclared field
              number at the SAME offset as (a)'s nested vector, so the pair isolates WIRE TYPE.
          (c) FIELD-NUMBER BOUND, inclusive at 2^29-1. VECTORS
              `wire_compat_field_number_{max,over}.bin` -- the PAIR is what makes the bound
              inclusive rather than off by one.
          (d) 10-BYTE UINT64-OVERFLOW VARINT -- `take_varint/3` (`wire_validate.ex:124`) against
              a decoder that MASKS 2^64+1 to 1, which the peer asserts as the NUMBER 1 rather
              than merely as "a struct came back". VECTOR `wire_compat_varint_overflow.bin`.
          (e) WIRE-TYPE MISMATCH on a singular scalar -- Go's parser PRESERVES it and
              `DecodeRecord` refuses it as an unknown field; Elixir's preflight passes it by
              design (the packed rules are `repeated?`-gated) and the decoder refuses it. VECTOR
              `wire_compat_wire_type_mismatch.bin`.
          (f) PACKED payload rules and the NESTING BOUND (`protowire.DefaultRecursionLimit`,
              10,000 counting the root). Enforcement only, no shared vector: the packed-element
              rules close a protobuf-elixir leniency with no Go counterpart, and the edge roots
              are acyclic so no committed edge message can nest 10,000 deep. UNSHAREABLE, not
              missing.
          (g) UNKNOWN ENUM retained then refused SEMANTICALLY -- the closed `known*` switches
              (`validate.go:1489-1560`) / `scripts/patch_edge_enum_negatives.exs` plus
              `@enum_field_policy` (`semantic_validate.ex:180-223`). VECTORS
              `wire_compat_enum_positive.bin` (99, the forward-compatibility case a newer
              producer sends), `wire_compat_enum_negative.bin` (-1, the case that RAISED before
              the transform), `wire_compat_enum_unspecified.bin` (0, a DECLARED member the closed
              sets still exclude, so the retained-value gate cannot be what refuses it).
          (h) LAST-ONE-WINS effective value -- `lane_open_negative_then_valid.bin`, Go-authored
              in `proto/edge/v1/golden_test.go` and asserted in both runtimes.
          (i) ENUM POLICY INVENTORY parity -- `enum_policy_manifest.txt`, written by Go
              (`validate_test.go:999`) and read by Elixir (`semantic_validate_test.exs:1102`).
        THE MANIFEST IS THE CROSS-RUNTIME ASSERTION. Five columns; the normative one is the
        accept/refuse CLASS, which BOTH suites derive from BOTH columns -- so moving one runtime
        and its own column leaves the other suite failing. The reason tokens are DIAGNOSTIC and
        labelled as such in both suites, because the spec permits refusing at either layer. The
        retained enum VALUE and FORM are normative: a decoder that clamped an unknown enum would
        still be refused by the closed sets, so no class assertion can see that drift.
        MANIFEST-VERSUS-DISK runs in both directions in both runtimes, so an orphaned
        `wire_compat_*.bin` cannot be staged by Bazel and read by nobody.
        GATED in `go_test.srcs`, the Elixir unit shard, and `proto-abi.yml`.
  - [ ] 1.5-b unsupported-version compatibility rules
  - [x] 1.5-c TIMESTAMP UNITS -- projection-boundary canonicalization. SPEC, RUNTIME AND
        VECTORS LANDED, and SIGNED OFF at 47e3c2a7 after an uncached, retry-disabled Bazel run
        (`--nocache_test_results --flaky_test_attempts=1`) passed all three gating targets on
        the FIRST attempt -- an honest result rather than a green status hiding a retry.
        THE RULE is the requirement "Nanosecond time is canonicalized to microseconds only at
        the projection boundary" -- containing-bucket mathematics, the order against the two
        contract hashes, and the consumer list. Not restated here.
        THE HELPER IS FIXED. `projection.CanonicalMicros` adjusts the quotient after a direct
        signed division, forming no unrepresentable intermediate; its package doc no longer
        claims it runs "BEFORE any identity or ordering comparison".
        `ServiceRadar.Edge.ProjectionTime.canonical_micros/1` is the peer.
        CONSUMERS: `mtr_traces.time` and `mtr_hops.time` only, both `TIMESTAMPTZ`. NOT the
        partition identity -- `trace_identity_time` is, and is UUIDv7 MILLISECOND derived, so it
        is permanently excluded. AGE's `(observed_at, trace_id)` ordering stays in raw
        nanoseconds, normative in `age-graph/spec.md`.
        VECTORS: 14 hand-written rows in `canonical_micros_corpus.txt`, verified against the
        invariant with independent arbitrary-precision arithmetic -- NOT generated from either
        helper, since a table produced by calling the implementation cannot detect the
        implementation being wrong. EXACT membership and uniqueness are gated in both suites; a
        count-only gate would accept a boundary row replaced by a duplicate.
        HASH CONTROLS on four committed records both runtimes read byte-for-byte:
        `canonical_hash_observed_{128,999}.bin` carry REAL MTR bodies differing only in
        `MtrTraceEventV1.observed_at_unix_nano`, and `canonical_hash_capability_{128,999}.bin`
        move `production_capability.not_before_unix_nano` with payload, hash, expiry and
        signature fixed (DIGEST-ONLY, not admission -- the signature no longer covers the moved
        timestamp). 128/999 because both are two-byte varints, and the records are UNCOMPRESSED
        so the width argument applies to the bytes actually hashed.
        MUTATION-VERIFIED: restoring the old negation-based Go implementation is killed at
        MinInt64; truncating instead of flooring is killed at -1500 in BOTH runtimes.
        GATED in `go_test.srcs` (with the `//go/pkg/edge/projection` dep the import needs), the
        Elixir unit shard, and `proto-abi.yml` -- whose path filters and Go sweep now include
        `go/pkg/edge/projection/**`, without which a helper-only regression skipped the very
        workflow gating its vectors.
        NOT OWNED HERE: projector integration and schema, both `unify-sweep-results-proto` task
        5.4's. Nothing calls the conversion from a projector yet, so SQL agreement is not
        established.
  - [ ] 1.5-d OPTIONAL ZERO-VALUED MEASUREMENTS -- absent versus present-zero
  - [x] 1.5-e ASN OBSERVATION SEMANTICS (renamed from "ASN RANGE admission").
        LANDED: the requirement "An MTR hop's ASN is diagnostic enrichment, not an allocation
        claim". Implementations SHALL NOT apply allocation-status filtering; zero means
        unavailable; every other uint32 value is carried through unchanged.
        REMAINING -- the shared vector slice, pinned:
          (a) BYTE-LEVEL zero proof: one fixture with field 6 ABSENT from the payload, and a
              separately identified one with field 6 encoded EXACTLY ONCE as varint zero.
              Asserted on the bytes, not only on the decoded value.
          (b) VALUES: 1, 23456, 64512, 65534, 65535, 2147483647 and 2147483648 (bracketing
              signed-32-bit storage), 4200000000, 4294967294, 4294967295.
          (c) `asn_org` INDEPENDENCE: an ordinarily valid string alongside each of a zero and a
              nonzero `asn`, neither affecting the other.
          (d) THE SAME COMMITTED BYTES consumed by both runtimes, and BOTH must compare the
              decoded values, not merely run their validator. `ValidateMtrTraceBatch`
              deliberately ignores ASN, so a decode substitution or truncation would pass it
              unnoticed. Go: decode -> assert the exact ASN/asn_org values -> ValidateMtrTraceBatch.
              Elixir: decode -> assert the same values -> `SemanticValidate.validate_message/1`.
          (e) BAZEL AND WORKFLOW REGISTRATION for both suites. A vector unreachable from CI is
              the recurring defect in this change; it has bitten five times.
        SCOPE OF THE PARITY CLAIM: Elixir has no raw MTR admission entrypoint and no full MTR
        body validator. Its vectors can prove generated decode, the recursive semantic
        traversal, and numeric preservation -- and nothing beyond that. Full record-ingress
        admission belongs to `unify-sweep-results-proto` tasks 5.1/5.4 and is NOT claimed here.
        OWNER NOTE: projection (SQL representation and column width) is owned by
        `unify-sweep-results-proto`'s "TimescaleDB Storage" requirement and task 5.4.
  - [x] 1.5-f COMPRESSION ADMISSION: streaming expansion bound, RECURSIVE COMPRESSION
        (exactly one compression LAYER), and trailing-frame rejection. "Recursion" unqualified
        collides with protobuf MESSAGE recursion, whose 10_000-message ceiling is 1.5-a's. CLOSED --
        delivered on `usp-32-compression-admission` in three slices; #4734 is closed unmerged
        and is prior art, not delivery.
        AN AUDIT/FREEZE/PARITY SLICE, NOT GREENFIELD -- `compression.go` already implements
        the Go side, so the requirement DESCRIBES it rather than inventing rules the code
        would be dragged toward. The audit findings are in `design.md`, not restated here.
        - [x] slice 1 NORMATIVE FREEZE -- the requirement "Compression admission is frozen
              by value, stage, and frame shape" is the normative source for
              `MaxUncompressedBytes = 33_554_432`, `MaxCompressionRatio = 100` and
              `MaxZstdWindowBytes = 33_554_432`, and
              freezes the enforcement STAGE, the denominator binding, the declared-versus-
              actual rule, the single-frame/trailing-data rule, the RECURSIVE-COMPRESSION rule and
              overflow-safe ratio arithmetic. Until it landed all three lived only in
              runtime source, so every consumer asserting any of the THREE -- 1.2-c's
              decoder among them -- pinned a number with nothing behind it. It freezes THREE independent
              limits, not two: decoded output <= 32 MiB, expansion ratio <= 100:1, and
              advertised Zstd WINDOW <= 32 MiB. The window ceiling was enforced by Go all
              along -- `WithDecoderMaxMemory` is the maximum WINDOW for streaming decoders --
              but was never normative, so a peer could have accepted a 64 MiB-window frame
              emitting 1 MiB and diverged on a record both runtimes call otherwise valid.
              v1 giving the window and output ceilings the same VALUE is a coincidence, not
              a rule; they bound different things
        - [x] slice 2 RUNTIME PARITY -- reconcile Go against the frozen text, implement the
              ELIXIR PEER, and add shared boundary/rejection vectors.
              THE PEER AND THE SHARED CORPUS HAVE LANDED. No new dependency: OTP 28 ships
              `:zstd` in stdlib and the repo already pins 28.x, so no Hex package, no Rust
              NIF, no Cargo/vendor.sh/crate-universe churn and no new native crash boundary.
              A project-owned FRAME WALK is still required -- `:zstd.decompress/1` accepts
              CONCATENATED frames -- and is a port of Go's `zstdFrameLen`.
              TWENTY-ONE shared vectors under `proto/edge/v1/testdata/zstd_*.bin` with
              `compression_corpus.txt` carrying the expectation, so Elixir DERIVES its
              verdict rather than restating it. All 21 agree. That agreement is the whole
              point: the two runtimes do NOT share a shape -- Go delegates the window and
              dictionary rules to its DECODER while the peer enforces them in a preflight
              over the parsed header -- so hand-built bytes are the only thing that shows
              two different routes reaching one answer.
              REASON PARITY IS DELIBERATELY COARSE: Go reports both an oversized window and a
              nonzero dictionary id as `ErrZstdInvalid`, so the peer reports `:invalid` for
              the same inputs even though its preflight could name them precisely. Making
              them distinct changes GO's taxonomy and is not a reconcile slice's job.
              THE CORPUS IS FRAME AND OUTPUT-SIZE ONLY, and is scoped as such in both
              runtimes rather than described as proving compression admission. It exercises
              `ValidateZstdPayload`; RECORD-LEVEL admission additionally binds `encoded_size`
              to the payload length and applies the 100:1 ratio BEFORE that runs. Several
              vectors are therefore unreachable as whole records -- `zstd_valid_5k.bin`
              declares 5000 bytes from a 15-byte frame (333:1) -- which is the stage they
              belong to, not a defect.
              GO IS RECONCILED. The three ceilings are three constants: `MaxZstdWindowBytes`
              is its own, and the decoder sites use it, so the window ceiling and the output
              ceiling can be changed independently. Mutation-proven independent -- changing
              the OUTPUT ceiling leaves the window vectors untouched, and changing the WINDOW
              ceiling flips `zstd_window_above_ceiling.bin` to `accept`. `DecompressZstdPayload`
              applies the FRAME stage only -- no encoded_size binding, no ratio -- which its
              doc says. The audit narrative is in `design.md`, not here.
              Everything else reconciled clean: the ratio runs on DECLARED sizes before
              decompression; inside `validatePayloadBinding`, `encoded_size` is bound to the
              payload length BEFORE the ratio is evaluated, which is the ordering the freeze
              requires; declared-versus-actual holds in both directions; the extent check
              refuses trailing data; and the product is widened before multiplying.
              The EXPORTED frame APIs now bound their ENCODED INPUT too. They are described
              as bounded, and a direct caller could otherwise hand the frame walker an
              arbitrarily large buffer -- the composed path refuses it earlier, but the
              exported contract has to be true on its own. Elixir's frame walk is PRIVATE for
              the same reason: a second exported raw-bytes entry point beside a bounded one
              is not a bound.
              CEILING VECTORS PIN THE LITERAL, NOT THE CONSTANT, in BOTH runtimes. A vector
              built from the production constant self-adjusts when the constant moves, so one
              runtime can start admitting bytes the other refuses with every test still
              green. The frozen number is stated by the test and the constant asserted
              against it.
              THE DECODER RULES ARE SETTLED FIRST, AND A LIBRARY IS CHOSEN AGAINST THEM, not
              the other way round. An Elixir zstd binding is admissible only if it supports,
              or permits a project-owned preflight to enforce, ALL of: a bounded maximum
              WINDOW size; DICTIONARY REFUSAL; exact FRAME EXTENT (the frame ends at exactly
              the payload length); rejection of TRAILING, CONCATENATED, EMPTY-CONCATENATED
              and SKIPPABLE frames; and BOUNDED decoding that never reserves the full output.
              Availability is not the test -- a binding that decodes correctly but cannot
              express these cannot implement the freeze, and picking it first would leave
              the rules to be bent toward what it happens to offer.
              WINDOW VECTORS ARE ISOLATED: the largest representable window at or below
              32 MiB ACCEPTED, and the smallest representable window above it REJECTED, both
              with output size and ratio otherwise valid, so neither vector can be satisfied
              by the output check or the ratio check
        - [x] slice 3 COMPOSED REACHABILITY -- a valid body larger than 512 KiB surviving
              physical admission under 100:1, the record-stage vectors slice 2's corpus
              cannot reach, the composed record -> extraction -> body path, CI/Bazel
              registration, ledger closure. CLOSED.
              TEN committed vectors under `proto/edge/v1/testdata/record_admit_*.bin` with
              `record_admit_corpus.txt` carrying the expectation, so the peer DERIVES its
              verdict. The admission stage is `validatePayloadBinding`; its Elixir peer is
              `Compression.admit_record/1`. Covered: the `encoded_size` BINDING, the payload
              digest, the codec gate, EXACTLY 100:1 admitted with the first value over it
              refused, 32 MiB admitted with N+1 refused on a slack ratio, the
              RECURSIVE-COMPRESSION negative (a ZSTD frame wrapping a ZSTD frame, distinct
              from protobuf MESSAGE recursion, whose ceiling is 1.5-a's), and the
              above-ceiling body.
              REACHABILITY RESTS ON NONCANONICAL ADMISSIBILITY, which is a property this ABI
              states deliberately: `unmarshalPayload` imposes no decode/re-encode equality,
              because payload identity is `payload_sha256` over the EXACT received bytes. A
              body may therefore carry a DUPLICATE encoding of a singular field, with
              last-one-wins yielding the canonical value appended after it. The padding rides
              in a duplicate of `availability_policy_id`, so the extracted body exceeds
              512 KiB while MEANING the ordinary bounded batch, and the carrying record stays
              far below the physical ceiling. The per-family limits bound MEANING; the
              physical ceiling bounds RECEIVED BYTES, and the first does not bound the second.
              The same construction makes the 32 MiB vector a valid contract body.
              `Compression.admit_record/1` is what BINDS `encoded_size` before the ratio
              consumes it as a denominator; why that mattered is in `design.md`.
              THE 32 MiB PAIR IS COMMITTED, not constructed per runtime, so both admit the
              SAME BYTES; admitting exactly 33_554_432 bytes of output within 100:1 requires
              at least 335_545 encoded bytes, so there is no cheaper vector. The
              over-ceiling half derives from the same committed bytes.
              THE RECURSIVE NEGATIVE CARRIES A CONTROL: the doubly wrapped message VALIDATES
              when unwrapped twice, so a recursive runtime would WRONGLY ACCEPT it. Admission
              accepts the record -- one-layer is not an admission-stage property; the refusal
              is the contract stage, `ErrRecordDecode` in Go and `:poison` in the peer.
              NO SPEC CHANGE. Slice 3 proves existing SHALLs; it does not add or move a rule.
              NOT COVERED, deliberately: a `payload_too_large` whole-record vector, which
              would need a >512 KiB fixture to say what slice 2's constructed ceiling vectors
              already say at the frame API. The audit narrative is in `design.md`
        1.2-c CONSUMES that bound and does NOT re-freeze it. The dependency is ONE-WAY and
        applies at CLOSURE, not at start: 1.2-c's decoder can be built and tested against
        32 MiB now, but 1.2-c SHALL NOT be checked until 1.5-f has frozen the value it is
        asserting. Otherwise the number is pinned by a test with no normative source.
        DISCHARGED: 1.5-f is closed, so 1.2-c is checked.
        1.5-f ALSO OWNS COMPOSED-RECORD REACHABILITY. 1.2-c's vectors are inputs to the
        extracted-decoder stage and assert nothing about whether a record carrying such a
        body survives compression admission -- highly repetitive padding compresses far
        beyond 100:1 and is refused before extraction. Proving that SOME body above the
        512 KiB physical bound is transport-reachable requires a composed-record vector
        under the ratio rule, which is 1.5-f's; no other task may claim it.
  - [ ] 1.5-g the payload-family <-> output-contract admission decision (assigned by 1.3):
        freeze the relation with vectors in both runtimes, or record an explicit decision
        that v1 needs none
  - [ ] 1.5-h string / count / byte / relational-row BOUNDS admission
  - [ ] 1.5-i SEMANTIC-ENVELOPE GRAMMAR coverage, and its DIGEST SEPARATION from gateway
        receipt, physical placement, spool coordinates and renewable delivery proof
  - [ ] 1.5-j BROKER PUBLICATION IDENTITY defined separately from the semantic envelope
  - [ ] 1.5-k PROJECTED ROW COST covering every synchronous ledger / domain / outbox / work
        / current-state mutation
  - [ ] 1.5-l REFUSAL CLASSIFICATION -- `:poison` vs `:systemic` vs `:not_ready`. This task's
        body requires it and no other subtask carries it.
        DISTINCT FROM 1.5-a, which freezes WHETHER bytes are refused and explicitly leaves the
        classification unfrozen. This one owns WHAT A REFUSAL IS CALLED, which decides
        RETRYABILITY: `:poison` permanently resolves a delivery, `:systemic` pauses, `:not_ready`
        leaves it unresolved. A malformed input classified `:systemic` at a known delivery slot is
        RETRYABLE FOREVER while Go refuses it permanently -- the same bytes, opposite outcomes,
        and invisible to an accept/refuse corpus because neither `:systemic` nor `:not_ready` is
        a refusal at all.
        NOT DELEGATED DOWNSTREAM: `unify-sweep-results-proto`'s task 1.16 names task 1.5 as its
        PREREQUISITE for exactly this alignment, so moving it there would be circular.
        ALREADY SATISFIED IN PART: `WireValidate` refuses truncation and short reads as `:poison`
        BEFORE the generated decoder runs; `classify/1` maps `Protobuf.DecodeError` to `:poison`
        and the ambiguous `MatchError` to `:systemic` deliberately; metadata and codegen failures
        are `:systemic`/`:not_ready` and never `:poison`.
        REMAINING: (1) a NORMATIVE requirement -- the rule lives only in module documentation and
        this ledger today, and a ledger is deleted at archive; (2) the body's own quantified claim,
        that roughly 3-4% of malformed inputs reached an ambiguous `MatchError`, needs FUZZ
        EVIDENCE that the preflight now catches those first rather than an argument that it should.

  EXHAUSTIVENESS: 1.5-a..l is checked against this task's own body. Every obligation the
  body names has a subtask; nothing is carried as an unlisted assumption. If the body gains
  an obligation, it gains a subtask in the same edit.

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
  CURRENT STATE: equivalence IS proven -- Elixir reads the SAME
  `proto/edge/v1/testdata` corpus as Go, and both regeneration drift guards run
  in `proto-abi.yml`. The gap is the fail-closed half: unsupported-version fixture
  coverage is incomplete across the grammars. Present today: transport provenance's `unknown-version` row in
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
  `ManifestPageDigest`, `PlanHeaderDigest`, `PlanPageDigest` and BOTH
  compiled-assignment digests belong ONLY to Class A: they are the digests OVER those
  messages, and the version they commit is the `digest_version` field the message
  itself carries, so the Class-A vector already exercises them. An object SHALL appear in
  exactly one class; listing one in both double-counts it.
  `CompiledSweepAssignmentV1.digest_version` (`CompiledAssignmentDigestVersion = 1`)
  is a Class-A member. ONE version field governs BOTH Appendix A grammars 9 and 10 -- the
  body digest and the artifact address share it -- so it is ONE Class-A member, not two.
  `Nats-Msg-Id` and `Sr-Edge-Delivery-Id` are Class B, NOT Class A: their received values
  are digests and their versions are compile-time constants, exactly like the semantic
  envelope. EVERY Appendix A object SHALL appear in exactly ONE class.

  STATUS
  - LANDED: Go and Elixir generation is single-sourced through `make generate-proto`, with
    `verify-proto-edge-go` / `verify-proto-edge-elixir` as manifest+byte drift guards.
  - REMAINING: see subtasks 1.6-a..b below; not restated here.
  - DEPENDS ON: nothing open.
  - EVIDENCE: `Makefile` verify-proto-edge-* targets, `hash_grammar.ex`.

  SUBTASKS (parent stays unchecked until all close)
  - [ ] 1.6-a unsupported-version fail-closed vectors for every CLASS-A OBJECT, per the
        object-level Class-A/Class-B partition this task owns. The partition is per OBJECT,
        not per grammar: one grammar may contain several objects, and one version field may
        govern two grammars. `CompiledSweepAssignmentV1.digest_version`
        is one of those members, covering BOTH compiled-assignment grammars, and is NOT a
        separate subtask -- naming it twice would let 1.6-a be checked while it is missing
  - [ ] 1.6-b CLASS-B MISMATCH vectors for every Class-B object: an altered version in the
        PREIMAGE, the DIGEST, or the HEADER must be REJECTED. Class B means "no input
        version", which forbids an unsupported-INPUT-version vector -- it does NOT mean no
        vector at all, and a checkbox that only confirms absence would let every Class-B
        object ship with its version unproven

- [x] 1.6a **Freeze the loss-classification span shape BEFORE the 1.7 ABI freeze.**
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
  tags are named here explicitly: the same reasoning applies to both messages, so BOTH are
  reserved, not only the tombstone's.
  TWO SIGNED SCALARS NEED ONE AUTHORITATIVE MEANING IN THE SAME PASS:
  (i) `RecoveryResolvedV1.applied_through_sequence` stays in the signed scope
  transcript, but with the tombstone range gone and gaps legal it could mean the
  maximum span end, a contiguous processed prefix, or the allocated high-water --
  which differ for `[1,1]` plus `[100,100]`, and the value GATES durable local
  journal release. FREEZE it as the consumer's DURABLY APPLIED CONTIGUOUS PREFIX
  over the ALLOCATED sequence space: the highest S such that EVERY allocated
  sequence at or below S is either durably applied by the consumer transaction, or
  ABSENT FROM a VALIDATED COMPLETE span union (the union is the LOST set, so ABSENCE from a
  COMPLETE union is what establishes not-lost; presence in the union does NOT). The gapped
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
  LANDED RULES (this task is CHECKED; these are the rules it froze, not a plan):
  - the recovery digest version, closed-set unknown-enum handling, and the Appendix A
    transcripts for BOTH the manifest page and the tombstone scope;
  - byte ceilings are measured against EXACT RECEIVED bytes. Hashing or re-marshalling a
    decoded message cannot bound what was received: duplicate fields and non-minimal
    varints survive the round trip and evade a physical ceiling.
  EVIDENCE: `go/pkg/edge/edgerecord/recovery.go` (field-by-field Appendix A framing, no
  `proto.Marshal` at any depth); `elixir/serviceradar_core/lib/serviceradar/edge/`
  `recovery_validate.ex` and `hash_grammar.ex`; `scripts/patch_edge_enum_negatives.exs`
  with `enum_policy_manifest.txt`; and the six recovery fixtures under
  `proto/edge/v1/testdata/`.
  The pre-implementation audit that drove this task -- what each runtime lacked before it
  landed -- is in `design.md`, not here.
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
  RULE: "passive" means ONLY "asserts no produced target range". It SHALL NOT be equated
  with an absent source authorization anywhere in the protos or the code -- the two are
  independent axes, and conflating them gives the word two incompatible meanings in one
  file. Note that generated comments follow the proto edit while hand-written ones do not,
  so both need checking when this wording changes. `run_shard`
  and `authority_epoch` equal `execution_shard` / `assignment_epoch` ONLY where the
  originating contract carries them -- `SweepObservationBatchV1` and
  `MtrSweepContextV1` do; the scheduled-check, ad-hoc, and command MTR variants
  carry neither. `run_id` is INDEPENDENT and is NOT REQUIRED to equal
  `execution_id`. A span does NOT embed `execution_plan_id`.
  SCOPE OF THE EXACT-RECEIVED-BYTES CEILING: this task closed it for the RECOVERY
  MANIFEST PAGE. The PLAN page is closed too, but by task 1.3 rather than here --
  `ValidatePlanFromRaw` measures `MaxPlanPageBytes` against RECEIVED bytes
  (`plan.go:572`). What remains coarse is the DECODED helper at `plan.go:265`, which
  measures a deterministic re-marshal; that is a convenience path for callers who
  already hold a decoded page, and it is NOT the physical boundary. This task does
  not claim to have closed the bypass for all paged contracts.
  ATOMICITY RULE: the proto shape, BOTH runtimes' validators, the exact byte checks
  and the fixtures land TOGETHER. Splitting them lets a frozen shape ship without the
  validators that enforce it.
  SPAN RULES: an `UNATTRIBUTABLE` span validates WITHOUT a covering affected scope;
  `ATTRIBUTED_PASSIVE` validates with a delivery interval and no produced range; and
  the frozen span rules hold (strict ascending order,
  non-overlapping, non-duplicate, primitively valid intervals, at least one span
  per page, and ordering total ACROSS the page chain). There is NO "exact-partition
  rule": gaps are legal and mean "not lost", so the spans do not partition a
  declared interval. An UNATTRIBUTABLE manifest SHALL be reportable rather than rejected
  outright: refusing it would make recovery of a corrupt segment unreportable, which is why
  this gates 2.21-2.28.

- [ ] 1.7 Freeze the agent-gateway frame and lane handshake as an internal,
  producer-neutral transport ABI. PREREQUISITE RULE -- COMPLETE, not a hand-listed
  subset: this task SHALL NOT be checked while ANY OTHER TASK OR SUBTASK IN THIS CHANGE is
  open. It is a RULE and not a list on purpose, and this entry does not enumerate one:
  any enumeration would need editing every time a task is added or split, and a stale one
  silently narrows the gate it exists to widen.
  ARCHIVAL GATE: 1.7 SHALL NOT be checked until this change contains a NORMATIVE
  delta defining the authoritative assignment-record schema and the frozen
  `SweepObservationBatchV1` correlation matrix (task 1.3). A task that requires a
  contract is not a substitute for the contract; if that delta is not authored,
  narrow 1.3 and this gate rather than freezing over a missing schema.
  Both deltas are AUTHORED -- the assignment-record schema and the correlation matrix each
  have normative requirements in `specs/edge-producer-data-plane/spec.md` -- so THIS GATE's
  condition is met. That does not license checking 1.7, which carries its own prerequisites;
  those are the STATUS block and subtasks below, and 1.3's live state is its own
  1.3-a..1.3-f checklist.
  NOT A PREREQUISITE: the durable assignment mapping's EXISTENCE and state, which
  is runtime task 2.20 downstream. This gate SHALL NOT wait on it.
  DISPLACED: the PRODUCER-FACING sink/run API freeze is NOT part of this task and
  SHALL NOT be performed here -- it depends on Wasm and native-relay fixtures this
  change does not own. It is downstream task 1.16a, which owns that freeze together
  with its receipts, credits, and fixtures. It SHALL be declared downstream only -- not
  also required imperatively inside 1.7, which would give it two owners.
  BOUND GATE -- OWNED HERE, not downstream: 1.7 SHALL NOT be checked until
  cross-language N/N+1 vectors exist for ALL FOUR frozen raw bounds
  (`MaxRecordBytes`, `MaxDeliveryEnvelopeBytes`, `MaxFrameBytes`,
  `MaxClientMessageBytes`) AND for the relational envelope budget -- each accepted
  at N and rejected at N+1, on RAW received bytes, before unmarshal.
  THE CANONICAL BOUNDS INVENTORY IS `design.md` -- its raw-bounds table and its
  work-ceilings table. This gate states the OBLIGATION and does not restate the values;
  a second inventory would be one more thing to keep in sync. What matters here is that
  the two KINDS are not interchangeable: an N/N+1 vector on RECEIVED BYTES cannot
  exercise a work ceiling, and the extracted-body ceilings are owned by 1.5-f rather
  than by this gate. This change
  claims ownership of the cross-language freeze gates, so it cannot rely on
  downstream task 1.16 to execute its own bound tests; otherwise the ABI can be
  declared frozen without its bounds ever being exercised.
  FREEZE CONDITION: freeze only after Go/Elixir golden fixtures cover
  `EdgeOutputContractRef`, authenticated `EdgeProducerContext`, production,
  optional source, and delivery authority, registry epochs, and finite platform
  route profiles.

  STATUS
  - LANDED: nothing; this is a GATE, not a build. Its condition that 1.3's normative deltas
    exist is now met.
  - REMAINING: see subtasks 1.7-a..d below; not restated here.
  - DEPENDS ON: every other open task in this change. It cannot close first by construction.
  - EVIDENCE: the per-task STATUS blocks above are what this gate reads.

  SUBTASKS (parent stays unchecked until all close)
  - [ ] 1.7-a cross-language N/N+1 vectors for all four raw bounds
  - [ ] 1.7-b the relational envelope budget vector
  - [ ] 1.7-c FREEZE-CONDITION FIXTURE COVERAGE: Go/Elixir golden fixtures covering
        `EdgeOutputContractRef`, authenticated `EdgeProducerContext`, production authority,
        OPTIONAL source authority, delivery authority, registry epochs, and the finite
        platform route profiles. This is its OWN subtask because "the freeze gate itself"
        does not mechanically require it -- a generic closing item can be checked while this
        coverage is absent, which is exactly how a gate passes over a hole
  - [ ] 1.7-d the freeze gate itself, once every other open task and subtask closes

- [x] 1.13 Restack prerequisite -- IMPLEMENTED as the stacked CANDIDATE slices.
  SCOPE: item (7) is MOVED OUT to tasks 1.4/1.15 and is NOT delivered here, so no
  statement in this task asserts the generated `MtrCompletionDisposition` enum
  exists or that the freeze prerequisite it represents is met: that enum is task 1.4's,
  never 1.13's to claim. Slices:
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
    (The 7/8/9 list is the statement AS COMPLETED by this task and is left standing.
    The oneof also carries `collection` = 11 and `assignment_execution` = 12, added by task
    1.3; the unification rule above applies to them unchanged. APPENDIX A IS THE INVENTORY;
    this entry is not.)
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
  FREEZE gate. This says nothing about the other freeze prerequisites. Task 1.6a is MERGED
  (#4764) and the generated `MtrCompletionDisposition` enum has LANDED (task 1.4's
  disposition sub-target); both are IMPLEMENTED CANDIDATES, not accepted ABI -- task 1.7 is
  still the accept gate. THIS CHECKED TASK DOES NOT INVENTORY OPEN WORK: the canonical open
  state is each open parent's own STATUS block and subtask checklist. A snapshot here would
  go stale silently. The zero-MTR
  decision is CLOSED -- a COMPLETED event always carries the proof. The freeze itself is
  task 1.7.

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

- [x] 1.17 ONE BOUNDED BODY-PIPELINE BENCHMARK, as NON-GATING evidence for this change.
  CLOSED. It stays unchecked at its peril: 1.7 carries every OPEN local task, so an open
  1.17 would make a benchmark an ABI-freeze prerequisite -- the exact opposite of
  "non-gating". Re-running the harness after step 3 is optional PR evidence, NOT an open
  task, and adding a stage or fixture later does not reopen this.
  NUMBERED 1.17, NOT 1.16: downstream `unify-sweep-results-proto` owns 1.16 and 1.16a, and
  this file already references both. A second local 1.16 made every one of those references
  ambiguous.
  STATUS
  - SCOPE IS WIRE-ONLY, like the rest of this change. CI trending, an SLA, a capacity
    budget and the JetStream -> EventWriter -> CNPG soak are RUNTIME concerns and belong to
    the downstream change -- they are NOT ABI-freeze prerequisites, and making 1.7 carry
    them would contradict this change's stated split.
  - WHY IT EXISTS HERE: informal timings varied by an order of magnitude for the same input,
    so no number was citable. The harness makes the SHAPE of the cost reproducible; it does
    not establish capacity.
  - WHAT IT MEASURES is the BODY PIPELINE, not production ingress: protobuf decode, decoded
    body validation, the correlation RELATION, and those three composed. It performs NO
    extraction, NO record validation, NO trust resolution, NO signature verification and NO
    decompression. Any capacity claim needs the authenticated/compression path, which does
    not exist yet.
  - [x] 1.17-a FOUR STAGES over seven fixtures (1 / 100 / 1000 / 2000 hosts; 2000 mixed
        ICMP/TCP/MTR with nested ports and errors; invalidity on host 2000; 2001 for bounded
        rejection). Hosts and nested messages are DISTINCT -- reusing one term shares an
        allocation and understates memory. The 32 MiB and 32 MiB + 1 DECODER-CEILING cases
        stay in the correctness suites, which pin them exactly; generating 64 MiB per run
        buys nothing here
  - [x] 1.17-b FIXTURES ARE SHARED: both runtimes build the bytes from one documented
        algorithm and verify them against `proto/edge/v1/testdata/sweep_bench_manifest.txt`
  - [x] 1.17-c A TIMING-FREE VERIFIER runs in the REQUIRED workflow, in BOTH runtimes: exact
        manifest membership, digest equality, and every fixture checked against an EXPLICIT
        expected outcome. Without it the evidence fails open -- a valid fixture degrading
        into an early rejection reads as a speedup, which had already happened twice.
        APPLICABLE STAGES ONLY: correlation has a VALID-BODY precondition, so it is NOT
        benchmarked for body-invalid fixtures. Timing an early refusal there would be
        cheaper and unnoticed, and the verifier cannot pin an outcome for it without
        blessing behaviour outside that precondition. TIMING ITSELF IS NEVER A GATE
  - [x] 1.17-d METRICS, PER RUNTIME, narrowed to what each actually reports. ELIXIR: p50 and
        p95 wall time, REDUCTIONS, and DIAGNOSTIC HEAP GROWTH -- a `total_heap_size` delta,
        i.e. occasional capacity growth of the process heap, frequently zero after reuse,
        and NOT words allocated. GO: `ns/op`, `B/op` and `allocs/op` from `-benchmem`;
        reductions are BEAM-only and have no Go peer. Wall time moved 2-3x between runs on
        identical input while reductions held within 1%, which is why reductions are the
        signal worth reading. The 1000 -> 2000 scaling check is REPORT-ONLY and gates
        NOTHING; the nightly policy that could act on it belongs downstream
  - [x] 1.17-e REPOSITORY SHAPE: `go/pkg/edge/edgerecord/sweep_ingress_benchmark_test.go`
        (listed in `edgerecord_test.srcs`) and `elixir/serviceradar_core/bench/sweep_ingress.exs`,
        following the existing dependency-free `ServiceRadar.Bench.*` scripts
  - EVIDENCE, 2000 hosts (141 KB), BODY PIPELINE ONLY and NOT a capacity figure: work scales
    LINEARLY -- doubling the hosts doubles the work in every stage of both runtimes, 2.0x
    REDUCTIONS in Elixir and ~2.1x `ns/op` in Go, since reductions are BEAM-only and have no
    Go peer -- and
    DECODE DOMINATES while body validation is a small fraction of it. Absolute wall time is
    not yet stable across machines and is deliberately not quoted here; see the PR and
    `design.md` for the raw runs.

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
  ZERO-MTR (`expected == 0`) IS DECIDED: a MANDATORY canonical zero-leaf proof, frozen by
  the requirement "A zero-MTR completion is a mandatory canonical proof, not an absence". THERE IS ONE REPRESENTATION for every COMPLETED event,
  so missing evidence can never masquerade as empty work. An alternative permitting BOTH an
  absent and a present proof for one state is forbidden: it would rest the choice between
  them on the event's own producer-reported counters.
  NOT BLOCKING 1.4, 1.15 or the 1.7 freeze:
  `NewMtrCompletionAccumulator` now accepts `expected == 0`; the Elixir
  verifier accepts it; the Go lifecycle validator's unconditional demand for a
  32-byte digest, matching version, and a 32-byte PLAN ROOT on EVERY COMPLETED
  event is now CORRECT rather than contradictory, because the zero-MTR case has a
  proof to carry. `ValidatePlanHeader` additionally requires
  `mtr_ordinal_range_commitment` to be exactly 32 bytes (32 ZERO bytes when no MTR
  is admitted, never empty), and `VerifyCompletionAgainstPlanState` freezes the
  COMPARISON a consumer performs -- a PRIMITIVE only: every authoritative value is a
  caller argument, so it establishes nothing about where those values came from and
  has deliberately no production caller. Shared vectors landed:
  `lifecycle_zero_mtr.bin`, `zero_mtr_commitment.bin`, and the paired
  `plan_header_zero_mtr.bin`, recomputed byte-for-byte in Elixir.
  STILL OPEN. Split deliberately, because `unify-sweep-results-proto` depends on the
  FROZEN ABI: an ABI task that blocked on a runtime task would be a cycle, and the
  runtime work could never start.
  DOWNSTREAM, AND EXPLICITLY *NOT* A 1.7 GATE:
  (a) PRODUCER PATH -- nothing in this repository computes a completion proof.
  `execstate.Tracker` builds lifecycle events and sets only `expected/emitted`
  counters. Owned by `unify-sweep-results-proto` task 2.3b, per this task list's
  scope note. `go/pkg/edge/execstate/**` is now in the Proto ABI workflow path
  filters so a producer change cannot bypass the ABI drift gate -- that is CI
  coverage, not a task dependency.
  (b) CONSUMER VERIFICATION IS NOT IMPLEMENTED, and 1.7 does not wait for it.
  `VerifyCompletionAgainstPlanState` is a comparison PRIMITIVE: every authoritative
  value is a caller argument, so a caller that derives them from the event gets a
  VACUOUS check that always passes. There is deliberately NO production caller, and
  `ValidateLifecycleRecord` remains shape-only. Elixir has no peer verifier at all.
  Wiring a real carrier is task 2.3b's job, downstream of the freeze.
  LOCAL 1.7 PREREQUISITES (normative FIELD MEANINGS only -- what the ABI must SAY,
  never who implements it):
  (c) RESOLVED by 1.3's assignment record. `range_root_sha256` is RETIRED (tag 20,
  reserved by number and name) rather than defined -- the authoritative binding is the
  assignment's resolvable `target_range_id` + `target_range_sha256`, related to the
  committed plan by `ValidateAssignmentAgainstPlan`. And the required
  `SweepMtrExpectationV1` STATES the admitted ordinal count, so "32 ZERO bytes means
  no MTR admitted" is written down and checkable in both directions.
  The full per-value shared leaf-vector inventory remains task 1.15.
  UNSUPPORTED-VERSION coverage is the vector ASSIGNED BY EACH OBJECT'S PROOF CLASS
  in task 1.6 -- Class-B objects have NO version input and SHALL NOT be asked for
  an unsupported-input vector. Add matching field-framed grammar
  vectors proving Go/Elixir byte equality for the `EdgeOutputContractRef`
  output-contract grammar, ALL FIVE claim grammars -- `EdgeProductionClaimsV1` /
  `EdgeSourceClaimsV1` / `EdgeDeliveryClaimsV1` (including the field-framed
  `transition` oneof and its framed member) / `EdgeCollectionClaimsV1` /
  `EdgeAssignmentExecutionClaimsV1` (including BOTH branches of its optional
  `source_identity`) -- the plan grammars (`RangeDigest` / `PlanPageDigest` /
  `PlanRoot` / `PlanHeaderDigest`, `plan_grammar_version = 1`), the recovery
  grammars (`EdgeLossManifestPageV1` / `SpoolLossTombstoneV1` / `RecoveryResolvedV1`,
  `recovery_grammar_version = 1`), and BOTH compiled-assignment grammars (Appendix A
  9 and 10, `CompiledAssignmentDigestVersion = 1`).
  The two new claim grammars and both compiled-assignment grammars ALREADY have
  shared Go-authored vectors that Elixir consumes, including a source-present and a
  source-absent grant.
  CLAIM GRAMMARS TAKE NO UNSUPPORTED-VERSION VECTOR: a claim message has NO version
  input of its own -- the version it is framed under belongs to the CAPABILITY
  (`capability_version`), so the rejection vector is the capability's, once, not one
  per claim type.
  TWO DIFFERENT OBLIGATIONS RANGE OVER THE SAME OBJECTS, and only one of them is this task's.
  The grammar list above is 1.15's PARITY surface: which objects need a shared Go-authored
  vector that Elixir consumes byte-for-byte. It is NOT an unsupported-version list.
  UNSUPPORTED-VERSION COVERAGE IS TASK 1.6's INVENTORY. 1.6 owns the exhaustive Class-A /
  Class-B assignment of every Appendix A object; this task consumes that assignment and SHALL
  NOT restate it. A copy here would silently omit objects such as `ManifestRoot` and the
  manifest-page scope digest while asking for an unsupported-INPUT vector on objects that
  have no version input.

  STATUS
  - LANDED: the shared Go-authored fixture corpus under `proto/edge/v1/testdata/`, consumed
    byte-for-byte by the Elixir golden test.
  - REMAINING: see subtasks 1.15-a..b below; not restated here. The matrix's cross-language
    vectors are OWNED BY 1.3-f, not by this task; 1.15 ACKNOWLEDGES them as parity evidence.
  - DEPENDS ON: nothing open. 1.3-f OWNS the matrix vectors and is checked, so 1.15-b's
    dependency is DISCHARGED and 1.15-b is checked. The matrix SHAPE was already merged
    (#4779) and was never the blocker.
  - EVIDENCE: `proto/edge/v1/testdata/`, `edge_v1_golden_test.exs`.

  SUBTASKS (parent stays unchecked until all close)
  - [ ] 1.15-a shared per-value leaf vectors (blocks 1.4)
  - [x] 1.15-b ACKNOWLEDGE 1.3-f's matrix vectors as cross-language parity EVIDENCE for this
        task. 1.3-f authors them and owns any fixture change they cause; this subtask records
        that they satisfy 1.15's parity obligation for the sweep correlation surface. It is
        NOT a second pass over the fixtures: this subtask closes by CITING 1.3-f's vectors,
        and mutates nothing.


