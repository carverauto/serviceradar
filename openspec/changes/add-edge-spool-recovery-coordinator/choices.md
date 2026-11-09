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
