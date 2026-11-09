# Recovery foundation choices

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
