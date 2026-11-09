# Recovery foundation choices

## Bound one recovery operation before granting authority

- When: registration contract pass, 2026-11-09.
- Choice: register the full bounded plan before issuing page or copy authority.
  If an agent loses sequences 9 and 11 while preserving 10, registration must
  carry both loss spans and the intended destination of 10. An interval alone
  could falsely describe 10 as lost. The gateway can check the complete plan
  without reconstructing the agent's erased journal evidence; the agent still
  owns the separate proof that its destination copy committed.
- Gap: the approved design requires operation-specific authority and a bounded
  terminal copy manifest but leaves the request shape and operation size open.
- Reach: select at most 1024 allocated slots per operation, with the existing
  256 KiB exact manifest limit and a 512 KiB registration limit. Larger plans
  split into distinct recoveries before freezing IDs. Four authenticated RPCs
  separate registration, source authorization, copy grant renewal and completion
  query. Protocol version zero keeps older or incomplete peers inactive.
- Verdict: sound. These bounds limit work without deleting evidence or widening
  loss spans; they leave local durability and consumer commit as separate gates.
- Confidence: medium. End-to-end reserve sizing must still demonstrate progress
  for large individual records; the slot limit is a ceiling, not a target size.

## Generation configuration factory

- When: lane foundation pass, 2026-11-09.
- Choice: configure a generation with existing spool options before opening it.
  When an agent restarts after re-enrollment, an old generation still belongs to
  its original authenticated identity. The factory receives a copy of that
  identity and the generation's final directory, so its binding reader can find
  the old evidence before the spool classifies records. A single inspector bound
  to the current session would inspect old records under the wrong identity.
- Gap: the approved design requires generation-specific bindings and a shared
  allocator but did not prescribe their configuration API.
- Reach: `WithGenerationOptions` returns ordinary `spool.Option` values; future
  runtime wiring shares its allocator and admission policy through that factory.
  Factories may run concurrently across lanes. They do not acquire resources
  needing a separate cleanup callback; the caller owns such services. A factory
  error refuses the generation open rather than silently dropping its options.
- Verdict: sound. The root implementer approved this seam before implementation;
  it keeps the existing spool configuration as the single owner of those knobs.
- Confidence: high.

## Fresh filesystem probe at admission

- When: lane foundation pass, 2026-11-09.
- Choice: use the existing gopsutil disk dependency to measure free bytes at the
  configured spool directory on every allocator probe. If another process fills
  the filesystem, a nominal spool budget alone cannot protect recovery space.
  The allocator now sees that shortage and refuses ordinary writes; if the path
  cannot be measured, recovery acquisition also refuses instead of assuming
  space exists. The existing allocator owns the reserve and in-flight arithmetic.
- Gap: the allocator already accepted a free-space probe, but production did not
  supply one and the design did not choose a platform implementation.
- Reach: the agent gains a direct Bazel dependency on a disk library already in
  its dependency graph, with no version change. The probe is bound to the same
  directory the spool opened. It does not cache a startup free-space value or
  inspect a parent directory that might belong to a different filesystem.
- Verdict: sound. This reuses the repository's existing platform support while
  activating its existing fail-closed capacity contract.
- Confidence: high.

## Immutable two-copy freeze before phase logging

- When: journal foundation pass, 2026-11-09.
- Choice: keep the frozen plan and exact manifest bodies in a versioned,
  checksummed record. Every selected allocated slot retains either its complete
  singleton classification or its intended destination coordinates and hashes.
  Detection time and reason are frozen inputs because signed controls require
  them; replay never invents a new timestamp or edits a publication body.
- Gap: the design defines crash evidence and reconciliation but does not prescribe
  a storage encoding or divide immutable evidence from mutable progress.
- Reach: `spool.FreezeRecovery` writes through the existing reserved durable barriers.
  `OpenRecoveryJournal` requires identical valid copies. `RepairRecoveryJournal` only recreates exact intact
  bytes when the other copy is absent or corrupt; conflicting valid copies,
  unsupported versions and read failures remain untouched. A freeze journal
  proves no copy completion, acknowledgement, source deletion or evidence-GC
  authority. Mutable phase intents remain a separate implementation slice.
- Verdict: sound. The root implementer approved this bounded freeze-only scope
  and strict reconciliation before implementation.
- Confidence: high.

## Bounded evidence with explicit partitioning

- When: journal foundation pass, 2026-11-09.
- Choice: at most 1024 selected allocated slots, at most 1 MiB per journal copy,
  and the existing 256 KiB aggregate exact manifest bound. Oversized plans return
  a split-required error rather than dropping evidence or weakening attribution.
  Copies-only compaction returns a separate error instead of fabricating loss.
- Gap: the approved bounded-work requirement needed a concrete interval and
  local-evidence ceiling alongside the existing wire ceiling.
- Reach: `RecoveryJournalBytes` reports exact bytes for one copy. The caller must reserve
  cumulative writes to both copies, every permitted repair, and independent
  phase/copy/page/mapping/metadata artifacts before acquiring a recovery grant.
  Coarsening compares the complete body and requires sequence adjacency; reopened
  singleton evidence remains the source for page construction and validation.
- Verdict: sound. The root registration protocol uses the same selected-slot
  ceiling. Frozen snapshots remain independent of later caller mutations.
- Confidence: high.


## Storage ownership for recovery proof

- When: coverage foundation pass, 2026-11-09.
- Choice: move frozen journal storage into `spool` before adding opaque coverage
  proofs. The storage owner must validate committed slots, durable bindings,
  allocated high-water and the frozen journal before authorizing reclamation.
- Gap: keeping the journal above `spool` would create an import cycle or require
  a caller-supplied proof assertion at the destructive boundary.
- Reach: the unshipped API now uses explicit `RecoveryJournal`, `RecoveryPlan`,
  `FreezeRecovery`, `OpenRecoveryJournal`, and `RepairRecoveryJournal` names.
  The local format and all validation remain unchanged. No aliases remain.
- Verdict: sound. Root approved the clean ownership move. A later coordinator
  orchestrates these storage-owned proofs without acquiring deletion authority
  from a generic callback.
- Confidence: high.

## Validated attribution and independent binding grammar

- When: attribution foundation integration, 2026-11-09.
- Choice: typed constructors derive authority from existing signed-body validators.
  The binding digest can validate stored tuple bytes independently, but only a
  validated result can authorize a new append. Relocation changes physical
  generation/sequence, preserving namespace, lane, event, exact record hash and
  full attribution. Go clones the captured values; Elixir terms are immutable.
- Gap: the design freezes the transcript but leaves the validated-result API open.
- Reach: sweep, metrics and recovery-control constructors cover their actual
  operands. No generic adapter invents a range for unsupported contracts. Other
  production adapters remain required before runtime activation. Shared synthetic
  vectors use independently computed expected hashes, not the production helper.
- Verdict: sound. The distinction preserves evidence readable after record loss
  without claiming that a checksum can validate an unavailable original record.
- Confidence: medium until all runtime producer adapters are integrated.

## Durable intent is separate from received recovery evidence

- When: operation storage pass, 2026-11-09.
- Choice: registration stores immutable bounded intent; a separate page table
  records delivery through the recovery consumer. Registration replay cannot
  manufacture broker receipt. Keys contain namespace, agent and recovery ID,
  plus page index for pages; digests and destination spools remain compared values.
  Conflicts retain original bytes and durably block the operation.
- Gap: the design fixes the idempotency contract but leaves the relational layout open.
- Reach: Ash resources have no lifecycle cascade or destructive action. A locked
  registration serializes page/tombstone receipt. Unsigned intent never authorizes
  source deletion or completion; later consumer repair owns those transitions.
- Verdict: sound. Received evidence and immutable intent remain distinguishable
  across restart, and a conflicting digest cannot evade its original key.
- Confidence: medium until guarded database integration tests pass.

## Recovery reserve ownership across append and restart

- When: coverage foundation pass, 2026-11-09.
- Choice: resume by measuring retained regular files before testing remaining
  physical backing; refused restores leave the allocator ledger unchanged.
  Reserve a relocated append's record, evidence copies, sidecars and terminal
  allowance atomically before PREPARED. Count cumulative writes separately from
  retained file growth, including sparse growth and prepared-slot overwrites.
- Gap: a fresh grant double-reserves already retained bytes after a crash, and
  independent per-artifact charges can fail halfway through append admission.
- Reach: this extends the existing allocator and grant. Destination terminal
  evidence remains prepaid when source release transfers destination ownership
  to ordinary storage. Only the generation's known data/evidence paths qualify.
  The coordinator still owns the complete retained-file inventory and must size
  the footprint for retained bytes plus every remaining write and repair.
- Verdict: sound. Root approved evolution of the existing ledger, and the
  binding owner consumes the private append-charge token across its barriers.
  Source release before final resolution remains a separate lifecycle step.
- Confidence: high.

## Authenticated recovery control and shared transaction errors

- When: gateway control pass, 2026-11-09.
- Choice: registration and status queries use the existing agent certificate
  resolver and installed trust snapshot. A request naming another scope cannot
  grant itself membership, even if an internal caller supplies a membership map.
  Core receives the authenticated agent identity separately from the plan.
- Gap: the design requires an independent control path but leaves its transport
  authentication composition and error behavior to implementation.
- Reach: these RPCs share normal gateway/core routing and return unavailable when
  trust or core is unavailable. They do not announce protocol readiness. Both
  mapping and operation stores use one recovery transaction adapter to preserve
  their bounded refusal reasons through Ash's structured transaction errors.
- Verdict: sound. The trusted namespace has one owner, and a database outage
  cannot look like successful registration or consumer completion.
- Confidence: high for authentication; persistence still needs guarded DB tests.

## Recovery chunks share one contiguous source prefix

- When: source interval pass, 2026-11-09.
- Choice: a generation row freezes the source allocation bounds and serializes
  disjoint recovery intervals. If sequences 1-10 are unknown and recovery for
  11-20 finishes first, its completion waits; the absence of 1-10 from that
  manifest says nothing about whether they survived. Rejected intervals remain
  visible as conflicts but cannot hide an earlier admitted interval in queries.
- Gap: bounded manifests require splitting, while the completion scalar describes
  contiguous progress over the source generation. The wire validator alone
  cannot maintain progress across those separate operations.
- Reach: one indexed generation key and exact numeric coordinates support bounded
  overlap and prefix queries, including the full uint64 range. Operation-before-
  generation lock ordering is shared by registration and consumer processing.
- Verdict: sound. It preserves the meaning of a complete loss union instead of
  treating a partial manifest as authority over omitted source slots.
- Confidence: high in the contract; database behavior awaits integration evidence.

## Attribution survives record damage and relocation

- When: sidecar integration, 2026-11-09.
- Choice: each sequence has a fixed independently checksummed attribution slot;
  relocation adds a separate mapping slot. New evidence entries explicitly name
  the mapping digest, while existing v1 generations keep their original offsets
  and remain readable. A torn adjacent sidecar slot cannot rename a readable one.
- Gap: the design freezes the authority binding, but not the physical sidecar and
  commit-evidence framing. Reusing an unrelated digest field would silently change
  the meaning of existing durable bytes.
- Reach: one validated append value derives the classification; producers cannot
  supply a second authority tuple. Record, sidecar and mapping durability precede
  the committed receipt. A reopened witness observes those facts but grants no
  deletion permission. Real read errors retain data and retry; malformed readable
  binding bytes alone become unattributable loss evidence.
- Verdict: sound. Explicit format selection preserves existing spools and keeps
  attribution independently readable after record damage.
- Confidence: high. Destination terminal-resolution races are handled by the
  separate durable recovery hold and coverage-certificate lifecycle.

## Account classification runs separately from physical bindings

- When: sidecar integration, 2026-11-09.
- Choice: segment capacity counts equal complete classification bodies together,
  normalizing only their physical interval. Two successive records for the same
  authority still have different per-sequence binding hashes, but do not consume
  two distinct authority dictionary entries merely for that reason.
- Gap: the old segment accounting used the physical binding digest as a body key.
- Reach: deterministic protobuf is used only for internal capacity accounting;
  the frozen cross-language binding transcript remains the durable authority.
- Verdict: sound. Capacity reflects real classification changes without weakening
  the independently checked physical record bindings.
- Confidence: high.

## Bound physical generations by full relocation bytes

- When: capacity foundation pass, 2026-11-09.
- Choice: use existing generation rotation, deriving a byte ceiling from the
  destination and sidecar reserve rather than introducing a new truncation ABI
  or a second size setting. Count every v2 evidence entry, attribution, mapping
  and terminal allowance before the append allocates a sequence.
- Gap: key/run limits do not bound large records with identical attribution;
  partial operations cannot make physical progress inside one append-only file.
- Reach: new attributed generations require the shared allocator. Existing raw
  and legacy generations retain their read/drain behavior. A single oversized
  valid record defers for configuration correction, never permanent loss.
  Fixed phase/control artifact minima and source reclamation remain later slices.
- Verdict: sound. Root approved this segmentation approach and corrected the
  empty-generation refusal to preserve the producer's event for retry.
- Confidence: high; independent destination/sidecar overflow regressions failed
  on baseline and complete reserved relocation succeeds with ordinary admission
  exhausted, using synthetic records with 32 KiB metric values.

## Separate durable receipt from consumer completion

- When: consumer transaction integration, 2026-11-09.
- Choice: acknowledge an incomplete page only after its exact bytes are durable
  in receipt storage. The record completing assembly remains deferred if mapping
  repair is pending or blocked. Neither receipt nor broker ACK releases journals.
- Gap: withholding every partial receipt fills a finite broker delivery window
  when operations interleave, preventing the pages needed to complete them from
  arriving. Raising that window only moves the failure threshold.
- Reach: the existing EventWriter transaction owns receipts and effects. Complete
  manifests replay repair; only applied adjacent intervals advance the source
  prefix. Signed completion remains a separate persisted result.
- Verdict: sound. This implements the approved distinction between received bytes
  and consumer completion without weakening unavailable-mapping refusal.
- Confidence: high in the boundary; guarded DB execution remains required.

## Verify completion as historical evidence

- When: agent completion verifier, 2026-11-09.
- Choice: verify the original signed recovery ID, root and applied prefix against
  current retained key policy, independently of production freshness and fences.
  Compromise-revoked and unavailable keys refuse release. Store detached originals.
- Gap: a producer validity deadline must not make a completed recovery impossible
  to collect after an outage; conversely, historical evidence is not a new right
  to produce or deliver records.
- Reach: the opaque Go receipt still requires the storage owner to join it to its
  frozen journal. The issuer retains one timestamp and signature; timestamp alone
  is intentionally outside the frozen applied-state scope digest.
- Verdict: sound. Reuses existing signature and trust verification without a new
  signature ABI or a caller-created deletion permission.
- Confidence: high; integration with journal release remains the next storage pass.
## One grant owns data and recovery-control attempts

- When: reserve lifecycle pass, 2026-11-09.
- Choice: attach dedicated recovery-control generations to the existing grant;
  account complete control storage under ManifestPages, separately from retained
  destination files. Resume measures all control attempts before checking backing.
- Gap: acquiring a second grant for publication deadlocks at maxActive=1. A torn
  append can also strand the control lane; replacement attempts must retain and
  charge the old evidence while replaying the exact publication.
- Reach: strict sender and attributed commit semantics remain unchanged. Source
  release transfers only data; final artifact release transfers control files and
  terminal allowances. Defaults reserve 22 MiB per recovery and validation covers
  the maximum supported record plus fixed generation metadata, both journal
  copies/repairs, two control attempts and coverage/metadata. Actual phase byte
  enforcement and proof-owned reclamation still belong to the following pass.
- Verdict: sound. Root approved shared grant ownership, the complete default
  footprint, and bounded reconstruction with explicit capacity refusal.
- Confidence: high for the allocator boundary; journal-backed reconstruction and
  cleanup authority are not claimed by the storage append tests alone.

## Persist completion once and authorize only registered controls

- When: completion and issuance pass, 2026-11-09.
- Choice: store the complete signed status under the existing operation lock.
  Later prefix advancement returns the original timestamp, prefix and signature.
  Source authorization compares the registered typed page or tombstone, verifies
  the current recovery output grant and commits explicit-negative historical
  mapping evidence before returning the signed capability.
- Gap: reconstructing a completion on every query changes its evidence; returning
  source authority before mapping commit creates another unrecoverable crash gap.
- Reach: uses existing issuer, registration transaction and mapping owner. No new
  signing grammar, mutable-assignment history or production freshness exemption
  is introduced. The finite completion capability window records issuance time;
  the agent verifies completion as historical evidence under retained key policy.
- Verdict: sound. One owner holds durable completion; the source issuer remains
  separate because its current-grant contract differs from historical completion.
- Confidence: high in the boundaries; guarded database assertions remain pending.

## Bound operation pages to the reserved publication footprint

- When: completion and issuance pass, 2026-11-09.
- Choice: registration admits at most four pages for its 1024 selected slots,
  matching 256-span coordinator packing. The frozen page ABI remains unchanged.
- Gap: accepting the wire grammar's larger page count admits publication work
  beyond the operation's fixed reserved control footprint.
- Reach: exact received aggregate limits still apply. Oversized legacy sources
  need a separate compatibility decision; this bound does not authorize dropping
  a copy-only interval or fabricating a loss span.
- Verdict: sound for bounded operations. Legacy partitioning remains explicitly
  unresolved until its representability and identity evidence are established.
- Confidence: high for the local admission invariant.

## Paired coverage, sender holds and retained source prefixes

- When: storage proof pass, 2026-11-09.
- Choice: save immutable phase pairs and block destination ACK application until
  both coverage copies are durable. For example, a copied record can reach the
  gateway immediately, but its early ACK is retried until the agent has saved
  proof that every old allocated slot is covered. If the process stops between
  those writes, exact repair completes the pair; a later phase never substitutes
  for the missing earlier record. The source gets a separate durable hold so the
  runtime can close its old session without suppressing destination delivery.
- Gap: a live sender can resolve copied data before coverage observes it. Merely
  retaining physical files does not preserve the existing sender-visible witness.
- Reach: the sender must save validated authoritative publication receipts before
  applying ordinary resolution, and must respect the source-only hold. Phase
  records are bounded to 64 steps and 1 MiB per copy; repeated failures retain
  evidence and surface capacity refusal rather than promising unlimited retries.
- Verdict: sound; root explicitly approved durable holds and exact frozen replay.
- Confidence: high.

- When: storage proof pass, 2026-11-09.
- Choice: cover the retained physical prefix even when the old sender already
  acknowledged it. A rejected record followed by a torn append still occupies
  source storage; copying it requires the original complete commit and binding,
  and its rejection evidence must survive eventual source deletion. Public copy
  witnesses remain strict for destinations, while the operation alone can read
  an already resolved source slot. The default archive budget increases from
  1 MiB to 11 MiB, making the aggregate reserve 32 MiB, to cover the bounded source
  record/evidence/sidecars plus 1 MiB certificate and archive headroom.
- Gap: using the resolved watermark as the deletion interval would omit retained
  records, and the legacy bounded quarantine can evict evidence at its cap.
- Reach: reclamation must measure/preflight the complete no-drop archive before
  destructive intent. Oversized legacy sources remain capacity-blocked and intact.
  This checkpoint retains source data and does not claim reclamation completion.
- Verdict: sound; root confirmed the physical base interval and approved the
  derived archive reserve. Actual archive enforcement remains the next slice.
- Confidence: high on the interval; medium on the framing headroom until the
  archive implementation and near-full generation proof establish its exact bound.

## Recovery uses its own acknowledged work queue

- When: consumer/catalog integration, 2026-11-09.
- Choice: recovery controls use the existing EdgeRecord provenance and ledger
  transaction, a dedicated WorkQueue stream and one shared durable consumer.
  Exact incomplete receipts can ACK after commit; complete-manifest mapping
  pending/blocked commits its evidence and NAKs without a delivery-count terminal
  path. Ledger replay revisits the durable operation; late-fenced audit delivery
  never applies authoritative repair.
- Gap: a limits-retained stream can remain full after every receipt is durable,
  preventing its recovery producer from progressing. WorkQueue removes ACKed
  receipts, while CNPG retains their exact replay evidence. Its single overlapping
  consumer rule is intentional; adding another recovery subscription is refused.
- Reach: startup rejects unsafe retention/discard/delivery overrides and budgets
  below 4 MiB. Defaults reserve 64 MiB; the tenant profile reserves 4 MiB. Small
  and tenant move capacity from primary bulk to preserve their total disk budget.
  Existing retention-risk reporting includes actual recovery backlog. MaxAge is
  finite, so journal replay remains required after broker expiry.
- Verdict: sound. Production grants now use the catalog's exact recovery lane;
  source authorization remains a separate registered-body issuance gate. The
  catalog's cost ceiling accounts for the complete manifest, not just one page.
- Confidence: pure/runtime/chart boundaries passed with three intentional
  negative controls. Receipt rollback, deferred replay and post-repair convergence
  are covered by boxed DB tests, pending guarded integration execution.

## Keep issuance proof outside assignment lifecycle

- When: retention audit, 2026-11-09.
- Choice: the mapping ledger has no TTL, destroy action, or foreign-key cascade
  from sweep assignments, groups or execution slots. Its original signed evidence
  and positive/negative projection remain unreclaimed until a complete safety
  witness covers recovery, redrive and lifecycle consumers.
- Gap: sweep-group destruction really cascades into assignments and execution
  slots; deriving historical mapping from those rows would erase recovery proof.
- Reach: extend that existing lifecycle test at the actual lease delivery owner.
  It records the historical execution/plan/range lookup, destroys the group,
  verifies assignment and slot deletion, then requires the identical lookup both
  before and after the revocation acknowledgment removes delivery state.
- Verdict: conservative and sound. This is retained evidence, not an implemented
  safe mapping-deletion API or a claim that elapsed time proves retention safety.
- Confidence: unit shard compilation and quality checks passed. The new lifecycle
  assertions still require guarded database execution before task 1.4 is complete.

## No-drop archive and bounded-source reclamation

- When: bounded-source archive/reclaim pass, 2026-11-09.
- Choice: preserve terminal acknowledgements, original commit/binding evidence,
  and rejected raw extents in a streamed archive before deletion. If corruption
  prevents identifying the rejected extent, preserve the full raw segment. A
  crash partway through the archive compares the already written prefix against
  the held original and appends the rest; a mismatching prefix stays untouched.
- Gap: the old quarantine deletes older entries or drops a new one at its cap,
  which cannot satisfy this recovery's preservation contract. Rewriting a full
  partial archive could also require a second full source-sized reservation.
- Reach: exact archive preflight can visibly refuse capacity, but never trades
  away evidence. The following delete intent joins the archive and coverage
  digests before publishing the existing physical reclaim layout.
- Verdict: sound; preserves evidence at every storage failure without inventing
  a separate destructive authority or a second accounting system.
- Confidence: high; interrupted prefixes and complete/insufficient budget cases are
  exercised at the real file and operation boundaries.

- When: bounded-source archive/reclaim pass, 2026-11-09.
- Choice: retain the active grant after recording signed completion, until the
  same storage owner has reclaimed fully acknowledged destinations and collected
  transient proof files. At a full disk, releasing it earlier can force cleanup
  to acquire a second fully backed reserve that the retained output has already
  consumed. The source-delete checkpoint therefore does not claim full-floor
  progress on its own.
- Gap: completion can arrive while copied records still await acknowledgement;
  moving every retained artifact to ordinary ownership would deadlock the next
  cleanup acquisition at the physical floor.
- Reach: the bounded lifecycle must finish under the original grant. Root approved
  a 42 MiB default reserve, including 21 MiB for both original and newly rejected
  destination archives, instead of adding a lossless deduplication format.
- Verdict: sound; keeps preserved evidence and the capacity to finish cleanup
  together. Oversized/flat legacy files remain retained and reported, with no
  compatibility implementation in this scope.
- Confidence: high on the ownership constraint; the near-full end-to-end proof
  remains required before this lifecycle is complete.

## Grant historical copies without recreating production authority

- When: rollover issuance pass, 2026-11-09.
- Choice: factor the existing signature boundary into a historical verifier and
  compose it with the same typed catalog constructors. The gateway pins one
  installed trust snapshot and verifies held registry admission. Core then joins
  the derived attribution to every registered physical coordinate and binding,
  and requires durable original positive or explicit-negative mapping evidence.
- Gap: requiring a current assignment would strand copies after its lifecycle
  deletes that row. Treating absence as a negative would instead invent history.
- Reach: the new capability permits only exact-byte rollover delivery for fifteen
  minutes; it grants no collection, source or production authority. Current key
  compromise, missing trust and unavailable registry history remain refusals.
  Existing ordinary renewal behavior is unchanged.
- Verdict: sound. One historical validation owner preserves the existing semantic
  and signature checks; one core owner joins durable intent to issuance evidence.
- Confidence: boundary and typed-body unit tests pass; database issuance assertions
  remain pending guarded integration execution.

- Review: kept rollover issuance separate from ordinary renewal because their
  authorization contracts differ; both use the existing capability signer.
  Historical and fresh constructors share typed body derivation, while retaining
  explicit freshness policy at their entry points. Ripwire's normalized generic
  pipeline matches and RPC-only caller gaps did not identify a missing owner.
  No lint suppression or caller-selected authorization mode was introduced.
## Reserve before dedicated generation metadata

- When: bounded generation publication pass, 2026-11-09.
- Choice: acquire and precharge through the shared generation publication owner,
  landing identity/marker/format bytes before the factory measures ordinary usage.
  Control generations attach to the original grant before their first write.
- Gap: writing even a small identity before acquisition consumes physical free
  bytes at the exact reserve floor and can prevent recovery from ever starting.
- Reach: creation refusal leaves the filesystem unchanged; a later publication
  failure keeps the slot and requires retained inventory on restart. Dedicated
  generations stay outside ordinary producer selection.
- Verdict: sound; no second ledger, no unreserved creation compatibility wrapper.
- Confidence: high; the physical-byte probe test passes at the exact floor and a
  deliberate acquisition-after-metadata mutation fails because bytes were written
  by an unbacked attempt.
## Deleted assignment recovery drains only to audit

- When: gateway recovery boundary pass, 2026-11-09.
- Choice: an original assignment can be deleted while its immutable record and
  original issuance evidence remain. A current rollover capability for the exact
  registered event, raw hash and destination permits that record to drain only
  to the audit stream. Without that capability, or with only an ordinary renewal,
  the gateway continues to withhold it. An epoch ahead of a known producer fence
  also remains withheld.
- Gap: replacement-delivery authority needed a rule for an absent current fence;
  the existing trust snapshot contains live assignments, not tombstone fences.
- Reach: core must join immutable registration and original mapping evidence
  before issuing rollover authority. Retained key validity, authenticated scope,
  typed payload and held registry admission remain mandatory. Audit delivery
  cannot run the primary projector or manufacture current execution authority.
- Verdict: sound. The root implementer approved this narrow interpretation of
  Decision 3; deleted lifecycle rows do not strand an otherwise valid recovery.
- Confidence: high.

## Count exact recovery transport overhead before publication

- When: gateway recovery boundary pass, 2026-11-09.
- Choice: a valid small page can still be wrapped in excessive repeated protobuf
  fields or oversized gateway headers. The gateway allows at most 16 KiB above
  the decoded control body in the exact record, and at most 16 KiB for the NATS
  subject plus serialized headers, including Gnat's framing bytes. Header refusal
  happens before credit reservation and broker publication.
- Gap: the bounded coordinator's control-byte budget needed a matching transport
  envelope bound to show that the reserved recovery stream can accept an attempt.
- Reach: four pages plus one tombstone remain bounded independently of compressed
  payload representation and runtime gateway-id configuration. Header failures
  withhold delivery; they do not invent a terminal broker acknowledgement.
- Verdict: sound. These bounds complete the approved finite recovery capacity
  calculation using the actual header serializer rather than a character estimate.
- Confidence: high.

## Compact completion owns proof collection

- When: same-grant completion pass, 2026-11-09.
- Choice: retain one paired compact intent and completion marker plus mandatory
  archives; reopen those commitments for cleanup even after freeze/phase GC.
  Output cleanup consumes the original grant and never enters evicting quarantine.
- Gap: journal collection can crash before releasing accounting. Depending on the
  collected journal to restart would permanently wedge the active reservation.
  Ordinary reclaim after source charge transfer could also bypass archival when
  another recovery concurrency slot happens to be available.
- Reach: the compact owner carries exact source/output identity and checkpoint
  commitments; current trust validation still gates each cleanup invocation.
  Ordinary reclaim checks active operation ownership, not just held byte charges.
- Verdict: sound; compact evidence proves restart progress without making a later
  phase stand in for missing prerequisite bytes, and mandatory archives stay charged.
- Confidence: high on the storage lifecycle: tested collection-before-final-marker
  crash, missing compact-copy repair, rejected raw retention, and a deliberate
  current-validation bypass that makes the restart regression fail.
