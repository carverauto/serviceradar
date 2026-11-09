# Agent spool recovery and gateway coverage

Status: Decisions 1-5 approved by the product owner on 2026-11-09.
Issue #6424 visibility ships first; coordinator implementation is authorized.

## Context and verified prerequisites

The agent opens one `spool.Spool` in `go/cmd/agent/edge_record_sender.go`.
`ResolveSlot` classifies an allocated slot without committed bytes as ambiguous;
`ScanFrom` skips it. `sender.drainAcks` validates a contiguous disposition prefix.
Consequently a later committed record cannot resolve across the gap. None of the
visibility fields or logs is permission to advance a watermark or delete bytes.

The moved task notes, not the checked boxes in `unify-sweep-results-proto`, remain
the completion authority. Inspection against the staging base found:

| Dependency | Evidence | Remaining implementation |
| --- | --- | --- |
| Companion ABI 1.6a | `proto/edge/v1/record.proto`: `EdgeClassificationSpanV1`, page tag 11; retired page/tombstone fields reserved | No ABI restoration needed. Keep Go/Elixir parity and received-byte bounds. |
| Canonical hashes | `go/pkg/edge/edgerecord/recovery.go`: `ManifestPageDigest`, `ManifestRoot`, chain/tombstone validators | Invoke these; never implement a second hash grammar. |
| Restart classification | `spool/resolve.go`, `recover.go`, redundant evidence in `evidence.go` | Journal each frozen per-sequence classification before constructing pages. |
| Lane generations (1.5) | `spool/lanes.go`: `LaneSet`, frozen identity, retryable rotation | Agent runtime still uses `spool.Open`; wire lanes and migrate the existing spool without losing identity or data. |
| Capacity and ordinary reclaim (1.1) | `spool/reserve.go`, agent allocator, `spool/reclaim.go`, permanent-rejection quarantine | Allocator is now wired, contrary to the older moved note. Recovery reserve consumption and recovery coverage are still absent. |
| Admission (1.2) | `admission/controller.go`: opaque `ReclaimAuthorization`, no exported constructor | Coverage owner must mint it only after durable proof. Ordinary gate wiring does not complete this contract. |
| Assignment values/storage (1.3-1.4) | Existing assignment validators describe sweep records; no recovery mapping owner was found in edge packages | Tagged positive/explicit-negative mapping, conflict records, lookup outcomes and retention remain prerequisites. |
| Attribution and relocation (1.6-1.7) | `spool.WithBindings`/`BindingInspector` accept an inspector; the agent opener supplies none | Implement semantic join, independently durable bindings, and destination rebinding. |
| Coordinator/reclaim/consumer (1.8-1.10) | Recovery wire validators exist; no agent coordinator or EventWriter recovery consumer was found | Implement the tasks and crash vectors below after approval. |

The short rescue search checked 135 local repository object stores under
`~/src`, `/Volumes/Build`, and the no-mistakes repository store. None resolved
`9a3a701f`. The visible ServiceRadar bundle advertises an unrelated documentation
branch. Rebuild from the frozen task/spec contract; this search is not a claim
that every external archive was searched.

## Decision 1: recovery belongs to a separate coordinator

A coordinator owns one immutable recovery ID for a frozen source generation and
selected bounded source segments. Producers rotate to a new generation under the
same authenticated agent/scope and lane identity. The sender remains a transport:
it sends committed records and never invents loss classifications or signatures.
Use the existing reserved recovery lane concurrently with bulk and interactive
lanes. Do not put recovery messages behind the bulk gap they must resolve.

Persist two checksummed journal copies and directory metadata before acknowledging
any phase transition. Journal the frozen source high-water and local reclaim
watermark, identity, selected source segments, per-sequence record/binding evidence,
complete classification bodies, destination mappings and copy watermarks. Resume
from durable phase/intent, not from whichever temporary files happen to exist.
Disagreement between journal copies requires deterministic evidence reconciliation;
when neither proves the next transition, retain bytes and surface a recovery error.

## Decision 2: bounded pages derive from journaled evidence

For every allocated sequence in the frozen unreclaimed interval, record either a
preserved destination or loss with its complete oneof classification. Never infer
that a missing lookup is an explicit negative mapping. Mapping outcomes have the
transitions required by task 1.4: temporary failures wait, missing fences, and
corrupt/conflicting quarantines; none authorizes `RecoveryResolvedV1`.

Merge adjacent lost intervals only when every intervening sequence is journaled
lost and the complete oneof bodies are equal. Compare every identity, scope,
epoch, discriminator and range digest for attributed bodies and the exact reason
for unattributable bodies. The gateway cannot reconstruct erased pre-merge facts.
Keep the per-sequence evidence through the deletion proof and recovery completion.

Construct four vectors from the journal, before constructing the final page:

1. Equal bodies at lost 1 and 2 merge.
2. Lost 1 and 3 with preserved 2 remain separate.
3. Adjacent attributed losses differing in one identity/range digest remain separate.
4. Adjacent unattributable losses with different reasons remain separate.

Apply canonical hashes using `edgerecord`. Enforce page, manifest and record bounds
against exact serialized/received bytes. Partition an oversized manifest into
bounded recoveries before freezing their identities; never erase attribution to
fit a budget. Retry recoverable work by semantic identity instead of enumerating
an outage-sized target tail. The aggregate allocator reserves both journals,
destination bytes, bindings, mappings, pages and filesystem overhead before work.

## Decision 3: gateway authorization and acknowledgement boundaries

The gateway authenticates the agent and fixed scope, checks the frozen source and
destination lane identities, and issues/renews operation-specific recovery source
capabilities through the existing authority path. The capability digest binds the
exact page/tombstone body using the frozen recovery scope grammar. The agent never
signs a recovery record. New recovery authorization/request handling must be
specified and tested as part of this implementation before an agent can use it.

The gateway validates exact received-byte ceilings, record authorization, page
hash/chain, root and immutable recovery identity. It publishes recovery-control
records to the configured JetStream recovery subject. Only a broker PubAck can
produce the durable recovery publication acknowledgement. The gateway does not
acknowledge an ordinary delivery across an unexplained gap and does not treat a
status field, journal existence or destination fsync as coverage.

Ordinary gateway prefix handling must recognize consumer-committed loss coverage
for the abandoned generation, while preserved records are delivered under their
new, fully committed destination coordinates with replacement capabilities and
stable semantic identity. This is a new protocol integration, not permission to
weaken `ValidateAck`. Persist the coverage application and its immutable recovery
identity before exposing any advanced old-generation prefix. Restart/replay must
produce the same result. Mixed-version peers fail closed and retain source bytes;
roll out capable gateway/core first, then enable the coordinator via runtime
settings and code defaults after capability negotiation.

## Decision 4: two distinct durability gates

Source deletion requires durable coverage of EVERY allocated unreclaimed sequence:

- Preserved: sender-visible destination commit evidence, wrapper coordinates,
  rebound attribution, durable mapping/high-water and directory metadata.
- Lost: all required pages PubAcked AND durable per-sequence loss evidence whose
  complete classification body equals the covering span.

Persist delete intent before deletion and completion afterward. A PubAcked span is
never self-authorizing. Specifically reject wrong-body coverage, an fsynced but
uncommitted destination, missing PubAck, and the sequence 9 committed / sequence 10
allocated-markerless case when only 9 is covered. Exercise a full-spool recovery
using the reserve and every journal/delete crash boundary.

Journal/page-proof garbage collection is a later gate: both copies stay until a
signed consumer-committed `RecoveryResolvedV1` or equivalent authenticated
idempotent query result is durable on the agent. A PubAck is insufficient.

## Decision 5: consumer keys and replay semantics

The EventWriter recovery consumer persists pages under identity-only keys
`(network_scope_id, agent_id, recovery_id, page_index)` and compares the fixed page
digest. Recovery identity is `(network_scope_id, agent_id, recovery_id)` and compares
prior spool, new spool, root and page count. Same key/different value is an integrity
conflict, never another insert. The scope/agent fields are authenticated identity,
not a new deployment tenancy model. Broker dedup IDs may include digests so a
conflict reaches the consumer.

After assembling and validating the full bounded chain and terminal copy manifest,
one durable transaction applies the loss audit, partial/lost produced ranges,
authority fences and scheduler reconciliation intent. Active loss affects its
produced range; passive loss asserts only delivery loss; unattributable loss
records its reason, fences the affected agent/scope generation and schedules
reconciliation. Do not acknowledge consumer completion before these writes commit.
All transport enters JetStream first; the control-plane audit transaction runs in
EventWriter, never in the agent or a bypassing gateway ingest path.

Replay choice: a completed immutable recovery has ONE final
`applied_through_sequence`; a later different value is a conflict, not incremental
progress. `resolved_at_unix_nano` is the original persisted completion timestamp:
return the same signed result on replay. Timestamp differences alone on an inbound
completion response do not prove different applied state, but the issuer must
serve its stored timestamp and signature. Compare recovery ID, root and applied
sequence; verify the authenticated signature/capability before accepting locally.
The applied scalar is the highest contiguous allocated prefix whose sequences
are either durably applied or absent from the validated COMPLETE loss union, using
`edgerecord.AppliedThroughSequence`; it is neither the largest span end nor simply
the allocation high-water. For loss at 1 and 100 with only 1 applied, it is 99. Partial progress remains internal pending state and emits no final result.

## Rollout and approval

Ship #6424 visibility first, with #6428 depending on its status transport. Visibility
never deletes, truncates, skips a sequence or changes acknowledgement validation.
Then complete prerequisites in dependency order, followed by coordinator, coverage
reclaim and consumer/gateway integration. Keep all moved tasks unchecked until
behavioral and crash evidence proves their complete contract.

The product owner approved Decisions 1-5 on 2026-11-09, including consumer-committed
gateway prefix application, source deletion versus journal-GC gates, immutable
completion replay, and gateway/core-first capability rollout. The implementation
checklist remains open until each complete contract is demonstrated.


### Physical generation bound

New attributed generations use the existing generation rotation as the physical
recovery segment boundary. Before PREPARED or sequence allocation, an append
must fit the full-copy destination budgets of the shared allocator. With `n`
retained slots including the proposed append and `S` encoded spool record bytes
including it, the required destination budget is `1024 + S + n * (4 * 212 + 256)`:
two evidence files, each holding PREPARED and COMMITTED v2 entries, plus prepaid
terminal evidence. The attribution-sidecar budget must cover `n * (1024 + 1024)`
for the complete attribution and relocation mapping sidecars. `n <= 1024` also
applies; existing manifest/key/run bounds may rotate sooner.

A nonempty generation that would exceed either bound refuses retryably with
`ErrRotationRequired`, without allocating a sequence. An empty generation whose
single record cannot fit returns a distinct retryable configuration/capacity
refusal; correcting settings permits the exact same event and body to retry.
Attributed appends without the shared allocator fail closed. Legacy generations
remain readable and drain under their original identities; relocating an
oversized damaged legacy generation requires explicit reserve headroom.

These destination limits are one part of the aggregate reserve. Coordinator
activation also requires separately validated fixed budgets for both frozen
journals, phase records, repairs, control publication wrappers/evidence/sidecars,
coverage certificates and filesystem metadata. The generation limit alone does
not establish that the complete coordinator footprint is configured.

### Aggregate defaults and recovery-control attempts

The default footprint is 32 MiB per active recovery: 8 MiB destination,
2 MiB attribution/relocation sidecars, 4 MiB for EACH journal copy, 2 MiB control
publication storage, 11 MiB terminal archive and coverage/mapping evidence, and 1 MiB filesystem
metadata. Together with the existing 1 MiB unborrowable free-space floor, one
active recovery reserves 33 MiB of the default 1 GiB spool. The existing allocator
capacity validation rejects a total below its aggregate floor; there is no new
Helm-only setting. `Footprint.ValidateCoordinator` additionally rejects component
budgets below the complete coordinator minima.

The destination equation includes 1024 fixed bytes for the generation identity,
format marker, dedicated recovery marker, closed marker and fixed hold. A journal
copy reserves twice `(1 MiB freeze + 1 MiB aggregate phase records)`, covering the
initial records and an exact repair of every retained record. Complete encoded
publication records are bounded to 512 KiB aggregate before enqueue. For at most
`ceil(1024 / MaxSpansPerPage) + 1` records including the tombstone, one control
attempt requires that aggregate plus each spool wrapper, four 212-byte evidence
entries, one 1024-byte attribution sidecar and 256-byte terminal allowance, plus
1024 fixed generation bytes. The minimum control footprint covers two complete
attempts; the default rounds up to 2 MiB.

Recovery controls use the SAME grant as data relocation. They consume the
`ManifestPages` artifact budget, including their wrappers/evidence/sidecars, and
have independently tracked retained file ownership. Source release transfers the
copy destination only. Final artifact release transfers still-retained control
attempts and their terminal allowances to ordinary storage for normal sender
cleanup. Restart measures every attempted control generation before testing
remaining physical backing, without acquiring another concurrency slot.

A failed control append may create an ambiguous slot. Its generation and all
its evidence remain charged; reconstruction uses the exact frozen publication
bytes in a new dedicated control attempt. Ordinary delivery renewal can authorize
the unchanged record under its new spool/sequence while the output grant remains
active. Repeated failed attempts require enough remaining aggregate capacity;
exhaustion is a visible capacity refusal retaining evidence, not unbounded retry
progress. Safe cleanup of superseded attempts remains part of the proof lifecycle.


### Paired storage proof checkpoint

Every mutable phase is an immutable two-copy record bound to the complete frozen
journal digest and its step name. There are at most 64 steps and 1 MiB aggregate
phase bytes per copy. A single intact copy permits exact repair but never proves
progress until both barriers exist. Divergent intact copies fail closed.

Opening an operation durably holds the source against resolution/reclaim and its
empty dedicated destination against resolution. The sender supervisor must close
or skip the source session while `Generation.RecoverySourceHeld` is true; a
read error also blocks that session. The destination remains sender-visible.
Every selected allocated slot is rechecked as either a committed destination with
exact local binding, old-to-new mapping and high-water evidence, or a complete
frozen loss classification with authoritative acknowledgements for every page and
tombstone. Those acknowledgements come only from the strict authenticated sender
validator. Their exact publication generation, attempt, sequence, event, raw hash
and binding are saved before ordinary control-lane resolution.

After both coverage certificate copies are durable, the destination hold can be
removed. Restart can use that certificate even if destination ACKs have since
advanced. Source terminal acceptance is not a third coverage branch: every
allocated slot above the physical reclaim base still needs a copy or loss proof,
including an already accepted or permanently rejected prefix. A private retained
source witness permits reading that prefix; the public destination witness still
requires an unresolved sender-visible commit.

The mapping/archive minimum is `DestinationSegment + AttributionSidecar + 1 MiB`:
the bounded source's retained record/evidence/sidecar bytes plus certificate,
terminal and archive framing headroom. Defaults therefore reserve 11 MiB here.
The following reclamation slice must preflight actual archive bytes and preserve
all terminal evidence without invoking the legacy quarantine eviction policy.
The proof checkpoint does not yet delete source bytes, release the source charge,
or collect journals; those actions still require the deletion-intent/archive and
verified consumer-resolution lifecycle.
