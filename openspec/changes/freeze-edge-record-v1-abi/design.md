# Design — edge record v1 wire ABI

This change owns FOUR things and nothing else:

1. the authority of the actual proto files;
2. the exact raw byte bounds;
3. Appendix A's byte-exact grammars, the identity semantics, and the
   version/proof-class inventory;
4. the cross-language freeze gates.

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
| plan / range / recovery content hashes | `PlanDigestVersion = 1` / recovery version `1` | plan: frozen. RECOVERY: **CANDIDATE, NOT FROZEN** -- task 1.6a atomically rewrites the manifest-page and tombstone-scope grammars, so no recovery entry here may be relied on for cross-language identity until it lands. DOMAIN-FIRST -- leads with a per-object `str` domain sub-tag (`serviceradar.edge.plan.{range,page,root,header}.v1`, `serviceradar.edge.recovery.{manifest_page,manifest_root}.v1`), THEN the `u64` version; FIXED field order; 8-byte big-endian ints; 8-byte big-endian length prefixes; each excludes its self-hash; NO `proto.Marshal` |
| MTR completion proof | `MtrCompletionDigestVersion = 2` | **CANDIDATE, NOT FROZEN** -- the leaf `disposition` is the not-yet-generated `MtrCompletionDisposition` enum (tasks 1.4/1.15) and the zero-MTR behaviour is an open decision. Otherwise: leads with the `u64` version; each leaf = version, ordinal (`u64`), disposition (`u64`), trace_id (bytes, empty unless TRACE_ALLOCATED), `range_sha256`; three accumulators folded by BIG-endian 256-bit modular addition (mod 2^256), arrival-order-independent, no per-block Merkle/sort; ROOT = `SHA-256(version || expected || plan_root_sha256(32) || mtr_ordinal_range_commitment(32) || content-acc(32))`; NO `proto.Marshal` |

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
The recovery manifest-page, tombstone-scope, RESOLVED-scope, and MTR-completion
entries are CANDIDATES until tasks 1.6a and 1.4/1.15 land. "TombstoneScopeDigest
retired" means the OLD TRANSCRIPT is replaced -- the scope OBJECT itself remains,
and stays in task 1.6's proof inventory; task 1.7 is the freeze gate and
carries those prerequisites explicitly. Reading the appendix title as "everything
here is frozen" would let an implementer pin a grammar this plan already schedules
for atomic rewrite.

Every SIGNING/DIGEST grammar below is byte-frozen and interoperable ONLY when Go
and Elixir implement it byte-for-byte. A grammar that does not pin all of the
common framing rules is not yet frozen and MUST NOT be relied on for
cross-language identity.

### Common framing rules

These rules apply to every grammar (1-8) at every nesting depth and match the reference
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
table below with an outer 1-byte presence marker and recursive framing; `proto.Marshal`
appears in NO preimage at any depth (landed in task 1.13).

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
7/8/9, and the signing preimage additionally commits `purpose`).

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
     7 = production / 8 = source / 9 = delivery / 0 = none) + the FIELD-FRAMED claim message
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
   (bytes); `algorithm` (str); `purpose` (u64/enum EdgeCapabilityPurpose = PRODUCTION /
   SOURCE / DELIVERY); `not_before` (i64); `expires` (i64); `claims` (the set claim message
   framed FIELD-BY-FIELD per the grammar-1 claim-message tables [field-framed in #4713,
   not `proto.Marshal`]). EXCLUDES the signature. Ed25519 signs this RAW framed preimage bytes
   DIRECTLY (NOT a SHA-256 of them). A single domain tag plus a `purpose` field bind the
   role -- there is ONE domain `.capability.v1`, NOT per-purpose tags.
   >>> FIXED in #4713 (task 1.13): the claims-oneof variant was formerly bound TWO different
   ways -- the signing preimage via the `purpose` enum, the grammar-1 capability() sub-framing
   via the 7 / 8 / 9 field-number discriminant. UNIFIED: BOTH now commit the u64 field-number
   discriminant (7 / 8 / 9), and the signing preimage ADDITIONALLY commits
   `purpose`; and BOTH field-frame the claim member (no `proto.Marshal`).
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
     (bytes), `mtr_admission_budget` (u64).
   - PlanPageDigest (plan.go, excl `page_sha256`): `str "serviceradar.edge.plan.page.v1"`,
     `digest_version` (u64), `execution_plan_id` (bytes), `page_index` (u64), `page_count`
     (u64), `prev_page_sha256` (bytes), `check_set_sha256` (bytes), `len(ranges)` (u64), then
     EACH range inlined in order (`range_id`, `range_sha256`, `cidr`, `first_address`,
     `last_address`, `target_count`, `check_set_sha256`, `availability_policy_id`,
     `mtr_admission_budget` -- the page commits each range's `range_sha256`, unlike
     RangeDigest itself).
   - PlanRoot (excl `plan_root_sha256`): `str "serviceradar.edge.plan.root.v1"`, `version`
     (u64), `len(pages)` (u64), then each `page_sha256` (bytes) in order.
   - PlanHeaderDigest (excl `execution_plan_sha256`): `str "serviceradar.edge.plan.header.v1"`,
     `digest_version` (u64), `execution_plan_id` (bytes), `page_count` (u64),
     `total_target_count` (u64), `plan_root_sha256` (bytes), `check_set_sha256` (bytes),
     `availability_policy_id` (bytes), `assignment_epoch` (u64), `network_scope_id` (bytes),
     `mtr_ordinal_range_commitment` (bytes).
   - **UNFROZEN CANDIDATE — retired atomically by task 1.6a.** The
     ManifestPageDigest entry below hashes the `lost_ranges` + `affected` pair,
     which 1.6a replaces with ONE ordered `classification_spans` list. Nothing has
     shipped against it; 1.6a rewrites this transcript, the page/manifest messages,
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
     CANDIDATE, retained only to show what changes. Task 1.6a REMOVES
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
     `manifest_root_sha256` (bytes), `applied_through_sequence` (u64) -- CANDIDATE
     pending task 1.6a, which freezes this scalar as the consumer's durably applied
     CONTIGUOUS PREFIX over the allocated sequence space (not the maximum span
     end); with gaps legal those differ, and the value gates journal release.
   Go and Elixir (`ServiceRadar.Edge.HashGrammar`) reproduce every self-hash AND scope digest
   byte-for-byte; the committed testdata (`tombstone_scope.bin` / `manifest_page_scope.bin` /
   `resolved_scope.bin` + the plan/manifest `*.bin`) are the cross-language vectors.
5. MTR completion proof -- `u64 MtrCompletionDigestVersion = 2`. CANDIDATE MIGRATION
   TARGET, not a description of the code: the leaf `disposition` becomes the generated
   `MtrCompletionDisposition` enum (tasks 1.4/1.15), which does NOT exist yet, and the
   zero-MTR behaviour is an open decision every implementation currently contradicts.
   It therefore does NOT "match the code exactly", and it supersedes rather than
   matches #4713's local declarations. Framing below
   (domain.go:706-847):
   - leaf element (`mtrLeafHash`): `version` (u64 = 2), `ordinal` (u64), `disposition`
     (u64, the uint32 widened to u64), `trace_id` (bytes, empty unless TRACE_ALLOCATED),
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
   - empty (`expected == 0`, the plan admits NO MTR targets) -- UNFROZEN CANDIDATE,
     OPEN DECISION (task 1.15): the candidate says NO completion proof is required; the
     plan's `mtr_ordinal_range_commitment` (`ScheduledPlanHeaderV1` field 11) is EMPTY
     bytes; and if a root is computed it is over zero leaves (`count == 0`, all three
     32-byte accumulators the zero value, with `plan_root_sha256` still committed). Every
     current implementation contradicts this, so it is NOT authoritative and MUST NOT be
     frozen at 1.7 until 1.15 chooses one behaviour.
   - terminal disposition values (the u64) -- `MTR_COMPLETION_DISPOSITION` enum, CANDIDATE
     (not frozen; see below),
     DISTINCT from the per-hop `MtrOutcome` enum:
     the members and numbers frozen by the requirement "MTR completion disposition is one generated enum". CANDIDATE, NOT FROZEN: this enum is not
     generated yet (tasks 1.4/1.15); calling it FROZEN while it exists only as a Go
     `iota` block and Elixir integer guards is what the 1.1-1.6 audit found. Declared ONCE as the generated proto enum
     `MtrCompletionDisposition` (full symbols `MTR_COMPLETION_DISPOSITION_*`); Go and Elixir are
     CONSUMERS, not co-owners -- the number is hashed into the frozen leaf preimage, so two
     hand-maintained copies can produce two roots for one completion. Cross-language leaf
     vectors are NOT "per value": VALID vectors for `1..5`, and REJECT vectors for `0`,
     `-1`, `6`, and `999` -- zero is rejected before hashing, so an accepted vector for it
     would contradict the rule. Do NOT reuse the per-hop `MtrOutcome` numbering (`REACHED = 1`,
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
tag)" rule applies to the signing/digest transcripts (1-8), not to artifact hashing. Their
named digests MAY
participate in the transcripts above (for example the semantic-envelope digest
commits `payload_sha256`, and the `Nats-Msg-Id` transcript includes
`record_sha256`), but the artifact hashes themselves are computed as raw SHA-256
with no domain tag or version prefix.

### Parity requirement

Every grammar (1-8) has independent Go and Elixir preimage fixtures and, where the
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
