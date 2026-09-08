# Design — edge record v1 wire ABI

This change owns FIVE things and nothing else:

1. the authority of the actual proto files;
2. the exact raw byte bounds;
3. the residual DOMAIN-SEMANTIC admission bounds -- the per-family string, count and
   relational limits that are part of the contract rather than of a deployment's policy;
4. Appendix A's byte-exact grammars, the identity semantics, and the
   version/proof-class inventory;
5. the cross-language freeze gates.

Item 3 was implicit until the 1.5-h ownership audit, and "the exact raw byte bounds" was
read as covering it. It does not: a host-count ceiling and a lane credit cap are neither raw
nor bytes, and several such bounds turned out to be owned by nothing. Section 2h is the
ownership index for all of them. The line item 3 does NOT cross is transport POLICY -- a
value a deployment may set, such as an acknowledgement's disposition budget or the local
clock-skew tolerance. An acknowledgement's disposition budget is the case where a value stays
unfrozen while the OBLIGATION TO HAVE ONE is normative: a receiver SHALL impose finite
raw-byte, decoded-count and canonical-byte limits. Task 1.7-f supplies that requirement
and the composed Go `DecodeAck` and Elixir `AckValidate.validate_bytes/3` boundaries.
The local clock-skew
tolerance is not even that: it is deliberately local policy, carries no interoperability
obligation, and this change states nothing about it.

Operational behaviour -- ordering, PubAck and DLQ routing, caching, source-ACK,
persistence, projection -- belongs to `unify-sweep-results-proto` and is NOT
restated here. Five earlier revisions tried to carve prose sections along that
line and failed each time, because the sections have more than one owner. This one
does not carve prose; it points.

## 1. Proto authority

The normative wire definitions ARE `proto/edge/v1/record.proto` and
`proto/edge/v1/sweep.proto`, as landed by tasks 1.1-1.4 through candidate slices
#4713-#4718, PLUS the `EdgeRecordCapabilitiesV1` submessage that task 1.1 imports
into `AgentHelloRequest` and `ControlStreamHello` in `proto/monitoring.proto` --
that file is in ABI scope for those fields ONLY. This document does NOT restate a single message or enum.

An earlier revision did restate them, marked the copy normative, and the copy was
already STALE in five places against the code it sat above:

| The copy said | The proto says |
| --- | --- |
| `EDGE_RECORD_COMPRESSION_NONE = 0`, `ZSTD = 1` | `UNSPECIFIED = 0`, `NONE = 1`, `ZSTD = 2` |
| `EdgeRecordAuthorizationKind` | `EdgeSourceAuthorizationKind` |
| `string` sweep/execution/range/source IDs | `bytes` |
| `string trace_id` | `bytes trace_id` |
| no `optional` on first/last-seen deltas | `optional` presence |

It also referenced `EdgeSignedCapabilityV1`, `EdgeSourceAuthorizationV1`, several
sweep enums and summary messages, and `MtrOutcome` without defining them. A prose
restatement of a wire contract is a second source of truth whether or not it is
labelled normative, and this one drifted before anything depended on it.

**Owed to the proto by this change:** the typed edge-record capability fields the
handshake needs are NOT in today's `monitoring.proto` Hello messages. Task 1.7
cannot freeze a capability negotiation whose fields do not exist, so adding them is
an explicit deliverable of task 1.1 and a prerequisite of the freeze -- not an
assertion prose can make.

## 2. Exact raw byte bounds (frozen)

Checked against RAW RECEIVED BYTES, before any protobuf unmarshal and before any
decompression:

| Bound | Value | Applies to |
| --- | --- | --- |
| `MaxRecordBytes` | 512 KiB | one raw `EdgeRecordV1` |
| `MaxDeliveryEnvelopeBytes` | 16 KiB | the delivery-frame envelope around the record |
| `MaxFrameBytes` | `MaxRecordBytes + MaxDeliveryEnvelopeBytes` = 528 KiB | one raw `EdgeDeliveryFrameV1` |
| `MaxClientMessageBytes` | `MaxFrameBytes + 8` | one raw `EdgeRecordClientMessage`: the oneof tag (1 byte) plus a length prefix (<= 5 bytes) |
| `MaxPlanPageBytes` | 128 KiB | one raw `ScheduledPlanPageV1` |
| `MaxPlanHeaderBytes` | 512 KiB | one raw `ScheduledPlanHeaderV1` |
| `MaxCompiledAssignmentBytes` | 64 KiB | one raw `CompiledSweepAssignmentV1` (fetched standalone by digest) |
| `MaxExecutionGrantBytes` | 16 KiB | one raw `EdgeSignedCapabilityV1` carrying an ASSIGNMENT_EXECUTION claim (travels standalone) |

THIS DOCUMENT IS NOT THE NORMATIVE SOURCE FOR ANY VALUE. The applied OpenSpec requirement
owns the exact number; this document is the consolidated OWNERSHIP INDEX -- which task owns
each bound, at which stage it is taken, and what evidence exists. Section 2h below is that
index, and it is the entry point. The tables here restate values for readability only, and a
disagreement between a table here and the spec resolves in the SPEC's favour.

Calling this document canonical was a defect, not a shortcut. It was demonstrably incomplete
-- it carried no string-bytes table at all, and its count table carried three rows while
seven further count ceilings existed in code -- so "canonical" meant a reader who found
nothing here concluded no bound existed. Tasks SHALL reference bound NAMES and SHALL NOT copy numbers, so there is exactly
one place a value can be changed.

## 2b. Extracted-body work ceilings (frozen)

A DIFFERENT KIND OF BOUND, and not interchangeable with the table above. The raw bounds are
PHYSICAL limits on received bytes. These bound the COST OF EXPANDING those bytes, so they are
checked at a different stage and cannot be exercised by an N/N+1 vector on received bytes.
Applying a physical bound to an extracted body would permanently reject valid records.

| Ceiling | Value | Bounds |
| --- | --- | --- |
| `MaxUncompressedBytes` | 32 MiB (33_554_432) | the extracted body's decoded size |
| `MaxCompressionRatio` | 100 | decoded size divided by encoded size |
| `MaxZstdWindowBytes` | 32 MiB (33_554_432) | the Zstd WINDOW a frame may advertise |

The window and output ceilings SHARING A VALUE in v1 is a coincidence, not a rule: one bounds
what the body costs to hold, the other what the decoder must retain as history while
producing it. A frame advertising a 64 MiB window while emitting 1 MiB of output passes the
output ceiling and the ratio and is still refused. Frozen normatively by the requirement
"Compression admission is frozen by value, stage, and frame shape"; owned by task 1.5-f.

The `+ 8` is CONSERVATIVE HEADROOM, not an exact derivation. The oneof framing at
the maximum frame size is 1 tag byte plus a 3-byte varint length (528 KiB <
2^21), so 4 bytes are actually required; an earlier revision of this table claimed
`+ 8` followed from "1 byte plus at most 5", which yields at most 6 and does not
add up either. The frozen value is 8, chosen with margin. What IS load-bearing is
that the client message has its own bound at all: a receiver bounding the frame but
not the enclosing message has an unbounded outer envelope. Values match
`go/pkg/edge/edgerecord/{canonical,validate}.go`; a divergence between this table
and those constants is a freeze failure, not a documentation nit.

WHO enforces each bound, and at which hop, is runtime.

### Non-byte structural, count and work ceilings (frozen, THREE enforcement stages)

None of these is a byte ceiling, and they are NOT all checkable at the same point.
Listing them in the raw-byte table above made a normatively impossible claim, but
calling them all "post-decode" is equally wrong: `MaxManifestPages` bounds how many
page BLOBS were supplied, which is countable without decoding any of them, while a
range count needs its page decoded and an ordinal total needs every page decoded.
Each row below names the EARLIEST stage at which its value exists.

| Bound | Value | Applies to | Stage |
| --- | --- | --- | --- |
| `MaxManifestPages` | 1024 | pages in one plan or recovery manifest | STRUCTURAL -- on the supplied page LIST, BEFORE any page is decoded |
| `MaxRangesPerPage` | 256 | `TargetRangeV1` entries in one plan page | POST-DECODE (per page) -- after that page decodes, before its ranges are walked |
| `MaxPlanMtrOrdinals` | 2^20 = 1048576 | TOTAL admitted MTR ordinals across one plan | POST-DECODE (whole plan) -- after every page decodes, BEFORE any commitment is folded |

`MaxPlanMtrOrdinals` is a WORK ceiling and is deliberately far below
`MaxMtrCompletionOrdinals` = 2^31: that constant bounds what the ordinal space can
REPRESENT, this one bounds what a validator will COMPUTE, since recomputing a
commitment costs one hash per ordinal. Both are frozen; they answer different
questions.

Every row must be applied before the work it bounds -- the page list before its pages
are decoded, a page's range count before its ranges are walked, and the ordinal total
before COMMITMENT HASHING. Not before all hashing: a page's own digests are computed to
validate it, and `MaxPlanMtrOrdinals` bounds the per-ordinal commitment fold specifically. The stage column says when each value first EXISTS, never how long
enforcement may be deferred.

## 2h. Bound OWNERSHIP INDEX (task 1.5-h audit)

The entry point for every bound this change freezes. It exists because "which task proves
this?" had no answer for most rows, and an unowned bound is how a ceiling ships inside a
freeze with nothing exercising it.

NO FROZEN VALUE IS RESTATED HERE. The applied requirement owns the number; this index owns
WHO PROVES IT. A row's value is read FROM THE SPEC, and from nowhere else -- not from this
document's readability tables, and not from a constant in either runtime.
AN ABSENT SPEC VALUE IS AN IMPLEMENTED CANDIDATE, NOT A FROZEN ONE. The normative
requirements and reviewed bound corpora now close the obligations identified by this audit;
implementation defaults such as ACK budgets remain policy. The overall freeze gate is still
tracked separately in 1.7-d. Sections 2 and 2b restate values for readability, so they are a
convenience for a reader and never a source for a task. The one place numbers do appear is the
MEASURED-MAXIMA table below, where the number IS the finding: those are not frozen bounds
but measurements of what a valid input can actually reach, and the gap between the two is the
whole point of that table.

Read the ACTION column as the audit's verdict, not as a plan 1.5-h may revise silently.

### Referenced only -- another task owns the proof

| Bound | Quantity and stage | Owner | Production gate (Go / Elixir) | Evidence today |
| --- | --- | --- | --- | --- |
| `MaxRecordBytes` | raw received bytes, pre-decode | 1.7-a | `DecodeRecord` / `decode_record` | CLOSED -- `raw_bounds_corpus.txt`, literal N/N+1 and predecode witness |
| `MaxDeliveryEnvelopeBytes` | raw frame minus record bytes | 1.7-a | `DecodeFrame` / `raw_frame_envelope_check` | CLOSED -- `raw_bounds_corpus.txt` |
| `MaxFrameBytes` | raw received bytes, pre-decode | 1.7-a | `DecodeFrame` / `decode_frame` | CLOSED -- `raw_bounds_corpus.txt` |
| `MaxClientMessageBytes` | raw received bytes, pre-decode | 1.7-a | `DecodeClientMessage` / `decode_client_message` | CLOSED -- shared bounds and `raw-transport-boundary-audit.md`; no deployed Go edge ingestion service is claimed |
| relational envelope budget | raw frame total minus record bytes | 1.7-b | `ValidateFrameRawEnvelope` / `raw_frame_envelope_check` | CLOSED -- `raw_relational_corpus.txt`, direct and client-wrapped duplicate-field controls |
| `MaxUncompressedBytes` | extracted-body output size | 1.5-f | `Compression` both runtimes | CLOSED -- shared `zstd_*` vectors |
| `MaxCompressionRatio` | output over encoded input | 1.5-f | `Compression` both runtimes | CLOSED -- shared vectors |
| `MaxZstdWindowBytes` | advertised frame window | 1.5-f | `Compression` both runtimes | CLOSED -- shared vectors |
| `MaxPayloadBytes` | DERIVED defensive guard, equal to `MaxRecordBytes` | 1.5-f | `validatePayloadBinding` / `Compression` | CLOSED -- literal-pinned in both runtimes |
| `MaxPlanPageBytes` | raw page bytes, pre-decode | 1.3 | `ValidatePlanFromRaw` / `decode_plan_page` | CLOSED -- `assignment_test.go` |
| `MaxCompiledAssignmentBytes` | raw carrier bytes, pre-decode | 1.3 | `ValidateCompiledSweepAssignmentBytes` / `decode_compiled_assignment` | CLOSED -- `assignment_test.go` |
| `MaxExecutionGrantBytes` | raw grant bytes, pre-decode | 1.3 | `verifyExecutionGrantSignature` / `decode_execution_grant` | CLOSED -- `assignment_test.go` |
| `MaxManifestBytes` | per-page AND summed raw page bytes | **1.6a** | `ValidateManifestChainFromRaw` / `RecoveryValidate` | CLOSED -- boundary tests both runtimes |
| `MaxSweepHostsPerBatch` | host count, post-decode | **1.3 (evidence) / 1.5-h (normative closure)** | `ValidateSweepObservationBatch` / `SweepBodyValidate` | **CLOSED** -- 1.3's vectors, and the requirement 1.5-h owed is now authored |
| `MaxTracesPerBatch`, `MaxHopsPerTrace`, `MaxEcmpPerHop`, `MaxMplsPerHop`, `MaxMtrBatchBytes`, and the four MTR `MaxTraceStrBytes` predicates | MTR counts, strings, canonical body | 1.4-a | `domain.go` / no Elixir MTR body validator in this task | CLOSED -- Go boundary pairs and literal ceilings; this owner does not promise a new Elixir MTR body peer |
| `MaxPlanMtrOrdinals` | admitted ordinal total per plan, post-decode; TWO Go sites, and a Go/Elixir ARITHMETIC ASYMMETRY in the second | 1.4 / 1.15 | `PlanMtrWindows` running total; `MtrWindowCommitment` count/offset. Elixir: `HashGrammar` peers of both | **RUNNING TOTAL CLOSED** -- the shared `plan_page_ordinals_at_max/over_max.bin` fixtures are MULTI-RANGE, so they exercise that gate. For `MtrWindowCommitment`: Go has BOTH a load-bearing COUNT control and an offset control; this runtime has ONLY the offset control, and its count conjunct is SHADOWED because bignum subtraction goes negative where Go's uint64 underflows. Go's arm is load-bearing, Elixir's is not, from identical-looking code |
| `MaxMtrCompletionOrdinals` | representable ordinal space; runtime-specific shadowed arms | 1.4 / 1.15 | Go expectation, plan and accumulator; Elixir assignment and hash grammar | CLOSED -- accepted ceiling and over-ceiling controls added in 1.4-a; the shadowing analysis below remains applicable |
| projected cost COVERAGE | declared cost covers enumerated synchronous mutations | 1.5-k | Go projection rows / Elixir `ProjectionRows` | CLOSED -- shared projection row inventory, normative transaction accounting and static writer inventory guard |

`MaxPayloadBytes` is NOT a ninth raw ceiling and SHALL NOT be added to the section 2 table.
It is a per-field defensive guard whose value is `MaxRecordBytes`, taken on the inner payload
before the whole-record ceiling is reachable. Section 2's table has eight rows because it names eight
BOUNDARIES, not because eight independent values exist -- `MaxFrameBytes` and
`MaxClientMessageBytes` are both derived from `MaxRecordBytes` already. A ninth row for
`MaxPayloadBytes` would add no boundary, only a second name for one that is listed, and would
invite the two values to drift apart.

The MTR row is the audit's sharpest exclusion. Those six bounds have no Elixir peer because
this runtime has NO MTR BODY VALIDATOR AT ALL -- not a missing bound inside an existing
validator, an absent boundary. Shared vectors would therefore be Go-only rows wearing a
shared-corpus shape. They stay with 1.4-a unless ownership is explicitly moved.

### Owned by 1.5-h -- residual domain-semantic admission

| Bound | Quantity and stage | Production gate (Go / Elixir) | Evidence today | Action |
| --- | --- | --- | --- | --- |
| `MaxPolicyIDBytes` | string bytes, post-decode; **TWO provable carriers** -- plan header (`ValidatePlanHeader`) and `SweepAssignmentRecordV1` (`ValidateSweepAssignmentRecord`) | `plan.go`, `assignment.go` / `PlanValidate`, `AssignmentValidate` | LANDED: the scalar corpus, FOUR controls per carrier per runtime -- 0 refused, 1 ACCEPTED, 128 accepted, 129 refused. The gate is `len == 0 \|\| len > Max`, which freezes a MINIMUM OF 1 as well as a ceiling, and EACH bound needs two controls: a pair proves only the upper, and a zero-refusal alone leaves the minimum free to move up because a validator tightened to reject length 1 refuses zero unchanged. Tightening either carrier's minimum to 2 now fails exactly its own row. The plan fixtures carry the policy CONSISTENTLY through every range with range/page/root/MTR/header commitments resealed, so only the header's length rule can refuse them. Deleting either carrier's bound fails exactly one row | COMPLETE |
| `MaxPolicyIDBytes` at a plan RANGE | REMOVED -- was derived | `plan.go` / `PlanValidate`, both now EQUALITY-ONLY | LANDED as a RUNTIME CHANGE, not a recorded exemption. THE AUDIT RESULT, kept here rather than in a production comment: the arm was not merely unreachable. With the header bound deleted, a CONSISTENT 129-byte policy -- the same value in the header and in every range -- was still refused at the range (`{:error, :plan_range}`), so a header row passed over the missing header gate. Centralized, the same mutation now ADMITS the plan and the header rows kill it. The production comments state only the RULE and why it lives in one place. CHRONOLOGY LIVES HERE TOO, not in the corpus comments: the plan-policy fixtures must be CONSISTENT over-limit because an inconsistent one is refused by the range's equality arm, and the plan-header padding reads its field number from the descriptor because a literal tag pads whichever field holds that number today -- `0x22` is `total_target_count` in `ScheduledPlanHeaderV1`, so the first attempt padded a uint64 with a length-delimited value and was refused by the decoder | COMPLETE. It gets no site row -- a row that cannot fail for its own reason is a vacuous row |
| `MaxPrincipalBytes` | producer context, edge publication slot, service publication slot | `ValidateAuthenticatedPrincipal` / `PublicationIdentity` helper, called by `RecordValidate` and both slots | FOUR controls at all three sites in both runtimes: empty refusal, minimum acceptance, ceiling acceptance, overflow refusal. Earlier mutation measurements covered five live carrier sites; the new record peer adds verdict parity without claiming a new mutation measurement | CLOSED -- 1.5-n; scalar and record boundary corpora |
| `MaxTraceStrBytes` at `abort_reason` | lifecycle conditional content and length | `ValidateSweepExecutionEvent` / `LifecycleValidate` | All SIX controls run in both runtimes: ABORTED empty/minimum/ceiling/overflow and non-ABORTED empty/nonempty | CLOSED -- 1.6-c, lifecycle and scalar corpora; MTR body strings remain with 1.4-a |
| `MaxPlanHeaderBytes` | raw header bytes, pre-decode -- **NAMED SCOPE EXCEPTION** | `ValidatePlanFromRaw` / `decode_plan_header` | LANDED in BOTH runtimes: 524288 accepted / 524289 refused, each encoding padded with an INERT duplicate field the true value overwrites and asserted to decode to the same header, so neither fixture reaches the ceiling by being malformed. Elixir gained an independent `@max_plan_header_bytes`; it was previously aliased to `@max_record_bytes`, so the two runtimes agreed by coincidence of VALUE. Each side also carries a STAGE WITNESS -- an over-limit UNDECODABLE header still refused for SIZE -- because the pair alone proves the ceiling, not the pre-decode ordering | COMPLETE. NO SECOND REQUIREMENT is authored: the normative source already exists. MEASURED LIMITATION: while both constants are 512 KiB, re-aliasing fails nothing -- no behavioural test separates two constants of equal value. Moving the plan-header ceiling alone is caught, but the row count depends on the direction and size of the move -- LOOSENING BY ONE fails only the boundary row, because the stage witness is larger than `over` and stays over the loosened ceiling; a larger move fails both. The claim is that the DRIFT is caught, not that a fixed number of rows fails. The Elixir stage witness asserts THOSE EXACT over-limit bytes are undecodable, through both `WireValidate` and the generated decoder, before claiming the size gate ran first -- a truncated PREFIX would prove some other input is poison while leaving the witness possibly decodable |
| `MaxRangeStrBytes` | string bytes, PRE-PARSE guard; THREE fields (`cidr`, `first`, `last`) | `plan.go` zone + length preflight before `rangeSpanSize` / `PlanValidate` the same | **NORMATIVE**, and LANDED: zone gate in both runtimes, three-part corpus in both | COMPLETE. Go's rows are mutation-killing. THIS RUNTIME'S LIMITATION IS NARROWER THAN "ELIXIR IS REGRESSION-ONLY": only its WHOLE-VALIDATOR zone row is regression-only, because the spelling check already refuses a zoned address there, so removing the preflight changes no verdict. The SEAM zone rows DO mutation-kill the predicates and pin the frozen ceiling, and the TRACED stage test proves attachment where no verdict can. A RECORDED LIMITATION of one row, not outstanding work -- see below |
| `MaxTransportProvenanceHeaderBytes` | header bytes, PRE-PARSE guard; **ONE testable site** -- `DecodeTransportProvenance` on receive. The emit-side check is DEFENCE IN DEPTH over output it just built and gets NO row | `DecodeTransportProvenance` / `PublicationIdentity` | LANDED in BOTH runtimes. The obligation was the STAGE, not the refusal: an oversize header and a malformed one are both refused, so the witness is a PAIR malformed IDENTICALLY and differing only in length -- at the ceiling the decoder must be reached AND object as the decoder, one byte over it must not be reached at all. Go reads that from the `base64.CorruptInputError` it already wraps with `%w`; Elixir from its existing `:bad_base64` / `:too_large` tags. NEITHER freezes diagnostic text and NEITHER mints an error class for the test -- the typed Go error is WHITE-BOX STAGE EVIDENCE ONLY and is not a normative refusal class. A GUARD, so no attainable-maximum pair is claimed: the largest CONFORMING header is 468 bytes (a 128-byte principal, a delivery proof, valid fixed-width numeric fields) and the corpus asserts that exact length, so a shrunken envelope cannot leave the headroom claim resting on a header that no longer represents the maximum | COMPLETE. Mutation-verified 5 per runtime: deletion, loosening, tightening, `>` to `>=`, and REORDERING the guard behind the parser -- the last returns an identical verdict and is caught only by the witness |
| `MaxManifestPages` **(recovery, RAW)** | supplied page-list length, pre-decode | `ValidateManifestChainFromRaw` -- correctly staged / `RecoveryValidate.bound_received` -- **now bounded** | LANDED: bounded traversal, call-site improper-tail row, and the SHARED N/N+1 corpus (`recovery_raw`) with a STAGE WITNESS each side -- Go a malformed final page only a decode could object to, Elixir a traced proof the decoder is never entered plus a live-decoder control | UPPER + STAGE COMPLETE. LOWER: the BOUNDARY is proven -- 0 refused, 1 accepted -- and that is the WHOLE claim. The LOCAL ARM is deliberately left unproven and the lower-bound corpus classes it `silent`: this raw check falls through to the decoded refusal, which returns the SAME reason, so no verdict-based row can kill its removal. Recorded, not claimed. Kept as its own site because the plain N+1 verdict is shared with the decoded gate |
| `MaxManifestPages` **(recovery, DECODED)** | page-list length on decoded pages | `ValidateManifestChain` / `RecoveryValidate.manifest_chain` -- **both now count first** | LANDED: precedence rows in both runtimes, mutation-verified, plus the shared N/N+1 corpus (`recovery_decoded`) | COMPLETE. LOWER LANDED: the recovery page-list MINIMUM is now normative (this task authored it -- the shared ceiling was stated for a recovery manifest but its minimum spoke for the PLAN list alone), with 0 refused / 1 accepted in both runtimes. The local arm is classed `crashes`: removing it INDEXES PAGE ZERO OF AN EMPTY SLICE, so it is what keeps a public validator from panicking on attacker-supplied input, and the row kills its removal |
| `MaxManifestPages` **(plan, RAW)** | supplied page-list length, pre-decode | `ValidatePlanFromRaw` -- correctly staged / `AssignmentValidate.bound_page_count/2` -- **now bounded** | LANDED: bounded traversal, call-site row, and the SHARED N/N+1 corpus (`plan_raw`) with a STAGE WITNESS each side -- Go an oversized final page (`ErrPlanPageTooLarge` wraps `ErrPlanBounds` and is separately testable), Elixir a traced proof plus a live-decoder control. Both accept at N through their PUBLIC boundary: Go's `ValidatePlanFromRaw` takes header bytes and raw pages, while this runtime's `validate_bytes_against_plan_bytes/3` also validates a RECORD, so its at-ceiling row carries a valid assignment bound to the generated plan rather than an empty one | UPPER + STAGE COMPLETE. LOWER: the BOUNDARY is proven (0 refused / 1 accepted) and that is the whole claim -- the LOCAL ARM is deliberately unproven, classed `silent` in Go -- removing it changes NO verdict, since the decoded gate refuses the same input for the same reason -- and `combined` in Elixir, whose predecode gate is one conjunction with no separable zero arm. The corpus records both and claims no proof of either arm |
| `MaxManifestPages` **(plan, DECODED)** | page-list length in `ValidatePlanPages` | both runtimes now count AFTER header validation and BEFORE the walk | LANDED: precedence rows both runtimes; the declared page count stays a header RELATION below the walk; plus the shared N/N+1 corpus (`plan_decoded`) | COMPLETE. LOWER LANDED: 0 refused / 1 accepted. The local arm is classed `retags` -- removing it leaves the header page-count RELATION refusing the same input under a different reason -- so the row asserts the exact reason, which is what kills the removal |
| `MaxRangesPerPage` | range count, post-decode per page | `plan.go` / `PlanValidate` -- **both now precede descent** | LANDED: precedence rows both runtimes, plus the shared N/N+1 corpus (`plan_ranges`). The page-size ceiling returns the SAME refusal tag, so it is excluded against the LIVE bound rather than a copied number: Go runs the REFUSED pages through the exported `MaxPlanPageBytes`, and this runtime -- whose ceiling is private -- adds an ACCEPTED N-range control built from canonical full-length IPv6 that encodes LARGER than the refused N+1 page, so any ceiling low enough to have refused N+1 for size refuses the control too. The discriminating mutation is a ceiling STRICTLY BETWEEN the two encoded sizes; both runtimes fail it | COMPLETE. LOWER LANDED: 0 refused / 1 accepted, and this is the load-bearing plan arm -- classed `admits`, because removing it ADMITS a page with no ranges outright in both runtimes |
| `MaxSpansPerPage` **(chain)** | span count, post-decode per page | `ValidateManifestChain` / `RecoveryValidate` -- **both now precede descent** | LANDED: precedence rows both runtimes, plus the shared N/N+1 corpus (`recovery_spans_chain`) | COMPLETE. LOWER LANDED: 0 refused / 1 accepted. Classed `retags` -- the span-body fallback refuses the same input under its own reason -- so the rows assert the exact reason. The fallbacks are RECORDED rather than centralized: restructuring a validator to make a shadowed arm independently killable changes production code to suit a test |
| `MaxSpansPerPage` **(single page)** | span count on ONE page | `validateSingleManifestPage`, reached from the recovery-control path / **no Elixir peer** | LANDED (GO ONLY): a signed recovery-control wrapper around the shared span pair -- page sealed first, scope digest taken from it, payload/claim/envelope/both signatures built after, nothing mutated post-seal; both artifacts pass `ValidateRecordSigned` before any production claim. Removing ONLY this ceiling ADMITS the over-limit wrapper | COMPLETE (upper + lower), GO ONLY, NOTHING DEFERRED -- all four controls (0/1/N/N+1) run through the SIGNED boundary with `ValidateRecordSigned` asserted first, since the page is reachable only via `ValidateRecoveryControl`. Single-runtime row: the peer is **1.6-d**'s, recorded as `n/a` with that owner in the corpus so an absent peer cannot become a silent exemption. The local arm is classed `retags`, so the rows assert the exact refusal reason |
| `MaxManifestPages` **(tombstone)** | supplied page-list length, against a DECLARED count | `ValidateTombstone` / `RecoveryValidate.tombstone/2` -- **both now bound BEFORE comparing the declared count** | LANDED: bounds-before-relation parity rows in both runtimes, mutation-verified, plus the shared N/N+1 corpus (`tombstone`). The N+1 tombstone RESEALS its declaration to 1025 and asserts so -- declaring 1024 would be refused by the count RELATION and the row would pass with the ceiling deleted | COMPLETE for the page-LIST bound. An INDEPENDENTLY REMOVABLE eighth site. SEPARATE, AND NOW LANDED IN GO: the signed tombstone's `manifest_page_count` rule bounds a DECLARED SCALAR, not a supplied list, so it is a different site from the page-LIST bound above. BEFORE THIS TASK it had no dedicated count-specific pair in either runtime -- the signed reason rows exercised a count of 1 only INCIDENTALLY, since every wrapper declares one page, with nothing varying the count or asserting a verdict on it -- and `recoveryControlBody` checked `== 0` alone, so a declaration of 2^32-1 was admitted on the only path a SIGNED tombstone reaches. NOW: that gate bounds `1..MaxManifestPages` (detected-at split into its own fault), with FOUR Go controls -- 0 refused, 1 accepted, 1024 accepted, 1025 refused -- each rescoping and re-signing a fresh record and asserting `ValidateRecordSigned` before the production claim. The signed Elixir peer is **1.6-d**'s and MIRRORS ALL FOUR; what is delegated is the TARGET bound, not the `== 0` arm Go carried before |
| `MaxReasonBytes` | tombstone reason bytes, on the SIGNED recovery-control body path | `recoveryControlBody`, reached only via `ValidateRecoveryControl` / **no signed path exists** (1.6-d) | LANDED (GO ONLY): FOUR controls -- 0 refused, 1 ACCEPTED, 256 accepted, 257 refused -- through a signed wrapper -- tombstone sealed first, scope digest taken from it, payload/claim/envelope/signatures built after, `ValidateRecordSigned` asserted before any production claim. The empty arm is its own rule AND needs its own accepted control: a frozen minimum of 1 is not pinned by a zero-refusal, which a validator rejecting length 1 satisfies unchanged | delegated to **1.6-d**, recorded `n/a` with that owner |
| declared projected cost vs the capability's DECLARED maxima | structural, pre-signature | `ValidateRecord` / `RecordValidate.validate_bytes/1` | Shared model equality and each cost maximum relation, including equality acceptance and one-over refusal; Go signed-boundary ordering test remains distinct from structural parity | CLOSED -- 1.5-n. Actual row accounting is 1.5-k |

### Which ordinal arms can be mutation-killed, measured -- PER BOUND

The two ordinal ceilings are different bounds with different arms, and an earlier revision of
this section mixed them. They are separated here because a shadowed arm of one is not evidence
about the other.

#### `MaxMtrCompletionOrdinals` -- the ordinal SPACE

`PlanMtrWindows` checks a range's count and the running total against this ceiling, then checks
the accumulated total against the lower `MaxPlanMtrOrdinals` work ceiling two statements later.
Both return the SAME error, so the question is which arms change a VERDICT when removed --
every mutation column, not just the convenient ones:

| input | all arms | per-range arm removed | plan-total arm removed | both removed |
| --- | --- | --- | --- | --- |
| count one over the space ceiling | per-range | work ceiling | per-range | work ceiling |
| count = 2^64-1 | per-range | work ceiling | per-range | work ceiling |
| first range 1, second at the space ceiling | **plan-total** | plan-total | work ceiling | work ceiling |
| count one over the work ceiling | work ceiling | work ceiling | work ceiling | work ceiling |
| two ranges whose counts wrap uint64 | per-range | **ADMITTED** | per-range | **ADMITTED** |

**The plan-total arm DOES fire** -- row three is exactly that case, and an earlier revision
claimed it never fired because the inputs chosen never reached it. The correct statement is
narrower and is what matters for evidence: REMOVING IT NEVER CHANGES THE FINAL VERDICT, because
the work ceiling refuses the same input two statements later. SHADOWED; no evidence row.

**The per-range arm is load-bearing for one INPUT CLASS**: two or more ranges whose counts sum
to a uint64 wrap, where the total lands back under the work ceiling and everything is ADMITTED
without it. One row instantiates the class; the class is not one input. That row must assert admitted-versus-refused, not error identity.

**This runtime's expected-ceiling arm is SHADOWED by its offset arm.**
`mtr_completion_verify` checks `expected <= @max_mtr_ordinals`, then
`plan_ordinal_offset > @max_mtr_ordinals - expected`. Under arbitrary precision an
over-ceiling `expected` makes that right-hand side NEGATIVE, so any non-negative offset
satisfies it and the later arm refuses anyway. Only the arm's `is_integer` TYPE check is
load-bearing. **The offset arm is the load-bearing predicate** -- it is what shadows expected,
so it is not itself a candidate for classification.

So this bound has TWO shadowed arms: Go's plan-total arm and this runtime's expected-ceiling
arm.

**The expectation ceiling now has both directions in both runtimes.** Task 1.4-a
added accepted-at-ceiling controls as well as one-over refusals. The earlier refusal-only
coverage allowed a stricter `>=` mutation to survive; those controls close that debt.
The shadowed-arm classifications above remain unchanged.

#### `MaxPlanMtrOrdinals` -- the validation WORK ceiling, and a Go/Elixir arithmetic asymmetry

`MtrWindowCommitment` guards `count <= ceiling AND offset <= ceiling - count` in both runtimes
-- the same relation, written the same way. Removing the count conjunct does OPPOSITE things:

| input | Go, count conjunct present | Go, count conjunct REMOVED | this runtime, conjunct removed |
| --- | --- | --- | --- |
| offset 0, count = ceiling+1 | refused (count) | **ADMITTED** | refused (offset) |
| offset 0, count = ceiling | admitted | admitted | admitted |
| offset = ceiling, count 1 | refused (offset) | refused (offset) | refused (offset) |

**Go's count conjunct is LOAD-BEARING and this runtime's is SHADOWED, from one line of
identical-looking code.** `ceiling - count` UNDERFLOWS uint64 to 2^64-1 in Go, so the offset
comparison passes and the value is admitted; in Elixir the same expression is -1, and any
non-negative offset exceeds it, so the offset conjunct refuses. THE ARM IS THE SAME; THE
INTEGER MODEL IS NOT. A shadowing verdict is therefore not portable between runtimes and must
be established separately in each -- which is the general lesson, not a note about one guard.

Go already HAS the load-bearing count control (`MtrWindowCommitment(0, ceiling+1, ...)` in
`assignment_test.go`). This runtime has only an OFFSET control, and its count conjunct cannot
be mutation-killed at all. That is the third shadowed arm across both ceilings, and it belongs
to THIS bound -- not to `MaxMtrCompletionOrdinals`, where an earlier revision filed it.

### The zone prohibition is load-bearing in ONE runtime, and a regression pin in the other

Go's `netip.ParseAddr` accepts a scoped IPv6 address and round-trips it canonically, so without
the gate Go ADMITS a zoned range string -- at the ceiling, since a zone is arbitrary-length
text. Disabling the gate fails rows there; forging the handoff past the preflight fails the
whole-validator row.

This runtime never admitted one. `:inet.parse_strict_address/1` accepts the zoned text and
silently DISCARDS the zone, after which the canonical-spelling check refuses the mismatch. No
zoned value can round-trip, so the spelling rule catches every one -- and reports the SAME
`:plan_range` atom the zone gate would. Removing the gate there changes no verdict, measured.

THE GATE IS STILL REQUIRED THERE: the frozen rule says a zone is refused BEFORE either parser,
and the spelling rule runs after. NO VERDICT distinguishes the two, so the validator-level
Elixir rows are REGRESSION rows -- they catch a change that made that runtime ADMIT a zoned
address, and claim nothing more.

THE STAGE ITSELF IS OBSERVED AT THE VALIDATOR, by CALL TRACING through the real
`PlanValidate.validate/2`: the preflight must be called and `:inet.parse_strict_address/1` must
not. So "unobservable" was only ever true of verdicts, and no distinct refusal reason was
needed.

WHAT EACH KIND OF ROW PROVES, kept apart because they are not interchangeable:

- THE SEAM proves the PREDICATES and pins the FROZEN CEILING. It parses nothing, so an
  at-ceiling acceptance exists there when none exists through the whole validator.
- GO'S WHOLE-VALIDATOR ZONED ROW proves ATTACHMENT in that runtime: forge the handoff and it
  fails, because Go would otherwise admit a zoned equal-endpoint span.
- ELIXIR'S TRACED STAGE TEST proves attachment there, where no verdict can: the preflight must
  be called and `:inet.parse_strict_address/1` must not.

A seam row does NOT prove attachment, and a validator row does not pin the ceiling. Treating
either as the other is how a suite ends up green over a bypass.
THE HANDOFF IS NOT UNFORGEABLE, and the two runtimes are NOT in the same position about it.
Go's checked struct and Elixir's tagged tuple are both ordinary in-module values, so code
inside either can construct one.

In GO the forgery is caught: replacing the preflight call with a forged handoff fails the
whole-validator zoned row, because Go would otherwise ADMIT a zoned equal-endpoint span.

IN ELIXIR NO VERDICT CATCHES IT. Measured across zoned spans, zoned CIDRs, over-length values
in each field, and valid controls: every candidate returns an IDENTICAL verdict with the
preflight and with it forged away, because everything the preflight refuses is ALSO refused
downstream -- zones by the canonical-spelling check, over-length values by the parser.

A VERDICT IS NOT THE ONLY OBSERVABLE. OTP CALL TRACING sees the stage directly: a worker runs
the real `PlanValidate.validate/2` while `__check_range_strings__/3` is traced `:local` and
`:inet.parse_strict_address/1` globally, and a zoned or over-length input must show the
preflight called and the parser NOT called. A valid control proves the parser trace is live,
so "parser not called" cannot pass because the pattern was dead. Forging the handoff fails
every row. This needs no production change and no new refusal reason, so the earlier claim
that a production-path observer and the no-new-taxonomy rule were jointly unsatisfiable was
WRONG -- it mistook "no verdict distinguishes them" for "nothing does".

TWO TRAPS THAT MAKE A TRACED ROW VACUOUS, both closed here. `trace_pattern/3` on a module the
VM has not loaded yet matches ZERO functions and reports so without raising -- which is how
the first test in a file silently traces nothing while the rest pass. The modules are loaded
first and the MATCH COUNT is asserted. And trace messages reach the tracer asynchronously, so
a timeout-based drain can return before the last one arrives and report a race as "the parser
was not called"; `trace_delivered/1` synchronises instead. THE SEAM IS ALSO THE ONLY
PLACE THE FROZEN CEILING CAN BE PINNED: no canonical address reaches 64 bytes, so a
whole-validator at-64 acceptance does not exist, and a 65-byte refusal driven through the
validator survives the bound drifting anywhere from 43 to 65 because the parser refuses those
lengths anyway. Measured: at the seam, drifting the bound to 128 and tightening `>` to `>=`
each fail rows in both runtimes; through the validator, neither does.

### Two NAMED exceptions to 1.5-h's "no raw bounds" scope

1.5-h's scope says it does not own raw or pre-parse bounds, and it owns two anyway:
`MaxPlanHeaderBytes` (raw, pre-decode) and `MaxTransportProvenanceHeaderBytes` (pre-parse).
They were here for different reasons, both HISTORICAL now. AT THE START OF 1.5-H,
`MaxPlanHeaderBytes` was normatively stated but had NO SHARED EVIDENCE, and 1.7-a was scoped to
the four transport ceilings rather than to it; task 1.14 had defined and implemented the
provenance grammar and is `[x]`, but left NEITHER a requirement for its bound NOR evidence, so
1.5-h took it as REMEDIATION rather than first ownership. BOTH EXCEPTIONS ARE NOW COMPLETE
UNDER 1.5-H -- the plan header's shared evidence and named Elixir ceiling, and the provenance
guard's requirement and stage-sensitive corpus in both runtimes.
They remain EXCEPTIONS BY NAME, not a widening: any further raw bound belongs to a raw-bound
owner, and adding a third to this list requires saying which owner declined it.

### What this index does NOT own: the semantic-envelope transcript

An earlier draft inventoried it here. It is not a bound -- no ceiling, no value to freeze, only
the SHAPE of a transcript -- so carrying it in a BOUND ownership index invited exactly the
category error the index exists to prevent. It is frozen as a grammar in
[section 3](#3-identity-semantics-grammars-and-version-inventory) under task 1.5-i.

### The range-string guard is REACHABLE, and the runtimes disagree

The first version of this index called `MaxRangeStrBytes` unreachable on a measurement that
enumerated only UNSCOPED addresses. `netip.ParseAddr` also accepts SCOPED IPv6 addresses, and
a zone is arbitrary-length text:

    fe80::1%eeeeeeee...   (8-byte prefix + a 56-byte zone) = EXACTLY 64 bytes

It round-trips canonically through `Addr.String()`, so Go's spelling check passes, and
`rangeSpanSize` accepts `first == last`, so the span is 1 and `target_count == 1` matches. The
bound is reachable AT the ceiling in Go, through the first/last form. It is NOT reachable
through the CIDR form: `netip.ParsePrefix` rejects zones outright, so that arm's maximum stays
43 bytes.

**The runtimes disagree, and not by rejecting at different lengths.**
`:inet.parse_strict_address/1` ACCEPTS the zoned text and SILENTLY DISCARDS the zone --
`fe80::1%eth0` and `fe80::1` both parse to the same tuple. The refusal then comes from
`canonical_addr?/2`, which compares `:inet.ntoa(tuple)` against the input and finds
`"fe80::1"` unequal to `"fe80::1%eth0"`. So this runtime refuses a scoped address as a
NON-CANONICAL SPELLING while Go accepts it as a canonical one. Two parsers, one contract,
opposite verdicts on the same bytes.

**The syntax was decided before the bound, and is now FROZEN: zones are REFUSED, never
stripped.** A zone is node-local -- it names an interface on the machine that wrote it and
cannot be interpreted by any other agent -- so a scoped address in a scheduler plan target
range has no meaning at the receiver. The prohibition closes the parity gap and restores 43
bytes as the maximum canonical range string. Repair was rejected rather than merely not chosen:
these strings feed the range, page, plan-root, header and assignment digest chain, so rewriting
one forks a plan's identity from the bytes its author signed.

**Which then makes 64 unreachable again, so the proof shape follows the RULE, not the
constant.** Forbidding zones and then demanding an at-ceiling/one-over pair would
be asking for a vector the chosen rule forbids. The corpus for this bound is three parts:

1. **zone-present refusal, per field** -- load-bearing in Go, which admits a zoned address
   without it; a REGRESSION row in Elixir, whose spelling check already refuses one with the
   same reason, so removing that gate changes no validator verdict;
2. **accepted controls** -- at the frozen ceiling for the PREFLIGHT SEAM, and at the largest
   valid syntax for the whole validator;
3. **one over-limit control per field**, addressed at the seam so the stage is structural.

Only part 1 is a semantic rule. Parts 2 and 3 are what a defensive guard can honestly prove:
that valid input passes and that over-limit input is refused before parsing, never that the
ceiling is an attainable maximum.

### One bound that admits no N/N+1 pair, measured rather than argued

`MaxTransportProvenanceHeaderBytes` is a DEFENSIVE PRE-PARSE GUARD, not an inclusive semantic
maximum. The largest valid header is **468 bytes** against a 512-byte guard -- measured by
composing `TransportProvenance` over a 128-byte principal (the `MaxPrincipalBytes` maximum) in
RENEWAL mode, the only variable-length composition. There is no accepted-at-512 control to
build.

The guard runs before `base64.RawURLEncoding.Strict()`, so the evidence it admits is
stage-sensitive: THE PARSER WAS NOT ENTERED. An accepted-512 row would be a vector passing for
a reason it does not name, and a reader would take it as proof that 512 is a legal header
length. Only one of its two sites is defending against anything -- `DecodeTransportProvenance`
on receive; `TransportProvenance` on emit is checking output it just built.

### Every removable site needs BOTH directions

A site row that carries only an over-limit negative stays green when that validator rejects
EVERYTHING -- a mis-wired site, a stale digest, an unrelated precondition. It proves the site
is reachable and refusing; it does not prove the site is refusing FOR THIS REASON. Each site
therefore gets an accepted control at a legal value AND its own over-limit negative. That is
what makes a site row independently removable, which is the property the corpus is for.

### Six findings that contradict the audit's own starting assumptions

Historical findings below describe the starting state and why the tasks were split.
Current closure is in the ownership tables above: 1.7-a added `DecodeClientMessage`,
1.5-n added `RecordValidate`, and 1.7-f added composed ACK admission in both runtimes.
Statements of absence in this historical narrative are not current implementation status.


**The count ceilings are not proven anywhere, and the stage defect affects HALF the sites
rather than all of them.** (AS FOUND BY THE AUDIT -- historical. The ordering and
traversal defects below are FIXED; the ownership index above carries present state. This
section records why no verdict-only vector could have found them.) A repository-wide search for `MaxManifestPages`, `MaxRangesPerPage` and
`MaxSpansPerPage` across every `_test.go` returns nothing, and no `1025`/`257` construction
exists in either runtime. The staging is not one defect but four different situations, which
is why the index gives each its own row:

- **Go RAW entrypoints are already correct.** `ValidatePlanFromRaw` and
  `ValidateManifestChainFromRaw` compare the supplied list length against `MaxManifestPages`
  BEFORE decoding anything. Saying these run late was wrong.
- **Go DECODED validators run late.** `ValidatePlanPages` runs `hasUnknownFields(p)` -- which
  recurses into every range of every page -- across the whole list BEFORE comparing
  `len(pages)`, and the per-page range count is checked after that page's ranges were walked.
- **This runtime's RAW gates traverse to count.** `AssignmentValidate.bound_page_count/2` and
  `RecoveryValidate.bound_received/1` call `length/1` on the entire attacker-supplied list, so
  a ten-million-element list is fully walked to discover it is too long. The stage is right;
  the traversal is not. A comparison bounded at N+1 elements fixes it without moving the check.
- **This runtime's DECODED checks run late**, matching Go's decoded validators.

Both runtimes return the CORRECT VERDICT at every one of those sites, which is why no
VERDICT-ONLY N/N+1 vector would have caught the two that are mis-staged: such a pair passes in
both directions while the work the ceiling exists to prevent has already been done. Only
stage-sensitive evidence separates them, and only per site -- a single "the count gates run
late" row is false for the two Go raw entrypoints, which are already correct.

**`MaxReasonBytes` is attached to a different boundary than the index first claimed.** Neither
Go's `ValidateTombstone` nor this runtime's `RecoveryValidate.tombstone/2` reads `reason` at
all. Go bounds it inside `recoveryControlBody`, reachable only through `ValidateRecoveryControl`
-- the SIGNED path. So the Elixir gap is not a missing line in an existing validator; it is the
same absent-boundary situation as the three recovery scope transcripts, and its peer is blocked
on 1.6-d. The first version of this index said "absent from `RecoveryValidate.tombstone/2`",
which named a real function that was simply not the boundary in question.
Separately, the spec froze the MAXIMUM and said nothing about a lower bound while Go refused
length 0. THAT IS NOW DECIDED AND FROZEN: an empty reason is REFUSED. A tombstone records that
spooled records were lost and is read by an operator reconstructing what happened; an empty
reason says data was lost and declines to say why, which is the one thing the message carries.

**`MaxClientMessageBytes` has no edge-ABI gate in Go**, and this belongs to 1.7-a rather than
to 1.5-h. The constant is declared, `ErrClientMessageTooLarge` is declared beside it, and a
repository-wide search finds NO call site for either: the error is never returned by any code
path. Elixir enforces the ceiling in `decode_client_message/1` before its scan. This does NOT
establish that Go accepts unbounded input, and it does NOT establish that anything else stops
it either. EXACTLY ONE THING IS ESTABLISHED: the ABI's own ceiling has no enforcement site.
Whether an outer gRPC receive-message limit is configured on that path is UNKNOWN and was not
examined, so no conclusion follows about what does bound that message -- including the
conclusion that a transport setting does. 1.7-a SHALL DETERMINE the effective bound. "A gRPC
limit probably catches it" is the assumption under which this gap sat unnoticed, and
"a transport setting bounds it instead" is the same assumption with a confident tone. Found only because the index has a production-gate column: a bounds inventory
listing names and values renders a declared constant and an enforced one identically.

**BOTH residue guards end up guard-class, but only after a syntax decision.** The audit assumed
every bound in its residue was an inclusive semantic maximum, then over-corrected and called two
of them unreachable. `MaxTransportProvenanceHeaderBytes` always was a defensive guard.
`MaxRangeStrBytes` was NOT -- it is reachable at exactly the ceiling through a scoped IPv6
address, which the first measurement missed by enumerating only the address shapes it thought
of. FORBIDDING ZONES PUT IT BACK OUT OF REACH, so with that prohibition frozen and IMPLEMENTED
it is guard-class too, and its evidence follows the guard shape rather than an at-ceiling pair
-- pinned at the preflight seam, which is the only place an at-ceiling acceptance exists.
A measurement establishes what the sample reached, never what the parser accepts -- the
parser's grammar is the thing to read.

**The projected-cost comparison is STRUCTURAL and PRE-SIGNATURE, not post-signature.**
`ValidateRecord` performs no cryptographic verification at all; `validateProductionCapability`
runs inside it, comparing a record's DECLARED cost against the maxima carried in an
UNVERIFIED capability. Calling the row "post-signature" described a boundary that does not
exist here. The accepted-equality control also already existed and had been recorded as
missing: `validate_test.go` builds every valid record with the declared maxima set EQUAL to the
declared values, so every passing test is an equality control at both operands.
WHAT WAS GENUINELY MISSING -- `projected_write_bytes` overflow and a `cost_model_version`
mismatch -- HAS LANDED, together with an explicit at-maximum acceptance per quantity and an
order test at the signed boundary. The relation row above is the single record of it.

**No validator on either side of this ABI has a live ingress caller, so "production-shaped"
is defined ONCE and applied everywhere.** `SemanticValidate.validate_record/1` has no
production caller -- every reference is in an `.exs` test file. Neither do Go's transport
validators: `ValidateLaneOpenAck` and `ValidateAck` have ZERO non-test callers, and
`ValidateLaneOpen`'s only non-test caller is `ValidateLaneOpenAck` itself.

THE DEFINITION FOR THIS CHANGE: a COMPLETE VALIDATOR API -- one that applies the full rule and
is callable by an ingress -- is sufficient, and a COMPOSED API SET counts, provided its ORDER
is not left to the caller. Live ingress attachment is downstream and is NOT a closure condition
here. This change freezes a contract, and a contract is testable before it is wired.

That qualifier is not decoration. Go exposes `ValidateAckRawSize` and `ValidateAck` separately
and composes them nowhere, so the sequence that makes the raw guard meaningful lives in each
caller. 1.7-f owns supplying a composed entrypoint or attaching the two to a real ingress that
composes them. THERE IS NO ORDERING-EVIDENCE FALLBACK: no vector can oblige a caller to invoke
the raw guard first, so a suite calling them in order proves the functions work and nothing
about a caller that skips one. The plan boundary reached this conclusion already and unexported
its page-only path.

That resolves what were two definitions. An earlier revision rejected an Elixir validator API
for lacking a live caller while accepting Go's zero-caller validators, which is the same
artifact judged twice. What 1.5-n owes is therefore a COMPLETE structural record boundary --
not a comparator bolted into a function that applies no other record rule -- and the Elixir
record-level `MaxPrincipalBytes` check attaches to that same boundary.

### Deliberately excluded, with the reason

| Excluded | Why |
| --- | --- |
| `MinNonceBytes` / `MaxNonceBytes`, `MaxByteCredits`, `MaxFrameCredits` | LANE-OPEN admission -- task 1.7's subject is the frame AND LANE HANDSHAKE. Not raw bytes, so 1.7-a does not reach them either. NOW OWNED BY 1.7-e |
| `MaxRejectionCodeLen` | DELIVERY-ACK, owned by 1.7-f. CLOSED: the normative requirement specifies the finite length and machine-token grammar; `DecodeAck` / `AckValidate` share isolated code controls |
| `DefaultMaxDispositions`, `DefaultMaxDispositionBytes` | Caller-overridable policy defaults, not ABI ceilings. 1.7-f CLOSED the normative finite-limit obligation at raw bytes, decoded count and canonical bytes; `ack_bounds_corpus.txt` isolates each. Non-positive arguments select finite defaults or are refused, never disable a gate |
| `MaxClockToleranceNano` | NOT FROZEN, and not this change's. The 300-second cap is LOCAL AUTHORIZATION POLICY -- how stale a signed authority a deployment will still honour -- which sits outside a wire ABI. It is excluded from 1.5-h and from 1.5-i. If it must become interoperable it needs a dedicated signed-authority-currentness subtask with a normative literal and real runtime evidence, not a home in a residue bucket |
| whether projected cost COVERS every real mutation | explicitly 1.5-k; 1.5-h verifies only that the declared value is compared against the capability's DECLARED maxima. Not "signed": the comparison runs pre-signature, so nothing has verified those maxima at that point |

### What this audit opened

All three additions in this historical table are now reviewed and closed:
1.7-e in 72d6409c4b, 1.7-f in 19e37a307a, and 1.5-n in 5b8af178b2.
The table preserves why each needed its own owner.


| Opened | Why it was owned by nothing |
| --- | --- |
| **1.7-e** lane-open admission, BOTH halves | 1.7's body covers the lane handshake, but its subtasks were the four raw bounds, the relational envelope, fixture coverage and the gate -- none reaches a nonce length or a credit cap. It covers the REQUEST (`EdgeRecordLaneOpen`) and the RETURN half (`EdgeRecordLaneOpenAck`, validated by `ValidateLaneOpenAck`), which is independently removable and distinct from the `EdgeDeliveryAckV1` path in 1.7-f |
| **1.7-f** acknowledgement bounds | the ACK path is not the lane-open handshake; folding `MaxRejectionCodeLen` and the finite-receiver-limit requirement into 1.7-e would have put two legs under one subtask |
| **1.5-n** the Elixir structural record boundary | Go compares declared cost to the capability maxima in `ValidateRecord`; this runtime only DIGESTS the three fields. The deliverable is a COMPLETE boundary, not a comparator: `SemanticValidate.validate_record/1` applies no production record rule beyond enum and shape checks, so a cost comparison bolted onto it would sit next to none of the rules it must run with. Its lack of a live caller is NOT the objection -- no validator on either side of this ABI has one. It also carries the record-level `MaxPrincipalBytes` check. Filed under 1.5, NOT 1.6: parent 1.6 is the version-corpus parity task, and a non-inventory member there would make its 15/19 figure mean two things at once |

### An unowned follow-up, deliberately without a task identifier

NOT A SUBTASK, and the count above does not include it: nothing in this change is blocked on it
and no one owns it yet. Recorded so it is not rediscovered from scratch.

**A descriptor-validated declarative grammar that GENERATES both framers.** 1.5-i freezes the
transcript behaviorally and adds two static guards over framing order, but those guards reason
from the OUTSIDE: Go matches proto and oneof accessors by NAME, and Elixir reads function bodies
without resolving heads, guards, macro expansions or remote calls. Replacing them with a typed
analyzer per language buys machinery rather than closure -- neither frontend could be a proof
against Elixir macros or dynamic dispatch, so both would keep chasing host-language semantics
from outside. Generating both framers from one descriptor-validated declaration removes the
arbitrary host program instead of analysing it, which is the only version of this that ends.

Whoever picks it up should read the two guards first: they are the specification of what the
generated framers may do.

WHY THE OPEN COUNT WENT UP. This audit was expected to reduce work by finding that most bounds
were already proven elsewhere. It did the opposite: three subtasks opened; three count ceilings
found unproven in BOTH runtimes, with the stage defect at HALF their sites -- Go's raw
entrypoints are already correct, its decoded validators are not, and this runtime traverses to
count at gates that are otherwise correctly staged; three runtime divergences
(`MaxReasonBytes`, `MaxClientMessageBytes`, the projected-cost comparison); TWO bounds that admit no
at-ceiling/one-over pair -- the provenance guard, and the range string once zones are forbidden,
which was itself found REACHABLE after being called unreachable; three ordinal arms shown unable to carry an independent verdict row;
and one bound (`MaxSweepHostsPerBatch`) fully vectored in both runtimes yet not closeable
because no requirement states its value.

The ledger records the resulting obligations; this section records how they were found, per
rule N4. A count that only ever falls is measuring closure, not coverage -- every one of these
was invisible to each earlier count precisely because nothing owned it.

## 3. Identity semantics, grammars, and version inventory

### Record identity: producer-receipt, physical, semantic, domain

The edge pipeline uses four deliberately-separate identities across its stages --
not four fields carried on one record; only `semantic_envelope_sha256` and
`event_id` are carried ON the record, while `submission_sha256` stays journal-local
to the producer->sink hop and `record_sha256` rides the delivery frame. Byte-for-byte
equality of two records is NOT a protocol invariant: protobuf has no canonical
wire form, and field numbering, a signed raw hash, or a runtime reorder pass
cannot create one, so nothing requires, asserts, or enforces a unique byte
encoding of a record.

These four identities are PIPELINE-STAGE identities, NOT four fields of one
`EdgeRecordV1`. `submission_sha256` is journal-local to the producer->sink hop and
NEVER appears on the wire; `record_sha256` belongs to the delivery frame/slot
(`EdgeDeliveryFrameV1`) and its binding, not to `EdgeRecordV1`; only
`semantic_envelope_sha256` and `event_id` live on `EdgeRecordV1`. The table's
"Role" column names the boundary each one governs.

| Identity | What it is | Role |
| --- | --- | --- |
| `submission_sha256` | SHA-256 of the producer's bounded UNCOMPRESSED contract-payload submission bytes, computed BEFORE the sink compresses/constructs the record | Producer receipt + producer idempotency (retry-lookup COMPARISON value; the journal keys on the 5-tuple, never on this digest); never a transport/semantic/event-ledger key. |
| `record_sha256` | SHA-256 of the exact bytes the sink emitted | Physical artifact + transport integrity; binds the durable delivery slot/grant `edge_slot (network_scope_id, authenticated_agent_id, spool_id, sequence) -> record_sha256` and IS the physical-slot conflict comparison. NOT a SEMANTIC/event-ledger dedup or projection-conflict key. |
| `semantic_envelope_sha256` | SHA-256 over the frozen versioned field-framed transcript (Appendix A grammar 1: leads with `u64 semanticDigestVersion = 3` and NO string domain tag; FIXED field order with no numeric tags; 8-byte big-endian ints; 8-byte big-endian length prefixes on bytes/string; 1-byte presence markers; `u64` oneof discriminants; field-by-field nested framing; commits `payload_sha256`; excludes the digest field + all delivery state; NO protobuf serialization at any depth) | Runtime-neutral semantic identity; the comparison field for replay vs. conflict. |
| `event_id` (+ contract/domain keys) | UUIDv7 (allocation timing is runtime) | Domain idempotency, merge, projection. Event-ledger identity = `(network_scope_id, event_id)` ONLY; contract-specific domain MERGE keys are separate and are NOT the event-ledger identity. |

`payload_sha256` hashes the exact encoded/compressed payload. Semantic identity
therefore tolerates a differently-encoded outer `EdgeRecordV1` produced
independently by another compliant runtime/producer (recognized as a semantic
replay). `record_sha256` is the physical-slot identity, so a differing
`record_sha256` within one slot is a transport-integrity violation; WHICH
components must forward exact bytes rather than re-encode is runtime. Payload-level
re-encode tolerance would require a contract-specific semantic payload digest.

**Replay vs. conflict** -- the ingest ledger is keyed by `(network_scope_id,
event_id)` ONLY; every other field is a comparison field, never a lookup-key
extension (folding one in turns a conflict into a silent second row):

**Versioned grammars** -- every cryptographic preimage begins with a committed version
integer (and, for the grammars that define one, a leading string domain-separation tag)
committed INTO the hashed bytes (not merely carried alongside on the wire), is validated
fail-closed, and is rejected on an unknown version without trial-hashing other grammars.
Each grammar below is byte-frozen and interoperable only when both languages implement it
byte-for-byte -- the committed version, an optional leading string domain tag, a FIXED
field order (no per-field numeric tags), 8-byte big-endian integer encoding, 8-byte
big-endian length prefixes on bytes/string fields, 1-byte presence markers, `u64` oneof
discriminants, and field-by-field nested framing (no `proto.Marshal` at any depth); a
grammar not pinning all of these is not yet frozen and MUST NOT be relied on for
cross-language identity. Full byte-exact field tables are in Appendix A:

| Grammar | Version | Preimage |
| --- | --- | --- |
| semantic-envelope digest | `semanticDigestVersion = 3` (committed grammar CONSTANT fixed by the record-schema ABI, NOT a wire field) | frozen: NO leading string domain tag; leads with the `u64` version; FIXED field order (no numeric tags); 8-byte big-endian ints; 8-byte big-endian length prefixes on bytes/string; 1-byte presence markers; `u64` oneof discriminants; field-by-field nested framing; NO `proto.Marshal` at any depth |
| capability signing bytes | `capability_version = 1` | frozen: a SINGLE leading str domain `serviceradar.edge.capability.v1` plus a `purpose` field (NOT per-purpose tags); then the `u64` version; FIXED field order; 8-byte big-endian ints; `i64` not_before/expires; 8-byte big-endian length prefixes; the claims message framed field-by-field; EXCLUDES the signature; Ed25519 signs the RAW framed preimage bytes; NO `proto.Marshal` |
| plan / range / recovery content hashes | `PlanDigestVersion = 1` / recovery version `1` | PLAN: the range/page/header preimages CHANGED in this change (`mtr_ordinal_count` added, retired `assignment_epoch` removed), so they are an IMPLEMENTED CANDIDATE, not frozen -- `PlanDigestVersion` stays 1 only because nothing has shipped against them. RECOVERY: task 1.6a has LANDED, and with it the atomic rewrite of the manifest-page and tombstone-scope grammars -- the recovery entries here describe the post-1.6a IMPLEMENTED CANDIDATE. They are still not FROZEN, because task 1.7 is the freeze gate and holds the remaining prerequisites; what no longer applies is "pending 1.6a". DOMAIN-FIRST -- leads with a per-object `str` domain sub-tag (`serviceradar.edge.plan.{range,page,root,header}.v1`, `serviceradar.edge.recovery.{manifest_page,manifest_root}.v1`), THEN the `u64` version; FIXED field order; 8-byte big-endian ints; 8-byte big-endian length prefixes; each excludes its self-hash; NO `proto.Marshal` |
| compiled-assignment body + artifact digests | `CompiledAssignmentDigestVersion = 1` | frozen (Appendix A grammars 9 and 10): TWO grammars under ONE version, each DOMAIN-FIRST with its own `str` tag (`serviceradar.edge.assignment.compiled.body.v1` and `...compiled.artifact.v1`), THEN the `u64` version; FIXED field order (NOT proto tag order); 8-byte big-endian ints; `i64` window bounds; 8-byte big-endian length prefixes. The BODY digest excludes both digest fields AND the capability; the ARTIFACT digest covers the body digest, a 1-byte capability presence marker and, when present, the capability's grammar-2 signing preimage plus its signature. NO `proto.Marshal` |
| MTR completion proof | `MtrCompletionDigestVersion = 2` | **CANDIDATE, NOT FROZEN** -- the leaf `disposition` enum is now DECLARED and both runtimes consume it, and the zero-MTR behaviour is DECIDED (candidate B, the mandatory canonical zero-leaf proof). What still holds this entry short of frozen: ONLY task 1.15's shared per-value leaf vectors. Both previously-undefined plan-derived relations are RESOLVED -- `range_root_sha256` is RETIRED (tag 20, reserved by number and name) in favour of the assignment record's resolvable `target_range_id` + `target_range_sha256`, and the required `SweepMtrExpectationV1` STATES the admitted ordinal count, so "32 zero bytes means none admitted" is written down and checkable in both directions. Otherwise: leads with the `u64` version; each leaf = version, ordinal (`u64`), disposition (`u64`), trace_id (bytes, empty unless TRACE_ALLOCATED), `range_sha256`; three accumulators folded by BIG-endian 256-bit modular addition (mod 2^256), arrival-order-independent, no per-block Merkle/sort; ROOT = `SHA-256(version || expected || plan_root_sha256(32) || mtr_ordinal_range_commitment(32) || content-acc(32))`; NO `proto.Marshal` |

Raw `proto.Marshal` output MUST NOT be a runtime-neutral semantic, signing,
authorization, merge, or logical-content grammar, and there is no decode ->
re-encode -> byte-compare admission and no required whole-record byte equality:
protobuf has no canonical wire form. Protobuf encoding is legitimate wherever the
design produces a PHYSICAL artifact -- the domain body, the `EdgeRecordV1`, and the
`EdgeDeliveryFrameV1` -- plus transport / `proto.Size` / fixtures. WHICH component
produces each artifact, and how many times it encodes, is runtime. Those physical
protobuf artifacts MAY be hashed as explicitly-designated content-addressed
artifacts (`record_sha256` over the exact record bytes, `payload_sha256` over the
exact encoded body), and their NAMED digests MAY participate in transcripts (the
semantic-envelope transcript commits `payload_sha256`). What is forbidden is
placing raw marshalled bytes INSIDE the semantic-envelope, capability-signing, or
plan/range/recovery/completion preimages. Admission is never by decode ->
re-encode -> byte-compare, because protobuf has no canonical wire form and such a
check would reject valid records; `Deterministic` marshalling is a local
reproducibility aid, not a protocol invariant. WHO encodes, fsyncs, or preserves
the bytes end to end is runtime.

SCOPE NOTE: this appendix is frozen EXCEPT where an entry is marked a candidate.
Task 1.6a has LANDED (the recovery manifest-page, tombstone-scope and
RESOLVED-scope entries now describe the IMPLEMENTED CANDIDATE transcript -- landed
is not shipped, and task 1.7 is still what accepts it), and task 1.4's disposition
sub-target is DECLARED. What still holds those entries and the
MTR-completion entry short of frozen is task 1.7, the freeze gate, which carries EVERY
UNCHECKED LOCAL TASK -- currently 1.1, 1.2, 1.3, 1.4, 1.5, 1.6 and 1.15. Earlier
revisions named first only 1.15 and then only 1.3/1.5/1.6/1.15; both understated the
gate, which is why this now states the RULE (all unchecked local tasks) rather than a
list that goes stale as tasks close. The zero-MTR decision is
CLOSED (candidate B), and the plan-derived relations are RESOLVED and verified by
`ValidateAssignmentAgainstPlan` and its Elixir peer -- listing them as a blocker here
was stale. "TombstoneScopeDigest
retired" means the OLD TRANSCRIPT is replaced -- the scope OBJECT itself remains,
and stays in task 1.6's proof inventory; task 1.7 is the freeze gate and
carries those prerequisites explicitly. Reading the appendix title as "everything
here is frozen" would let an implementer pin a grammar this plan already schedules
for atomic rewrite.

Every SIGNING/DIGEST grammar below is byte-frozen and interoperable ONLY when Go
and Elixir implement it byte-for-byte. A grammar that does not pin all of the
common framing rules is not yet frozen and MUST NOT be relied on for
cross-language identity.

### The semantic-envelope transcript is frozen as a GRAMMAR (task 1.5-i)

It is not a ceiling and has no value to freeze, so it is inventoried here with the other
grammars rather than in the bounds tables: what is frozen is the SHAPE of a transcript.

SEVEN KEYED SETS, EACH GUARDED ON ITS OWN, WITH NO GRAND TOTAL, because they count different
proof units -- a root slot is a CLOSURE VIEW over the record, a framer operation is a LEXICAL
WRITE inside one framer, a state case is an ALTERNATIVE branch, a composition edge is a
CALLER-TO-FRAMER occurrence, a separation row is a quantity that must NOT reach the transcript.
Adding them would invent a number that means nothing.

| set | count | what it counts |
| --- | --- | --- |
| `op` | 125 framer-local operations | 89 at a framing seam, 22 through the public digest entry point, 14 discharged via state evidence. Deliberately NOT "every primitive callsite", which would be 138: the root slots contribute 13 direct writes on top |
| `slot` | 17 root slots | version + 12 direct + 4 composite, classified from the descriptor by BOTH consumers; `version` is REUSED evidence from the version corpus, since only Go can parameterise the grammar version |
| `state` | 8 cases, 28 artifacts | includes the ONLY optU64 site (absent / present-zero / present-one), BOTH capability carriers, and each delivery-transition variant POPULATED as well as defaulted |
| `edge` | 13 composition edges | all derived from descriptors and compared BIDIRECTIONALLY |
| `sep` | 5 separation rows | 4 vary a live quantity; 1 is schema closure |
| `excl` | 2 exclusions | field 17 (`self`) and field 18 (`raw`) |
| `rel` | 1 relation | field 18 committed transitively through field 6 |

DESCRIPTOR CLOSURE IS BIDIRECTIONAL AT THREE LEVELS. At the ROOT, fields 1..18 are classified as
{number, name, classification} TUPLES with duplicate numbers rejected -- parsing only the number
lets a duplicate overwrite its predecessor, classifying one field twice and another not at all
while the counts still balance. Across the NINE nested grammar roots, the walk discovers paths
from the DESCRIPTORS and the manifest classifies what was found; deriving the expected paths
from the manifest instead would make the closure agree with itself. And across the COMPOSITION
GRAPH, all thirteen edges are derived -- four from the nested walk, four from the record's
composite slots, five from the claims oneof, whose {field number, child root} pairs are pinned
because those numbers ARE the transcript's discriminant values.

THREE PROPERTIES NEEDED EVIDENCE NOTHING ELSE COULD GIVE:

- ORDER. Per-field inequality cannot see it -- reordering two writes leaves every such row
  green. Committed POPULATED vectors catch it, and at the root an ORDERED SEVENTEEN-CHUNK
  decomposition -- one chunk per direct write, one per composite child's framed output --
  is concatenated and hashed back to the production digest, so the decomposition cannot drift
  from the grammar it describes. Each pair is then exchanged IN PLACE and the COMPLETE preimages
  compared, across every committed variant: comparing `A||B` with `B||A` is unsound, since with
  A="a", a middle M="b" and B="aba" those differ while the full arrangements are both "ababa".
  The single
  base shape's vectors -- `root.shape.base.v0..v2` -- NAME the witness. They are not the only
  KEYS that move: `root.shape.base.v0` shares its value with FIVE `state.*.present` rows --
  `producer_context`, `capability`, `capability@source_auth`, `source_authorization` and
  `output_contract@root` -- which are the same whole-envelope measurement under other names, so
  SIX keys move together. THAT SET IS NOW DERIVED FROM THE COMMITTED VECTORS, not counted here:
  `TestSemanticBaseShapeAliasSetIsExact` and its Elixir peer rebuild it and fail on drift. The
  count had been written out in three places and one still read "four" a review round after the
  fifth row appeared, because no test executed it. What is unique is the
  evidence CLASS: no child vector and no edge row changes at all. It rests on a fixture where every write is distinct
  within its FRAMER TRANSCRIPT, inlined children included, so no two are exchangeable without
  moving a byte.
- CONDITIONAL OMISSION. A populated baseline cannot see it: a framer that skipped zero-valued
  fields would frame the populated case identically and diverge only on defaults. Hence a
  DEFAULT vector per framer, and populated bodies for each delivery-transition variant -- a
  defaulted renewal writes two zero i64s and a defaulted rollover two empty byte strings, so
  swapping either pair is a NO-OP without them.
- PRESENCE, DISCRIMINANTS AND THE OPTIONAL MARKER. Inequality is VACUOUS there: absent and
  present already frame differently for unrelated reasons, and changing a oneof variant also
  changes the branch BODY, so both survive DELETING the marker. Only frozen expected values
  discriminate them.

VALUE DISTINCTNESS IS SCOPED TO THE WHOLE FLAT TRANSCRIPT, because there is no smaller scope.
The preimage is an UNTAGGED CONCATENATION -- no length prefix, no intermediate hash, no framing
around a child block -- so every write coexists with every other, and two writes of the same wire
class carrying the same value are exchangeable without moving a byte. THE WIRE CLASS IS THE
WIDTH: `i64` is `u64(uint64(v))` and `str` is `bytes([]byte(s))`, so those pairs are
indistinguishable and are guarded as one class.

A HELPER IS NOT A BOUNDARY, and two earlier scopes assumed otherwise. Per MESSAGE let
`execution_grant_claims.traffic_class` and its inlined `source_identity.kind` both take 0. Per
HELPER -- after `producerContext` was extracted -- let the root's `traffic_class` and
`producer_context.origin_kind` both take 0, because the extracted helper appends to the SAME
buffer and changed no byte. Composition edges prove ATTACHMENT not POSITION, and the
caller-level chunk guard sees a parent's whole output as ONE chunk, so neither reaches inside.
Only length-framing or hashing child blocks would create a real boundary, and either would
change the ABI. The `producer_context` extraction is retained because it matches the Elixir
peer's existing shape, NOT because it separates anything.

ONE FIXTURE CANNOT SEPARATE THE ROOT, and that is arithmetic. Its transcript carries thirteen
enum writes -- SEVEN with a range of 0..2 -- plus constants at 3, 7 and 8. Seven positions cannot
take seven distinct values from three. So a position's identity is its SIGNATURE, the tuple of
values it takes ACROSS the committed fixtures, and THREE record variants are needed: the record
must avoid the all-equal tuples, which are reserved for the claim baselines (populated once, so
their signatures vary per variant), leaving only six varying tuples per range-3 enum over two
variants against seven positions. TWO POSITIONS COLLIDE ONLY IF THEY AGREE IN EVERY VARIANT OF
THE SHAPE THEY BOTH OCCUR IN -- see the per-shape rule below; an earlier draft asked the question
across the whole fixture set and that was too weak, since a mutation executes inside ONE shape.

EVERY WHOLE-RECORD SHAPE IS A FIXTURE, NOT JUST A RECONSTRUCTION. Byte-for-byte reconstruction
shows the mirror agrees with production for a shape; it says nothing about whether two writes
INSIDE it are exchangeable. Guarding only the base left `payload_family` and `compression` --
both zero in the first variant -- freely swappable whenever the capability carried `collection`,
and the record's `event_id` swappable with a spliced claim's `network_scope_id`. AND NO HAND-PICKED MATRIX
EVER CONVERGES. Five review rounds each found a reordering conditioned on some state no fixture
held -- a claims variant, a carrier, a PAIR of carriers, then a pair the fixtures held but the
guard compared globally -- and each round added the missing case. The space of predicates a
framer COULD branch on is unbounded, so no finite fixture set is complete against it.

SO THE MATRIX IS ENUMERATED FROM THE DECLARED AXES rather than chosen, and it is exhaustive OVER
THOSE AXES: output_contract presence (2), producer_context presence and its optional
authority_epoch (3), the production capability (10 states), and source_authorization (11: absent,
or present with its capability in 10 states) -- 660 shapes plus the base, at three variants, 1983
whole-record vectors of 2029 in all, every one consumed by both runtimes.

`TestSemanticFramingBranchesOnlyOnDeclaredAxes` checks that the framer sources keep the shape
that enumeration assumes: it fails on recognized forms of off-axis control flow, on branchless
selection, and it covers the ROOT function too, not just the `*digestWriter` methods (scoped to
methods, a payload branch in the root passed it).

IT ACCEPTS ANY NIL COMPARISON, WHICH IS ITSELF AN UNDECLARED AXIS. The check asks whether one
side of `==`/`!=` is `nil`; it does not ask WHAT is being compared, so `r.PayloadSha256 != nil`
passes as readily as `c != nil`. Presence of a `bytes` field is not one of the enumerated axes,
so a framer could branch on it and neither the guard nor the matrix would see it. It is a
REGRESSION CHECK, not the thing that makes the matrix complete -- see the limits below.

EXHAUSTIVE OVER THE DECLARED AXES, NOT OVER EVERY PROGRAM THE HOST LANGUAGES CAN EXPRESS. The
cross product covers every combination of carrier presence and oneof discriminant the grammar
declares. It does NOT cover a framer that branches on something else -- and the static guards
that CHECK FOR RECOGNIZED FORMS of that are DEFENSE-IN-DEPTH REGRESSION CHECKS, not a proof. Their known limits, stated
so no reader infers more: the Go guard identifies proto and oneof accessors BY NAME, so a method
spelled `GetClaims` on an unrelated type is accepted; the Elixir guard reads function BODIES and
does not resolve function heads, guards, macro expansions or remote calls, so a two-clause helper
matching `%{projected_row_count: 42}` is invisible to it. Closing that needs a descriptor-validated
declarative grammar that GENERATES both framers, recorded above as an UNOWNED follow-up -- not a second pair
of analyzers chasing two host languages from the outside.

SEPARATION IS ASKED PER SHAPE. A mutation executes inside ONE shape, so a pair must be separated
by a variant OF THAT shape; asked across the whole fixture set, `compression` and a claims
discriminant were both 0 in one shape and swapping them there moved no byte. Two STRUCTURAL
CONSTANTS are exempt -- two carriers holding the same claims kind write the same discriminant by
force of the shape, and a swap confined there changes nothing for any input -- but a pair with a
FIELD on either side never is, because its equality is the fixture's choice. Discriminant 0 and
an absent `optU64`'s forced zero are counted as constants for the same reason.

THE CLAIM BASELINES ARE TWO SETS, PER VARIANT. A spliced baseline's writes land in the record's
own transcript, and the cross product puts a claim body in BOTH carriers at once; splicing one
artifact into both made every corresponding field pair equal, and disjoint VALUES cannot separate
them either -- `production_claims` alone needs three distinct values from fields of range 3, 4
and 3, exhausting the range-3 space for one carrier. Separation is by SIGNATURE across variants.
Measured: one shared set gave 202 collisions, two constant-valued sets still gave 39, per-variant
sets give none.

THE PRIMITIVE INVENTORY IS AN ORDERED MIRROR BOUND BYTE FOR BYTE. Every conclusion above rests on
"these are exactly the writes, in exactly this order", and a width SUM cannot establish that: it
is blind to an equal-width omission paired with an equal-width addition, and to any substitution.
The mirror emits each primitive's exact bytes in transcript order and its concatenation must
EQUAL the preimage the seventeen chunks reconstruct -- itself proven equal to production by
hashing -- for every committed variant, every carrier-absent shape and every composed capability
shape. Presence markers and zero-length writes are excluded from the SIGNATURE guard by name:
they carry no value, and exchanging identical writes is not observable in principle. Presence is
discharged by the `state` rows, which vary it.

THE CARRIER'S OWN DECISIONS NEEDED THEIR OWN ROWS, and neither seam vectors nor attachment edges
supplied them. A seam vector freezes what a framer does when TOLD a carrier is absent; replacing
the root's `c != nil` with a literal `true` was invisible until a whole-record ABSENT witness
existed for each of the four carriers. And the claim bodies and discriminant have vectors, but
neither sees the capability transcript AROUND them, so reordering the claims against the
signature FOR ONE VARIANT the record never carried was invisible until all six composed
capability shapes were framed at the root. Both runtimes consume every committed vector.

VECTORS ARE FROZEN AND BASELINES ARE COMMITTED `.bin` ARTIFACTS read by both runtimes. Within
this grammar it is the only place the two implementations must produce IDENTICAL BYTES for the
same input rather than each merely being internally consistent -- which is how a grammar drifts
apart runtime by runtime with every suite green. Recomputing an expected value with the live
framer would compare the grammar against itself; building a baseline independently in each
runtime would compare two different messages and agree by luck. The Elixir peer carries an
EXACT key-set guard, so a vector cannot be added in Go without it.

RUNTIME SPLIT, HONESTLY BOUNDED. Go exercises its complete signed frame boundary through
`ValidateFrameSigned`, and the `delivery_capability` row asserts the decision moves from FRESH
to RENEWAL -- otherwise "the digest did not move" would be equally true of bytes the validator
ignored entirely. Elixir decodes the same committed artifact and recomputes the inner digest
WITHOUT claiming a frame boundary it does not have. The two runtimes also reach the claim bodies
at different depths: Go calls each framer directly, Elixir only through `claims_framed/1`, so
its adapter slices the discriminant off -- and that prefix is covered by the discriminant
vectors instead, so the gap is closed by a different row rather than left open.

The frame FIELDS are not 1.5-j's; 1.5-j owns broker PUBLICATION IDENTITY, a different object.


### Mutation record (1.5-i)

EXACT, NOT AGGREGATED, AND NOT ONE MEASUREMENT. An earlier draft reported "41 retained" by adding
the first audit's 19 to every survivor round, which DOUBLE-COUNTED: the 19 already contained the
first two rounds. The counts below are the number of test functions that failed, measured, not
remembered -- but they were taken at different times, and the paragraph after the table says
which were re-measured after the staging merge and which carry pre-merge counts. Do not read the
table as a single pass. Overlap is expected and recorded -- one deleted
call can fail rows in several sets.

| mutation | Go rows | Elixir rows |
| --- | --- | --- |
| a framer branches on a payload VALUE (static guard) | 1 | - |
| a framer uses a value `switch` (static guard) | 1 | - |
| a framer uses a loop (static guard) | 1 | - |
| swap `compression` with a claims discriminant in ONE shape | 1 | - |
| reverse `route_profile`/`traffic_class` ONLY for production=`collection` AND nested=`delivery.renewal` | 2 | 1 |
| inline `producerContext` + swap `traffic_class` / `origin_kind` | 4 | - |
| swap `traffic_class` / inlined `source_identity.kind` | 4 | - |
| swap root `route_profile` / `traffic_class` | 6 | - |
| move `producer_context` after `route_profile` | 15 | - |
| `producer_context.origin_kind` -> `run_shard` | 18 | - |
| swap `capability` / `source_auth` blocks | 15 | 7 |
| NESTED CARRIER frames renewal timestamps swapped | 3 | - |
| NESTED CARRIER frames assignment identity ids swapped | 3 | - |
| drop `producer_context` from the chunk decomposition | 2 | - |
| `outputContract(c, c != nil)` -> `(c, true)` | 2 | 3 |
| nested `sourceAuth` capability presence -> `true` | 4 | - |
| reorder claims / signature ONLY for `collection` | 2 | 1 |
| reorder claims / signature ONLY when claims unset | 2 | 1 |
| swap `payload_family` / `compression` ONLY for `collection` | 1 | 1 |
| the same swap ONLY when `output_contract` is absent | 1 | 1 |
| `collection`-only root `event_id` / claim `network_scope_id` | 1 | - |
| every shape vector checked at variant 0 only | consumption guard | - |
| Elixir shape loop restricted to variants 0-1 | - | consumption guard |
| drop the read-guard scanner buffer | scan error | - |
| mirror omits the capability `signature` write | 1 | - |
| split `u64`/`i64` wire classes in the mirror | 1 | - |
| widen the capability oneof exception | 1 | - |
| drop the `IsSynthetic` half of that predicate | 1 | - |
| delete the schema-scan recursion | 1 | - |
| swap claims discriminants 9 and 11 | 1 | - |
| stop deriving root composition edges | 1 | - |
| manifest: slot `01.event_id` direct -> composite | 1 | 1 |
| manifest: excl 17 `self` -> `raw` | 1 | 1 |
| manifest: rel `transitive` -> `direct` | 1 | 1 |
| manifest: rename one `edge` key | 2 | 1 |
| manifest: rename one `state` key | 1 | 1 |
| manifest: rename one `op` key | 2 | **0, Go owns it** |
| Elixir: swap renewal `not_before` / `expires` | - | 2 |
| Elixir: swap rollover `recovery_id` / `prior_spool_id` | - | 2 |
| vectors: append a duplicate key | - | 14 |

FORTY ROWS HERE, PLUS SEVEN LATER PROBES BELOW -- 47 in all. The two NESTED-CARRIER rows were
dropped from the table while the paragraph below went on citing them among the re-measured
thirteen; they are restored with their post-merge counts rather than the citation being removed,
because they are the rows that closed the second capability carrier. The first audit's nineteen
are NOT re-added and are NOT reproduced anywhere in this document: they were reported in the
review round that ran them and are not recoverable from this table. Saying they are "recorded
separately above" was wrong. The survivor rounds are represented by the rows that now kill them
rather than by a count. The counts are the number of test functions that failed -- measured, not
remembered.

WHAT WAS RE-MEASURED WHEN, STATED PLAINLY -- THIS TABLE IS NOT ONE PASS. It was measured in one
pass before staging was merged. After the merge, THIRTEEN rows were re-run: the seven survivors
review rounds reported (the shape-local `compression`/discriminant swap, the paired
`route_profile`/`traffic_class` reversal, both nested-carrier swaps, the `outputContract` presence
literal, and the two claims/signature reorderings), the three static-guard rows, and three
controls named here rather than left as a category -- `move producer_context after route_profile`,
`swap capability / source_auth blocks`, and `mirror omits the capability signature write`. All
thirteen still kill and the counts above are the post-merge figures for those; the remainder carry
their pre-merge counts. The merge touched staging's code, not this grammar or its suite,
but that is a reason to expect the rest to hold, not evidence that they do.

THE ROWS ADDED SINCE, all measured: the presence-argument bypass
(`d.outputContract(c, c != nil && r.GetProjectedRowCount() != 42)`, 1 row), a helper computing
that flag (2), a helper hiding a branch behind a returned value (1), BRANCHLESS SELECTION via
`map[bool][2]uint64{...}[x == 42]` (4), and on the Elixir side the same predicate as an `if` (2),
as a local two-clause helper (2), and behind a remote call (1).

THREE ROWS FAIL THROUGH A GUARD RATHER THAN A TEST FUNCTION, and the table says which. Restricting
the shape vectors to fewer variants leaves every assertion green and is caught by the
after-the-run check that every committed vector was actually READ -- once per runtime. Dropping
the read guard's scanner buffer is caught by its error check, and is only OBSERVABLE with an
over-long row present, which is the condition it was measured under: with the buffer intact that
row is reported unread; with it removed the scan error is reported instead. Without either, an
over-long line silently truncated the scan and every remaining key counted as read.

THE CONSUMPTION GUARD ALSO FIRES ALONGSIDE A GENUINE FAILURE, because a failing test aborts
before reading the rest. The test-failure count is the primary signal and the guard is recorded
next to it rather than smoothed away. ONE ROW MEASURES ZERO IN ELIXIR BY DESIGN, and the table
says which runtime kills it: Go owns the 125-key `op` closure, and restating those leaf paths in
the peer would be duplication, not independent evidence.



### Common framing rules

These rules apply to every grammar (1-10) at every nesting depth and match the reference
`digestWriter` primitives byte-for-byte (semantic.go:41-138; uniform across
semantic/capability/plan/recovery/MTR), so two clean-room Go/Elixir implementations
produce IDENTICAL bytes:

- The preimage is an ordered concatenation of framed values. There are NO per-field
  numeric tags -- field identity is FIXED ORDER, not a tag number.
- version leads: a `u64` written as 8 BIG-endian bytes, FIRST. (For a grammar that
  carries a string domain, the domain `str` is written first, then the version `u64`.)
- `u64` / enum: 8-byte BIG-endian (an enum is its numeric value widened to `u64`).
- `i64`: 8-byte BIG-endian two's-complement (the int64 reinterpreted as `u64`; NO zigzag).
- `bytes` / `str`: an 8-byte BIG-endian length prefix, then the raw bytes (`str` is
  UTF-8). The length prefix is 8 bytes, NOT 4.
- presence: a 1-byte marker `0x00` / `0x01` written before an optional value.
- `optU64`: the presence byte (1 byte) then the `u64` (8 bytes) -- the value is ALWAYS
  written (0 when absent).
- oneof discriminant: a `u64` (8-byte BIG-endian) equal to the set member's field number
  (0 for none), then the set member framed field-by-field.
- nested message: framed FIELD-BY-FIELD by these same rules (NOT a `proto.Marshal` blob).
- digest: SHA-256 over the full preimage -> the 32 raw bytes (`finish`).
- MSet 256-bit modular add (MTR accumulators): BIG-endian (`a[0]` most-significant); sum
  each of the 32 bytes with carry flowing toward index 0; discard the final carry
  (mod 2^256).
- text headers: `Nats-Msg-Id` and `Sr-Edge-Delivery-Id` are base64url(no-pad) of the
  SHA-256 digest; `Sr-Edge-Transport-Provenance` is base64url(no-pad) of the framed
  envelope ITSELF (not a digest of it).

The version -- and, where used, the leading string domain tag -- is committed INSIDE the
hashed/signed preimage (never merely carried alongside on the wire); an unknown version is
rejected fail-closed without trial-hashing any other grammar. Unknown protobuf fields are
rejected BEFORE hashing: a record carrying an unknown field in any grammar-covered
position is rejected fail-closed, never silently included or skipped. `proto.Marshal`
output MUST NOT appear in any preimage at any depth (task 1.13 REPLACED the last
`msg()` = `bytes(proto.Marshal(m))` uses -- the `output_contract` ref and the leaf claim
messages -- with field-by-field framing).

### Appendix A: Grammars

Each grammar states its committed version + current numeric value (and, where the grammar
defines one, its leading string domain tag in exact ASCII), covered fields in EXACT ORDER
with explicit exclusions, and any grammar-specific notes; the common framing rules above
apply throughout. Digest algorithm: SHA-256 for every grammar. Every nested message
(output_contract, all claim messages, the delivery transition oneof, plan ranges/pages/
root/header, recovery manifest-page/tombstone/resolved) is framed FIELD-BY-FIELD per its
table below with recursive framing; `proto.Marshal` appears in NO preimage at any depth
(landed in task 1.13).

PRESENCE MARKERS are NOT universal, and an earlier revision of this paragraph wrongly gave
every nested message one. Two forms exist:
 - An OPTIONAL nested message carries an explicit 1-byte presence marker (`output_contract`,
   `producer_context`, the sourceAuth and capability sub-frames, and
   `EdgeAssignmentExecutionClaimsV1.source_identity`, and
   `CompiledSweepAssignmentV1.collection_capability` inside the grammar-10 artifact digest).
 - A ONEOF member carries NO extra marker: the `u64` DISCRIMINANT IS the presence signal,
   with 0 meaning none. This applies to the capability `claims` oneof and the delivery
   `transition` oneof. Adding a marker beside the discriminant would be a second, redundant
   encoding of the same fact -- and the reference implementations do not emit one.

ORDERING RULE (frozen, with the exceptions the #4713 code has): a TAGGED grammar emits its
`str` domain tag FIRST, then the `u64` version (domain-tag-first, version-second) --
capability-signing (`serviceradar.edge.capability.v1`), `Nats-Msg-Id`, `Sr-Edge-Delivery-Id`,
`Sr-Edge-Transport-Provenance`, and (landed in task 1.13) the per-object plan/recovery
sub-tags. EXCEPTIONS (explicit): (a) the semantic-envelope digest is version-first with NO
domain tag (`semanticDigestVersion = 3`); (b) the MTR internal elements -- the leaf is
version-first with NO sub-tag; the ordinal element is version then `str
"mtr-completion-ordinal"`; the member element is version then `str "mtr-completion-member"`.

Two former #4713 bugs, FIXED by task 1.13, are noted inline below: (i) EdgeDeliveryClaimsV1's
`transition` oneof was formerly whole-message `proto.Marshal`'d and is now field-framed
(u64 discriminant + framed member); (ii) the capability claims-oneof binding was formerly
bound TWO different ways and is now UNIFIED (both commit the u64 field-number discriminant
7/8/9 -- later extended with 11 and 12 -- and the signing preimage additionally
commits `purpose`).

1. Semantic-envelope digest -- NO string domain tag; leads with `u64
   semanticDigestVersion = 3`. Ordered fields (semantic.go:147-188): `version` (u64 = 3);
   `event_id` (bytes); `payload_family` (u64/enum); `compression` (u64/enum);
   `encoded_size` (u64); `uncompressed_size` (u64); `payload_sha256` (bytes);
   `output_contract` (presence (1B) + EdgeOutputContractRef framed FIELD-BY-FIELD (NOT
   `proto.Marshal`): `contract_id` (str), `contract_version` (u64),
   `contract_bundle_sha256` (bytes), `registry_epoch` (u64), `registry_snapshot_sha256`
   (bytes), `effective_grant_sha256` (bytes)); `producer_context` (presence (1B); if present:
   `origin_kind` (u64), `origin_principal_id` (bytes), `producer_instance_id` (bytes),
   `producer_assignment_id` (bytes), `run_id` (bytes), `run_shard` (u64),
   `authority_epoch` (optU64), `scope_id` (bytes), `scope_sha256` (bytes), `package_id`
   (str), `package_sha256` (bytes)); `route_profile` (u64); `traffic_class` (u64);
   `network_scope_id` (bytes); `production_capability` (capability sub-framing, below);
   `source_authorization` (sourceAuth sub-framing, below); `projected_row_count` (u64);
   `projected_write_bytes` (u64); `cost_model_version` (u64). EXCLUDES
   `semantic_envelope_sha256` and ALL delivery state (`spool_id`, sequence,
   `record_sha256`, delivery capability, headers). There is NO `semantic_digest_version`
   wire field -- the `= 3` is a committed grammar constant fixed by the record-schema ABI.
   - capability sub-framing (semantic.go:88-118; used INSIDE the envelope and DISTINCT
     from the capability SIGNING grammar 2): presence (1B); if present: `capability_version`
     (u64), `issuer_id` (bytes), `issuer_key_id` (bytes), `algorithm` (str), `not_before`
     (i64), `expires` (i64), claims-oneof discriminant (u64 = the member's field number:
     7 = production / 8 = source / 9 = delivery / 11 = collection /
     12 = assignment_execution / 0 = none) + the FIELD-FRAMED claim message
     (per the claim-message tables below, field-by-field, NOT `proto.Marshal`),
     `signature` (bytes). The ENVELOPE framing has NO domain tag and NO purpose field and
     DOES include the signature; the SIGNING grammar 2 is different.
   - sourceAuth sub-framing (semantic.go:120-133): presence (1B); if present: `kind`
     (u64), `capability` (capability sub-framing), `context_id` (bytes), `scope_id`
     (bytes), `scope_sha256` (bytes).
   - claim-message tables (the oneof members; framed field-by-field, in order):
     - EdgeProductionClaimsV1 (field number 7; fields 1-23 in order): `contract_id` (str),
       `contract_version` (u64), `contract_bundle_sha256` (bytes), `registry_epoch` (u64),
       `network_scope_id` (bytes), `producer_assignment_id` (bytes), `traffic_class` (u64),
       `route_profile` (u64), `origin_kind` (u64), `origin_principal_id` (bytes),
       `producer_instance_id` (bytes), `run_id` (bytes), `run_shard` (u64),
       `authority_epoch` (u64), `scope_id` (bytes), `scope_sha256` (bytes),
       `package_sha256` (bytes), `registry_snapshot_sha256` (bytes),
       `effective_grant_sha256` (bytes), `max_projected_row_count` (u64),
       `max_projected_write_bytes` (u64), `cost_model_version` (u64), `package_id` (str).
     - EdgeSourceClaimsV1 (field number 8; fields 1-18 in order): `kind` (u64),
       `context_id` (bytes), `scope_id` (bytes), `scope_sha256` (bytes),
       `network_scope_id` (bytes), `collection_not_before_unix_nano` (i64),
       `collection_expires_unix_nano` (i64), `origin_principal_id` (bytes),
       `producer_instance_id` (bytes), `producer_assignment_id` (bytes), `run_id` (bytes),
       `run_shard` (u64), `authority_epoch` (u64), `traffic_class` (u64), `route_profile`
       (u64), `execution_plan_sha256` (bytes), `target_range_sha256` (bytes), `origin_kind`
       (u64).
     - EdgeCollectionClaimsV1 (field number 11; fields 1-11 in order): `purpose`
       (u64/enum, MUST be COLLECTION), `network_scope_id` (bytes),
       `authenticated_agent_id` (bytes), `execution_plan_id` (bytes), `target_range_id`
       (bytes), `execution_shard` (u64), `assignment_epoch` (u64),
       `compiled_assignment_body_sha256` (bytes), `traffic_class` (u64/enum),
       `producer_assignment_id` (bytes), `execution_id` (bytes).
       NOTE: field number 11, NOT 10 -- `signature` holds 10 on the envelope. The
       committed digest is the carrier's BODY digest, never its artifact address: the
       artifact address covers this capability, so signing it would require the
       signature to cover itself.
     - EdgeAssignmentExecutionClaimsV1 (field number 12; fields 1-19 in order): `purpose`
       (u64/enum, MUST be ASSIGNMENT_EXECUTION), `network_scope_id` (bytes),
       `authenticated_agent_id` (bytes), `producer_assignment_id` (bytes), `execution_id`
       (bytes), `run_id` (bytes), `run_shard` (u64), `authority_epoch` (u64),
       `production_scope_id` (bytes), `scope_sha256` (bytes), `contract_bundle_sha256`
       (bytes), `execution_plan_sha256` (bytes), `target_range_sha256` (bytes),
       `traffic_class` (u64/enum), `collection_not_before_unix_nano` (i64),
       `collection_expires_unix_nano` (i64), `source_identity` (presence (1B); if present:
       `kind` (u64/enum), `context_id` (bytes), `source_scope_id` (bytes),
       `source_scope_sha256` (bytes)), `compiled_assignment_id` (bytes),
       `compiled_assignment_sha256` (bytes).
       NOTE: fields 18-19 are framed AFTER the nested `source_identity` at 17 -- the
       grammar is FIELD ORDER, and the nested member does not move to the end.
     - EdgeDeliveryClaimsV1 (field number 9; fields 1-4 + a `transition` oneof):
       `event_id` (bytes), `record_sha256` (bytes), `spool_id` (bytes), `sequence` (u64),
       then the `transition` oneof: a u64 discriminant (5 = renewal, 6 = rollover, 0 = none)
       + the FIELD-FRAMED member. EdgeDeliveryRenewalV1 (member 5):
       `renewed_not_before_unix_nano` (i64), `renewed_expires_unix_nano` (i64).
       EdgeDeliveryRolloverV1 (member 6): `recovery_id` (bytes), `prior_spool_id` (bytes),
       `prior_sequence` (u64).
       >>> FIXED in #4713 (task 1.13): EdgeDeliveryClaimsV1's `transition` oneof was
       formerly whole-message `proto.Marshal`'d (semantic.go `msg()`), reintroducing the
       protobuf-go oneof-order hazard one level down. It is now FIELD-FRAMED (u64
       discriminant + framed member) exactly as tabulated above.
2. Capability SIGNING bytes -- domain `str "serviceradar.edge.capability.v1"` FIRST, then
   the `u64` version (domain-tag-first, version-second). Ordered (capability.go:106-121):
   `domain` (str); `capability_version` (u64); `issuer_id` (bytes); `issuer_key_id`
   (bytes); `algorithm` (str); `purpose` (u64/enum EdgeCapabilityPurpose = UNSPECIFIED 0 /
   PRODUCTION 1 / SOURCE 2 / DELIVERY 3 / COLLECTION 4 / ASSIGNMENT_EXECUTION 5); `not_before` (i64); `expires` (i64); `claims` (the set claim message
   framed FIELD-BY-FIELD per the grammar-1 claim-message tables [field-framed in #4713,
   not `proto.Marshal`]). EXCLUDES the signature. Ed25519 signs this RAW framed preimage bytes
   DIRECTLY (NOT a SHA-256 of them). A single domain tag plus a `purpose` field bind the
   role -- there is ONE domain `.capability.v1`, NOT per-purpose tags.
   >>> FIXED in #4713 (task 1.13): the claims-oneof variant was formerly bound TWO different
   ways -- the signing preimage via the `purpose` enum, the grammar-1 capability() sub-framing
   via the 7 / 8 / 9 field-number discriminant. UNIFIED: BOTH now commit the u64 field-number
   discriminant (7 / 8 / 9, plus 11 COLLECTION and 12 ASSIGNMENT_EXECUTION), and the
   signing preimage ADDITIONALLY commits `purpose`; and BOTH field-frame the claim member
   (no `proto.Marshal`). A claims variant with NO framing case emits discriminant 0 AND
   purpose 0, which signs a preimage no verifier accepts -- adding a variant therefore
   REQUIRES adding both its framing case and its purpose value.
3. Source authorization -- NOT a second signed object: the source CAPABILITY is signed
   via grammar 2 with `purpose = SOURCE`; the outer `EdgeSourceAuthorizationV1` (`kind` /
   `context_id` / `scope_id` / `scope_sha256`) is covered by the semantic envelope's
   sourceAuth sub-framing (grammar 1). Service-ingress records use `service_slot =
   (network_scope_id, authenticated_service_id, publication_lane_id, publication_sequence)`
   in the delivery transcripts (grammars 6-8) instead of spool coordinates.
4. Plan / recovery SELF-HASH digests (plan.go / recovery.go) -- each preimage leads with a
   per-object `str` DOMAIN TAG (domain-first, like grammar 2's capability domain), THEN the
   version, THEN its fields (excluding its own self-hash). Previously all shared
   `u64 version = 1` with no tag, so digests were distinguished only by field structure;
   the frozen tags now make a digest of one object type unable to equal a digest of another:
   `serviceradar.edge.plan.range.v1` / `.plan.page.v1` / `.plan.root.v1` / `.plan.header.v1`;
   `serviceradar.edge.recovery.manifest_page.v1` / `.recovery.manifest_root.v1`. Exact field
   orders (each EXCLUDES its self-hash):
   - RangeDigest (plan.go, excl `range_sha256`): `str "serviceradar.edge.plan.range.v1"`,
     `version` (u64), `range_id` (bytes), `cidr` (str), `first_address` (str), `last_address`
     (str), `target_count` (u64), `check_set_sha256` (bytes), `availability_policy_id`
     (bytes), `mtr_admission_budget` (u64), `mtr_ordinal_count` (u64).
     PRESENCE-MARKER EXCEPTION, stated because Appendix A's general rule gives every
     `optional` field a 1-byte marker: `mtr_ordinal_count` is hashed as a BARE u64 with
     NO marker, so an absent count hashes identically to an explicit zero. That
     collision is tolerable ONLY because absence is REJECTED BEFORE ADMISSION -- note
     the ordering: `RangeDigest` will happily hash an absent count as 0, and it is
     `PlanMtrWindows` that refuses the range afterwards, so no absent-count plan is ever
     admitted even though one can be hashed. The proto keeps `optional` solely so the
     validator can tell absent from zero. An implementation that hashes without
     validating would NOT be protected by the digest here.
   - PlanPageDigest (plan.go, excl `page_sha256`): `str "serviceradar.edge.plan.page.v1"`,
     `digest_version` (u64), `execution_plan_id` (bytes), `page_index` (u64), `page_count`
     (u64), `prev_page_sha256` (bytes), `check_set_sha256` (bytes), `len(ranges)` (u64), then
     EACH range inlined in order (`range_id`, `range_sha256`, `cidr`, `first_address`,
     `last_address`, `target_count`, `check_set_sha256`, `availability_policy_id`,
     `mtr_admission_budget`, `mtr_ordinal_count` -- the page commits each range's
     `range_sha256`, unlike RangeDigest itself).
   - PlanRoot (excl `plan_root_sha256`): `str "serviceradar.edge.plan.root.v1"`, `version`
     (u64), `len(pages)` (u64), then each `page_sha256` (bytes) in order.
   - PlanHeaderDigest (excl `execution_plan_sha256`): `str "serviceradar.edge.plan.header.v1"`,
     `digest_version` (u64), `execution_plan_id` (bytes), `page_count` (u64),
     `total_target_count` (u64), `plan_root_sha256` (bytes), `check_set_sha256` (bytes),
     `availability_policy_id` (bytes), `network_scope_id` (bytes),
     `mtr_ordinal_range_commitment` (bytes). NOTE: `assignment_epoch` (tag 9) is RETIRED
     and is NOT hashed -- an immutable plan must not commit a value that reassignment
     advances without changing the plan.
   - MTR ORDINAL WINDOWS (frozen derivation, not a digest). Each plan range owns one
     CONTIGUOUS plan-global window. The offset is the PREFIX SUM of `mtr_ordinal_count`
     over the ranges that PRECEDE it in plan order -- pages by ascending `page_index`,
     ranges in their committed order within a page. The first range's offset is 0.
     A range's window commitment is the additive multiset fold of
     `mtrMemberHash(offset + i, range_sha256)` for i in 1..`mtr_ordinal_count`, and the
     plan-wide `mtr_ordinal_range_commitment` is the additive SUM of every range's
     window commitment. Completion-leaf ordinals remain LOCAL (`{1..count}`); ONLY the
     membership accumulator is shifted by the offset. Without this derivation frozen, a
     clean-room implementation would produce different windows from the same plan.

     GRAMMAR VERSION: these entries change the v1 preimages. `PlanDigestVersion` stays 1
     because the plan grammar is an UNSHIPPED CANDIDATE -- no producer emits it and no
     fixture predates this change. Any later edit, once shipped, is a version bump.
   - **RETIRED — replaced atomically by task 1.6a, which has LANDED.** The
     ManifestPageDigest entry below hashes the `lost_ranges` + `affected` pair,
     which 1.6a replaced with ONE ordered `classification_spans` list. Nothing had
     shipped against it; 1.6a rewrote this transcript, the page/manifest messages,
     every `recovery_grammar_version = 1` reference, both runtimes' validators, and
     all fixtures together. Do NOT implement against the entry below: its
     `coarsened` marker and its `lost_ranges`/`affected` arrays are all RETIRED, and
     THE TARGET TRANSCRIPT IS FROZEN in the `edge-producer-data-plane`
     classification-span requirement.
   - ManifestPageDigest (recovery.go, excl `page_sha256`): `str
     "serviceradar.edge.recovery.manifest_page.v1"`, `digest_version` (u64), `recovery_id`
     (bytes), `page_index` (u64), `page_count` (u64), `prev_page_sha256` (bytes), `terminal`
     (bool as 1-byte marker (0x00/0x01)), `coarsened` (bool as 1-byte marker (0x00/0x01)),
     `len(lost_ranges)` (u64) + each EdgeLostRangeV1 (`from_sequence` (u64), `through_sequence`
     (u64)), `len(affected)` (u64) + each EdgeAffectedScopeV1 (`from_sequence` (u64),
     `through_sequence` (u64), `contract_bundle_sha256` (bytes), `producer_assignment_id`
     (bytes), `run_id` (bytes), `run_shard` (u64), `authority_epoch` (u64), `scope_sha256`
     (bytes), `range_sha256` (bytes), `coarsened` (bool as 1-byte marker (0x00/0x01))).
   - ManifestRoot (excl `manifest_root_sha256`): `str
     "serviceradar.edge.recovery.manifest_root.v1"`, `version` (u64), `len(pages)` (u64),
     then each `page_sha256` (bytes) in order.
   The recovery-OPERATION SCOPE digests are a SEPARATE family (recovery.go): a signed
   recovery source grant's `scope_sha256` MUST equal one of them. Each leads with
   `u64 RecoveryScopeDigestVersion = 1` THEN a `u64` body-kind discriminant (0 = tombstone,
   1 = manifest page, 2 = resolved) -- NOT a string domain tag. SpoolLossTombstoneV1 and
   RecoveryResolvedV1 have NO self-hash field, so these scope digests (not a self-hash) are
   their only grammar:
   - TombstoneScopeDigest (body kind 0) -- the members below are the PRE-1.6a
     transcript, retained only to show what changed. Task 1.6a (LANDED) REMOVED
     `lost_from_sequence`, `lost_through_sequence`, and `coarsened`, because with
     gaps legal the manifest min/max is not the loss and a SIGNED interval would be
     an authenticated second source of truth. THE TARGET TRANSCRIPT IS FROZEN in the
     classification-span requirement -- `u64(version) u64(0) bytes(recovery_id)
     bytes(prior_spool_id) bytes(new_spool_id) bytes(manifest_root_sha256)
     u64(manifest_page_count)` -- and is not restated here. Members: `version` (u64), `0` (u64), `recovery_id` (bytes),
     `prior_spool_id` (bytes), `new_spool_id` (bytes), `lost_from_sequence` (u64),
     `lost_through_sequence` (u64), `manifest_root_sha256` (bytes), `manifest_page_count`
     (u64), `coarsened` (bool as 1-byte marker (0x00/0x01)). It does NOT cover `reason`,
     `detected_at_unix_nano`, or `digest_version` -- those are validated separately and are
     not part of the authorized scope.
   - ManifestPageScopeDigest (body kind 1): `version` (u64), `1` (u64), `recovery_id`
     (bytes), `page_sha256` (bytes).
   - ResolvedScopeDigest (body kind 2): `version` (u64), `2` (u64), `recovery_id` (bytes),
     `manifest_root_sha256` (bytes), `applied_through_sequence` (u64) -- task 1.6a
     (LANDED) fixed this scalar as the consumer's durably applied CONTIGUOUS PREFIX
     over the allocated sequence space (not the maximum span end); with gaps legal
     those differ, and the value gates journal release.
   Go and Elixir (`ServiceRadar.Edge.HashGrammar`) reproduce every self-hash AND scope digest
   byte-for-byte; the committed testdata (`tombstone_scope.bin` / `manifest_page_scope.bin` /
   `resolved_scope.bin` + the plan/manifest `*.bin`) are the cross-language vectors.
5. MTR completion proof -- `u64 MtrCompletionDigestVersion = 2`. The leaf
   `disposition` IS the generated `MtrCompletionDisposition` enum (task 1.4's
   disposition sub-target, landed):
   it is declared once in `proto/edge/v1/sweep.proto`, Go's `MtrTerminalDisposition`
   is a type alias of it, and Elixir's guards read it through compile-time module
   attributes, so this framing now DOES describe the code and it supersedes #4713's
   local declarations. STILL CANDIDATE for reasons that are NOT the enum and NOT
   zero-MTR (decided: candidate B, implemented in both runtimes): task 1.15 owes the
   shared per-value leaf vectors. That is the ONLY remaining reason. The plan-derived
   relations are NOT unverifiable -- an earlier revision said so and was wrong: the
   assignment carrier EXISTS (`SweepAssignmentRecordV1`), and
   `ValidateAssignmentAgainstPlan` plus its Elixir peer VERIFY them today by
   recomputing the expectation from committed plan data, over a plan each runtime
   validates first. Framing below
   (domain.go:706-847):
   - leaf element (`mtrLeafHash`): `version` (u64 = 2), `ordinal` (u64), `disposition`
     (u64, the generated enum's int32 widened to u64 -- zero, negative and
     unknown-positive values are rejected BEFORE the widening, so no unrecognised
     number reaches the preimage), `trace_id` (bytes, empty unless TRACE_ALLOCATED),
     `range_sha256` (bytes). NO string sub-tag on the leaf. SHA-256 -> 32-byte point.
   - ordinal element (`mtrOrdinalHash`): `version` (u64 = 2), `str
     "mtr-completion-ordinal"`, `ordinal` (u64). SHA-256 -> point.
   - member element (`mtrMemberHash`): `version` (u64 = 2), `str "mtr-completion-member"`,
     `ordinal` (u64), `range_sha256` (bytes). SHA-256 -> point.
   - three accumulators fold by BIG-endian 256-bit modular add (mod 2^256): `acc` (leaf),
     `ordinalAcc`, `memberAcc`.
   - ROOT (domain.go:840-846) = `SHA-256( version (u64 = 2) || expected (u64) ||
     plan_root_sha256 (bytes, 32) || mtr_ordinal_range_commitment (bytes, 32) || acc
     (bytes, 32) )`. `plan_root_sha256` IS committed in the root; `ordinalAcc` and
     `memberAcc` are GATES, not hashed into the root.
   - gates (domain.go:821-838): `len(plan_root_sha256) == 32` && `len(commitment) == 32`;
     `count == expected`; `ordinalAcc ==` the big-endian add of `mtrOrdinalHash(i)` for
     `i in 1..expected`; `memberAcc == mtr_ordinal_range_commitment`.
   - empty (`expected == 0`, the plan admits NO MTR targets) -- DECIDED: candidate (B),
     a MANDATORY canonical zero-leaf proof. A COMPLETED event ALWAYS carries a proof;
     the zero-MTR one is `expected = 0`, no leaves, all three 32-byte accumulators the
     zero value, and the ordinary root framing still bound to `plan_root_sha256`. The
     plan's `mtr_ordinal_range_commitment` (`ScheduledPlanHeaderV1` field 11) is 32 ZERO
     bytes -- the empty-set multiset hash -- and NEVER empty bytes. Candidate (A) (no
     proof required) was REJECTED: it admitted both an absent and a present proof for
     one state and rested the choice on a producer-reported counter. The gates above
     already yield this for free -- `count == expected` holds at 0, the canonical
     ordinal fold over an EMPTY range is the zero accumulator, and `memberAcc ==
     commitment` compares zero32 to zero32 -- which is why (B) needed no new framing.
     NOTE for implementers: Go's `for i := 1; i <= expected; i++` is naturally empty at
     0, but Elixir's `1..0` is a DESCENDING range that iterates `[1, 0]`; the canonical
     fold uses `1..expected//1` so the range is empty exactly when there is nothing to
     cover. Without the step, every valid zero-MTR proof is rejected.
   - terminal disposition values (the u64) -- `MtrCompletionDisposition`,
     DISTINCT from the per-hop `MtrOutcome` enum:
     the members and numbers frozen by the requirement "MTR completion disposition is one
     generated enum". DECLARED (task 1.4): the enum now exists ONCE in
     `proto/edge/v1/sweep.proto` (full symbols `MTR_COMPLETION_DISPOSITION_*`), and Go and
     Elixir are CONSUMERS, not co-owners -- Go's `MtrTerminalDisposition` is an ALIAS of the
     generated type and Elixir's completion guards read the generated values through module
     attributes. The earlier audit finding -- that calling this FROZEN while it existed only
     as a Go `iota` block and Elixir integer guards was an overstatement -- is closed: a
     renumbering in the proto now fails both runtimes' closed-set tests without either
     runtime being edited. The number is hashed into the frozen leaf preimage, which is why
     two hand-maintained copies could produce two roots for one completion. STILL OPEN for
     1.15: the SHARED cross-language leaf vectors, which are NOT "per value" -- VALID vectors
     for `1..5`, and REJECT vectors for `0`, `-1`, `6`, and `999` -- zero is rejected before
     hashing, so an accepted vector for it would contradict the rule. (Each runtime already
     asserts that reject/accept set against its own generated enum; what 1.15 adds is the
     shared fixture both read.) Do NOT reuse the per-hop `MtrOutcome` numbering (`REACHED = 1`,
     `PROBE_FAILED = 3`, `NOT_ADMITTED = 5`, `QUARANTINED = 6`, `SCHEDULER_LOST = 7`) --
     they are a different enum. This SUPERSEDES #4713's local declarations, which the
     generated enum replaces (see the
     restack/implementation prerequisite in tasks.md).
6. `Nats-Msg-Id` transcript -- string domain `serviceradar.edge.msgid` FIRST, then
   `version` (u64 = 1), then the 6 fields in order: `authenticated_agent_id` (bytes),
   `network_scope_id` (bytes), `spool_id` (bytes), `sequence` (u64),
   `semantic_envelope_sha256` (bytes), `record_sha256` (bytes). SHA-256 -> base64url
   header. There is NO `lane_id`: `spool_id` is the persistent UUIDv7 for one delivery lane
   (#4713), so a lane id is neither carried nor derived from nonce/route/class. There is NO
   separate origin-principal input: `authenticated_agent_id` is the authenticated
   component-id principal (see the principal-encoding rule below) and MUST equal
   `producer_context.origin_principal_id`. (This is the frozen 6-field list; any disagreeing
   field list elsewhere reconciles to THIS.) Service-ingress variant: domain
   `serviceradar.edge.msgid.service`, fields = `authenticated_service_id`,
   `network_scope_id`, `publication_lane_id`, `publication_sequence`,
   `semantic_envelope_sha256`, `record_sha256` (the `service_slot` in place of the spool
   coordinates).
7. `Sr-Edge-Delivery-Id` transcript -- string domain `serviceradar.edge.delivery-id`,
   `version` (u64 = 1), the frozen `edge_slot` tuple fields (`network_scope_id`,
   `authenticated_agent_id`, `spool_id`, `sequence`). NOT `record_sha256` (the slot binding
   stores `record_sha256` as a compared value instead). SHA-256 -> base64url header.
   Service-ingress variant: domain `serviceradar.edge.delivery-id.service`, the
   `service_slot` tuple.
8. `Sr-Edge-Transport-Provenance` envelope -- string domain
   `serviceradar.edge.transport-provenance`, `version` (u64 = 1), then: `slot_kind`
   discriminant (u64: `0 = UNSPECIFIED` [reject], `1 = EDGE`, `2 = SERVICE_INGRESS`); the
   slot tuple fields for that kind (`edge_slot` or `service_slot`); `record_sha256` (bytes);
   `delivery_proof` -- presence byte (`0x00` = absent, `0x01` = present) and, when present,
   EXACTLY one 32-byte `digest` framed as `0x01` then the u64 length prefix (`= 32`) then the
   32 digest bytes [the digest is over the delivery capability's grammar-2 signing bytes with
   `purpose = DELIVERY`, NOT its raw protobuf]; `delivery_mode` (u64: `0 = UNSPECIFIED`
   [reject], `1 = FRESH`, `2 = RENEWAL`, `3 = ROLLOVER`, `4 = LATE_FENCED_DELIVERY`);
   `route_map_version` (u64, MUST be nonzero). The publisher-attested `delivery_mode` REPLACES
   the old `source_kind`: the source-authorization kind stays signed semantic data inside
   `EdgeRecordV1` and is NOT duplicated into transport headers. Proof invariant keyed on
   `delivery_mode`: `FRESH` carries NO proof (absent); `RENEWAL` / `ROLLOVER` /
   `LATE_FENCED_DELIVERY` carry EXACTLY one 32-byte proof; `SERVICE_INGRESS` v1 is FRESH-only
   (proof absent). Hard byte bound <= 512 ASCII bytes. The framed envelope (NOT a digest of
   it) is base64url-encoded (no padding) into the header value.

9. Compiled-assignment BODY digest -- string domain
   `serviceradar.edge.assignment.compiled.body.v1` FIRST, then `u64
   CompiledAssignmentDigestVersion = 1`, then the ordered BODY fields:
   `compiled_assignment_id` (bytes), `producer_assignment_id` (bytes), `execution_id`
   (bytes), `execution_plan_id` (bytes), `execution_plan_sha256` (bytes), `target_range_id`
   (bytes), `target_range_sha256` (bytes), `network_scope_id` (bytes),
   `authenticated_agent_id` (bytes), `execution_shard` (u64), `assignment_epoch` (u64),
   `config_generation` (u64), `result_format` (u64/enum), `check_set_sha256` (bytes),
   `traffic_class` (u64/enum), `not_before_unix_nano` (i64), `expires_at_unix_nano` (i64).
   EXCLUDES both digest fields AND `collection_capability`. This is what the COLLECTION
   attestation signs; a signature cannot cover itself. Note the transcript order is NOT the
   proto field order -- `producer_assignment_id` (20) and `execution_id` (21) are framed
   THIRD and FOURTH, immediately after the carrier id, because the grammar was frozen with
   the identity members grouped; the ORDER HERE is authoritative, not the tag order.
10. Compiled-assignment ARTIFACT digest (the carrier's CONTENT ADDRESS) -- string domain
   `serviceradar.edge.assignment.compiled.artifact.v1` FIRST (a DIFFERENT domain from
   grammar 9, so neither digest can be presented where the other is required), then `u64
   CompiledAssignmentDigestVersion = 1`, then: the grammar-9 BODY digest (bytes, i.e. the
   32-byte value length-prefixed like any other bytes member); a 1-byte PRESENCE marker for
   `collection_capability`; and, ONLY when present, the capability's grammar-2 SIGNING
   PREIMAGE (bytes) followed by its `signature` (bytes). EXCLUDES the artifact digest field
   itself. The referencing assignment record pins THIS digest: a body digest is not a
   content address for an artifact that also carries an authority, because two carriers with
   identical bodies and different capabilities share a body digest.

   PROOF CLASS / PARITY (both grammars): SHARED cross-language vectors, Go-authored and
   consumed by both runtimes -- the carrier bytes, both digest values, the COLLECTION
   attestation's grammar-2 signing preimage, the ASSIGNMENT_EXECUTION grant's grammar-2
   signing preimage, both issuer public keys, and the referencing record. Each runtime
   SHALL reproduce both digests and both preimages from the committed bytes.

   Authenticated-principal encoding (feeds `Nats-Msg-Id`, `Sr-Edge-Delivery-Id`, and
   provenance identically and MUST equal `producer_context.origin_principal_id`): the exact
   case-sensitive ASCII bytes the authenticated component-id resolver returns, charset
   `[A-Za-z0-9_-]`, length 1..128 -- no trimming, lowercasing, UUID text/binary conversion,
   or Unicode normalization; the encoder MUST NOT accept a separate origin-principal that
   could disagree with `authenticated_agent_id`. Service coordinates: `publication_lane_id`
   is a 16-byte UUIDv7; `publication_sequence` starts at 1 and increases monotonically
   (0 is invalid). WHEN the lane is allocated, whether it is persisted, and when a
   sequence is reused across retry/timeout/restart are runtime lifecycle owned by the
   companion change, not ABI validity rules.

### Artifact-hash exclusion (scope note)

The ARTIFACT hashes `submission_sha256`, `payload_sha256`, and `record_sha256` are
plain SHA-256 over the exact raw bytes and are NOT preimage grammars. The "every
cryptographic preimage begins with a committed version (and, where used, a leading domain
tag)" rule applies to the signing/digest transcripts (1-10), not to artifact hashing. Their
named digests MAY
participate in the transcripts above (for example the semantic-envelope digest
commits `payload_sha256`, and the `Nats-Msg-Id` transcript includes
`record_sha256`), but the artifact hashes themselves are computed as raw SHA-256
with no domain tag or version prefix.

### Parity requirement

Every grammar (1-10) has independent Go and Elixir preimage fixtures and, where the
grammar is signed, signature parity fixtures, and a digest-algorithm line
(SHA-256). Fail-closed version coverage is the vector ASSIGNED BY EACH OBJECT'S
PROOF CLASS (task 1.6): Class A objects carry an unsupported-INPUT-version reject;
Class B objects have no version input and instead carry an altered-version
preimage/digest/header MISMATCH reject. An unsupported-input vector SHALL NOT be
demanded of a Class-B object -- it cannot be constructed. A grammar without
both-language preimage (and signature, where applicable) golden fixtures is not yet
frozen.

## Appendix B: span-field traceability (NON-NORMATIVE)

Not a schema. The authority for every field is Appendix A and the
`edge-producer-data-plane` classification-span requirement; if this table and those
disagree, they are right and this is stale. It exists because three consecutive
review rounds found the same class of defect -- a field frozen against one
requirement without cross-checking the others that constrain it -- and a per-field
row is what makes that visible before the freeze rather than after.

Columns: field -> authoritative source -> validity rule -> digest position ->
in mapping key -> vectors owed.

| Field | Authoritative source | Validity | Digest position | Key | Vectors |
| --- | --- | --- | --- | --- | --- |
| `from_sequence` | span requirement | `>= 1` | span 1 | no | zero, inverted |
| `through_sequence` | span requirement | `>= from_sequence` | span 2 | no | inverted, overlap, cross-page |
| oneof discriminant | span requirement | set; 3/4/5 only | span 3 (`u64` member no.) | no | unset oneof |
| `identity` marker | Appendix A nested rule | present; nil body rejected | before identity body | no | nil identity |
| `producer_assignment_id` | attributed-identity req | canonical 16-byte UUID | identity 1 | yes | non-UUID, wrong width |
| `run_id` | attributed-identity req | canonical 16-byte UUID | identity 2 | yes | non-UUID, wrong width |
| `run_shard` | attributed-identity req | `u32` | identity 3 | yes | — |
| `authority_epoch` | attributed-identity req | plain `u64`, required, no marker | identity 4 | yes | absent-epoch record |
| `production_scope_id` | accepted-record validators | canonical 16-byte UUID | identity 5 | yes | non-UUID, empty |
| `scope_sha256` | attributed-identity req | exactly 32 bytes | identity 6 | yes | wrong width |
| `contract_bundle_sha256` | attributed-identity req | exactly 32 bytes | identity 7 | yes | wrong width |
| `source` marker | source-identity req | all four present or none | identity 8 | yes (incl. absence) | partial source, present vs absent pair |
| `source.kind` | `EdgeSourceAuthorizationKind` | frozen v1 accepted set `1..7` | source 1 | yes | `0`, `-1`, next unknown, `999` |
| `source.context_id` | source-identity req | canonical 16-byte UUID | source 2 | yes | non-UUID |
| `source.source_scope_id` | accepted-record validators | canonical 16-byte UUID | source 3 | yes | non-UUID, empty |
| `source.source_scope_sha256` | source-identity req | exactly 32 bytes | source 4 | yes | wrong width |
| `range_sha256` | attributed-identity req | 32 bytes, ACTIVE only | after identity body (ACTIVE) | yes (ACTIVE) | on PASSIVE, wrong width |
| `reason` | `EdgeUnattributableReason` | frozen v1 accepted set `2,3,4,6,7` | UNATTRIBUTABLE body | n/a | `0`, `-1`, `1`, `5`, next unknown, `999`; one per row + precedence controls |

Two rows carry the defects the earlier rounds missed, and are the reason the table
is worth keeping: the `source` marker row is where source-present and source-absent
spans stopped collapsing onto one digest, and the two scope-ID rows are where
"non-empty" was weaker than the accepted-record contract they must agree with.

## Review history and where it lives

This change's slices went through long adversarial review, and the corrections are worth
keeping — but NOT in `tasks.md`. That file is a work ledger: what landed, what remains, what
blocks it, and what evidence backs the claim. Narrative of the form "an earlier revision said
X, which was wrong" belongs here or in the PR that made the correction, because it describes
how the contract was reached rather than what is owed.

The rule going forward: a `tasks.md` entry states the CURRENT position. If a past error is
worth recording, it is recorded here or in the PR description, and `tasks.md` carries only the
forward-looking consequence — for example "the payload-family relation has an owner" rather
than "an earlier revision called it unowned".

Corrections whose REASONING is load-bearing stay in the spec, not here: those are cases where
the wrong reading is a live trap for the next implementer, such as the `EdgeSourceClaimsV1` and
`EdgeAssignmentExecutionClaimsV1` collection windows sharing field names while using opposite
endpoint conventions.

### Decisions whose rejected alternative is recorded here, not in tasks.md

- **Zero-MTR completion.** Candidate (A) required no proof and left
  `mtr_ordinal_range_commitment` EMPTY. Rejected because it permitted both an absent and a
  present proof for one state and rested the choice between them on the event's own
  producer-reported counters. Candidate (B) — a mandatory canonical zero-leaf proof — shipped
  in #4769. The ledger states only the rule that survived.
- **`run_id` equality.** An earlier reading equated `EdgeProducerContext.run_id` with a source
  correlation. Withdrawn: the span requirement forbids it, and the ledger states the
  prohibition rather than its history.
- **Loss-span union direction.** "Proven not-lost by the span union" is backwards; absence
  from a COMPLETE union is what establishes not-lost.
- **Capability oneof growth.** Task 1.3 added `collection` = 11 and `assignment_execution`
  = 12. Appendix A is the inventory; task entries do not track additions chronologically.

### Pre-implementation audit for task 1.6a (loss-classification spans)

Recorded here because it describes the state BEFORE the task landed, and a checked task
should carry its stable rules and evidence rather than the gap that motivated it.

At audit time: Elixir had only `HashGrammar` and no relational recovery validator, so its
half was new code rather than a port of `recovery.go`; the Go validator re-marshalled decoded
pages, so duplicate fields and non-minimal varints evaded the physical ceiling; several
`validate.go` comments were stale; and validators still rejected unattributable spans. All of
those are now closed — the rules that replaced them are in the task, the narrative is here.

### Mutation record for the MtrCompletionDisposition enum (task 1.4)

Kept here rather than in the ledger, which states the rule and its evidence.

Two mutations, each of which COMPILES — so each is a kill rather than a failed experiment —
with no edit to either runtime:

- renumbering `SCHEDULER_LOST` 5 -> 6 fails the closed-set tests in both runtimes;
- SWAPPING `QUARANTINED` and `SCHEDULER_LOST` fails the symbol-pin tests in both runtimes
  while the closed-set tests stay GREEN.

The second is why both test kinds exist: a swap preserves the set and moves only the meaning
at each number, so a closed-set test cannot see it. Every existing completion golden vector
stayed byte-identical under both, confirming the digest grammar did not move.

## The 1.5-f compression audit (2026-08-04)

Recorded here rather than in the ledger, which states rules and evidence, not findings.

`compression.go` and `validate.go` already implemented Go compression admission before 1.5-f
began, so slice 1 is a FREEZE of what the audit found rather than a specification the code
then has to be dragged toward. What the audit established:

- The ratio is enforced inside `validatePayloadBinding` on DECLARED sizes, BEFORE
  decompression, so a decompression bomb is refused without ever being expanded.
- `encoded_size` is bound to the actual payload length by the FIRST check in that same
  function, ahead of the ratio that consumes it as a denominator. This is what
  stops the ratio's DENOMINATOR from being inflated: without it, a record declaring a large
  encoded size passes the ratio trivially and only the absolute ceiling still applies. The
  binding existed; the freeze makes the ORDER a rule rather than an implementation accident.
- The ACTUAL decoded output must equal the declaration (`compression.go`), so the bounds
  apply to a body rather than to a claim.
- `zstdFrameLen` parses frame STRUCTURE and requires the frame to end at exactly the payload
  length, rejecting trailing bytes, a second frame, an empty concatenated frame and a
  skippable frame. A decode-side output-size check cannot see these: klauspost consumes
  no-output trailing frames transparently, so the declared byte count is produced from a
  payload carrying more than one frame.
- Validation streams through a 64 KiB scratch buffer and never reserves the full output.
  That buffer bounds the CALLER'S output buffering only -- the decoder still retains O(window)
  of history, which is what the window ceiling exists to bound.
- Every decoder WAS constructed with `WithDecoderMaxMemory(MaxUncompressedBytes)` -- this is
  the HISTORICAL configuration, corrected during the 1.5-f Go reconciliation, which split the
  window ceiling out as `MaxZstdWindowBytes` so the two limits stopped moving together.
  klauspost
  documents that option as "maximum decoded size for in-memory non-streaming operations OR
  MAXIMUM WINDOW SIZE FOR STREAMING OPERATIONS", and this code streams -- so Go has been
  enforcing a 32 MiB WINDOW ceiling all along, as a third limit nothing had frozen. Verified
  empirically: a hand-built frame advertising 1<<25 (32 MiB) is accepted and 1<<26 (64 MiB)
  is rejected, with a 12-byte output so neither the output ceiling nor the ratio is what
  refused it.

THE HOP ASN FIELD STAYS NON-OPTIONAL IN V1, AND ZERO CARRIES "UNAVAILABLE".

That is an overload, and it is chosen rather than overlooked. `MtrTraceHopV1.asn` is
diagnostic enrichment supplied by the producer; v1 has no requirement to tell an OBSERVED
AS 0 apart from an unknown one, and nothing in the product acts differently on the two. Given
that, presence tracking would add a wire-visible distinction no consumer reads.

If that requirement ever appears -- something must record that a hop genuinely reported AS 0,
distinctly from having no answer -- the field becomes `optional uint32`, so presence carries
"observed" and the value carries the ASN. It SHALL NOT be resolved by giving zero a second
meaning, because the two readings are not distinguishable after decode and every consumer
would have to guess which was intended.

AN EARLIER DRAFT OF THIS SECTION CLAIMED THE COMPOSED-REACHABILITY OBLIGATION WAS
UNSATISFIABLE. IT IS NOT, AND THE ERROR IS INSTRUCTIVE.

The reasoning was: every admitted family bounds its own body below the physical ceiling -- a
maximal sweep batch marshals to ~116 KiB because the contract stops at
MaxSweepHostsPerBatch, and MTR is capped at MaxMtrBatchBytes -- therefore no valid body above
512 KiB exists. That measured CANONICAL marshals and generalized to all byte strings, which
this ABI does not permit.

`unmarshalPayload` deliberately imposes no decode/re-encode equality: the payload's identity
is `payload_sha256` over the EXACT received bytes, so requiring canonical form would reject a
conforming encoder that emits equivalent but non-identical bytes. NONCANONICAL BODIES ARE
ADMISSIBLE BY DESIGN. A body may therefore carry a duplicate encoding of a singular field,
and protobuf's last-one-wins means a canonical value appended afterwards is what the decoder
keeps.

So the padding rides inside a duplicate of singular bytes field 13
(`availability_policy_id`), sized to put the body above 512 KiB, with enough deterministic
entropy that the frame stays within 100:1 and the record stays far below the physical
ceiling. The extracted body exceeds 512 KiB; what it MEANS is the ordinary bounded batch.
The same construction scales to exactly 33_554_432 bytes, so the 32 MiB ceiling vector is a
valid contract body rather than filler.

The lesson is about which quantity a bound bounds. The per-family limits bound MEANING -- how
many hosts, how many bytes a canonical encoding needs. The physical ceiling bounds RECEIVED
BYTES. Concluding one from the other was the mistake, and a measurement of one canonical
marshal plus one constant was never evidence for a universal claim about every admissible
encoding.

A related trap sits one layer down. `fixedUUIDv7` fills all sixteen bytes with its seed, so
the resulting timestamp is ~89 billion seconds and overflows int64 when the authority window
is computed in nanoseconds. Nothing noticed, because the payload-binding stage never looks at
the event id -- it only surfaced once a vector was validated as a WHOLE record. Committed
vectors also need their capability and envelope digest REBOUND after identities are fixed;
overwriting the ids alone leaves a record still carrying a randomly-minted capability, which
drifts on every regeneration.

SLICE 3 FOUND ONE UNENFORCED PRECONDITION AND TWO CONSTRUCTION CONSTRAINTS.

`admit_declared/2` -- the Elixir ratio gate -- documents that its caller MUST have bound
`encoded_size` to the actual payload length, because that value is the ratio's DENOMINATOR.
No caller in that runtime did: the function existed, the precondition was written down, and
nothing enforced it. A documented precondition with no enforcing composition is not a rule,
and `Compression.admit_record/1` is what makes it one.

The exactly-100:1 vector cannot be computed directly. The compressed length depends on the
body, and the body length is defined as ratio times the compressed length, so the two are
mutually recursive. Setting total = frame * ratio and recompressing converges within a few
rounds, because the bytes added are zeros and barely move the frame size; failing to converge
is a hard failure rather than a near miss, since a vector one byte off an inclusive boundary
proves nothing about it.

The 32 MiB pair is COMMITTED, as `record_admit_output_ceiling.bin`, and both runtimes read
those same bytes. An intermediate version had each runtime compress a shared RECIPE instead,
which is not cross-language evidence at all: Go and OTP produce different frames from the
same input, so "the ceiling is inclusive" would have been asserted about two different
payloads and neither runtime would ever have seen the other's. The fixture is 424_102
bytes (~414 KiB),
larger than anything else in the tree, and there is no cheaper one -- admitting exactly
33_554_432 bytes of output within 100:1 REQUIRES at least 335_545 encoded bytes. The
over-ceiling half is derived from the same committed bytes rather than committed twice, and
both runtimes assert the ratio slack BEFORE the verdict so the CEILING is demonstrably what
decides.

THREE DEFECTS IN THE SLICE-2 VECTORS ARE WORTH RECORDING, because each was a test that
looked like proof and was not.

The encoded-input boundary vectors first padded a bare zstd magic with zeros. That is a
MALFORMED buffer, so the parser returned the rejection whether or not the ceiling existed --
deleting the guard left the suite green -- and because the at-limit case expected that SAME
reason, `>` versus `>=` was invisible too. A VALID frame plus padding fixes it: the two sides
then give DIFFERENT reasons, so each mutation moves one of them.

Those vectors were then built from `MaxPayloadBytes` itself, which made them SELF-ADJUSTING:
raising the constant moved the vectors with it, so Go would admit 524_289 bytes to the frame
walk with every Go test passing while the Elixir peer, which states the literal, refused
them. A frozen value has to be asserted against a number the test states itself.

Elixir's `frame_length/1` was exported. It was a second entry point taking raw bytes, and it
did not carry the encoded-input ceiling that `validate_payload/2` applies before calling it,
so bounding one public frame walk left an unbounded one beside it.

TWO CLAIMS IN AN EARLIER DRAFT WERE FALSE AND ARE CORRECTED.

"Decompression happens exactly once" was wrong: an accepted payload is decompressed TWICE --
`ValidateZstdPayload` drains a decoder to verify the output length, and `innerPayload` later
calls `decompressZstdValidated`, which constructs and drains a second one to materialize the
protobuf bytes. (`decompressZstdValidated`'s comment HISTORICALLY said it avoided a "second and
third" decode, which is what misled the draft: it removes the third, not the second. The
comment was corrected during the Go reconciliation to say it IS the second decode.) The ABI rule
worth freezing is about LAYERS -- exactly one compression layer is admitted, and the extracted
bytes are a contract message rather than another envelope. How many passes a runtime takes
over that layer is implementation topology, and refactoring Go to reuse the first output is a
separate question from the freeze.

"Recursion" unqualified was ambiguous: protobuf MESSAGE recursion has its own 10_000-message
ceiling owned by 1.5-a. The compression rule is now stated as RECURSIVE COMPRESSION.

ON THE RATIO ARITHMETIC. An earlier draft of the freeze mandated a 64-bit accumulator. That
overstated the requirement: because `encoded_size` is bound to a payload already under the
512 KiB physical ceiling, the admitted denominator is at most 524_288 and the product at most
52_428_800, which a 32-bit accumulator holds. The property worth freezing is
OVERFLOW-SAFETY plus the ORDER -- an unbound `uint32` denominator times 100 does exceed 32
bits, so a runtime evaluating the ratio before the binding would need a wider accumulator to
stay correct. Freezing a width would have frozen an implementation detail and missed the
reason it is safe.

## The 1.5-a unknown-field / unknown-enum audit (2026-08-08)

Recorded here rather than in the ledger, which states rules and evidence, not findings.

Both runtimes already enforced every clause before 1.5-a began, so the slice is a FREEZE of
what the audit found. Nothing in it changes behaviour: no validator, no inventory, no runtime
edit. What the audit established, by RUNNING each input through both runtimes rather than by
reading the code:

- Eleven inputs were put through Go's `DecodeRecord` + `ValidateRecord` and Elixir's
  `WireDecode.decode_record` + `SemanticValidate` before any test was written. Every one
  agreed on accept versus refuse. There was no behavioural divergence to fix.
- What was missing was SHARED evidence. Every structural case was proven by bytes hand-built
  INSIDE the Elixir suite, so the two runtimes were asserted to agree on inputs neither had
  seen from the other. The two group vectors that predated the slice are both TOP-LEVEL.
- The two runtimes refuse the same bytes at DIFFERENT layers, in both directions. Go's wire
  parser refuses an out-of-range field number and a 10-byte overflow varint, while the pinned
  protobuf-elixir decoder accepts both -- masking `2^64 + 1` to `1`, which the peer now asserts
  as the number rather than as "a struct came back". Conversely Go PARSES and retains an
  ordinary unknown field and a well-formed group and refuses them on its own walk, while
  protobuf-elixir DISCARDS a group entirely, so nothing downstream of the decoder could see it.
- A CORRECTION to what the code said about itself: `WireValidate`'s comment claimed Go does not
  reject a singular scalar arriving length-delimited. That is true of Go's PARSER, which
  preserves the bytes as an unknown field -- and `DecodeRecord` then refuses it. Measured, not
  reasoned: Go returns `ErrUnknownFields` for that shape.
- That same vector is the one place the Elixir gate's halves swap roles. The preflight passes
  it deliberately (the packed rules are `repeated?`-gated) and the decoder raises
  `Protobuf.DecodeError`, which `classify/1` maps to `:poison`. One clause away is `:systemic`,
  which at a known delivery slot is retryable forever against Go's permanent refusal.
- An UNOWNED OBLIGATION surfaced: this change's task 1.5 body requires a typed malformed-wire
  preflight, and no subtask carried it. It became 1.5-l rather than being absorbed into 1.5-a,
  because 1.5-a freezes whether bytes are refused and 1.5-l owns what a refusal is called.

### Mutation record (1.5-a)

Four mutations, each killed:

| mutation | killed by |
|---|---|
| drop Elixir's unknown-field clause in `WireValidate` | the Elixir corpus, 2 of 10 tests |
| disable Go's `hasUnknownFields` | the Go corpus, on `wire_compat_unknown_field_top.bin` |
| move ONE runtime's manifest column to `accept`, leaving the other | BOTH suites, on the class invariant |
| add an orphan `wire_compat_orphan.bin` | BOTH suites, on manifest-versus-disk |

Reachability was proven rather than assumed: corrupting the manifest fails both
`//go/pkg/edge/edgerecord:edgerecord_test` and
`//elixir/serviceradar_core:unit_tests_serviceradar_edge`.

## The 1.5-g payload-family audit (2026-08-09)

Recorded here rather than in the ledger, which states rules and evidence, not findings.

The subtask offered two outcomes -- freeze a family-to-contract relation with vectors, or record
that v1 needs none. The audit found that neither was correct, and that the second would have
frozen an omission as protocol behaviour.

What the audit established, by RUNNING records through the validators rather than reading them:

- `dispatchContract` compares the four `EdgeOutputContractRef` members and never reads
  `payload_family`. That part was already known and is deliberate.
- `ValidateSweepRecord` and `ValidateMtrRecord` did not read the family EITHER. Measured, all
  four declared non-recovery families were admitted identically at the typed sweep ingress: a
  record declaring `SNAPSHOT_PAGE_V1` while carrying a sweep body was admitted AND authenticated
  with contradictory metadata.
- Only `RECOVERY_CONTROL_V1` was refused, and not by contract dispatch -- by
  `validateRecoveryLane`'s biconditional against `route_profile`, a different rule.
- `ValidateLifecycleRecord` and `ValidateRecoveryControl` DID check their families, so the
  invariant existed at two of four typed ingresses and was missing at the other two.
- Nothing at that revision invoked `ValidateLifecycleRecord`, so even the check that existed was
  unexercised. "Already covered" would have rested on an unrun branch.

Protobuf bytes are not intrinsically type-tagged, so a body decodes under an unintended schema
without complaint. Recording the observed behaviour as the contract would therefore have
authenticated contradictory metadata and made future decoder selection unsafe -- which is why
the resolution is a third outcome: no contract-to-family mapping, but the family bound to the
typed entry point and enforced at each one.

### Mutation record (1.5-g)

| mutation | killed by |
|---|---|
| move the sweep framing gate after `unmarshalPayload` | the precedence control (`record bytes do not decode`) |
| remove ONLY the MTR call-site check | the MTR entry-point test, sweep corpus unaffected |
| remove the lifecycle family check | the lifecycle control |
| drop a declared family from the manifest | the descriptor-derived coverage guard, both runtimes |
| flip a typed verdict in the manifest | the Elixir peer |

A first attempt at the precedence mutation moved the gate after `innerPayload` only, which
extracts without interpreting, so the gate still ran first and the test passed. That is a
mutation that did not apply, not a passing test.
