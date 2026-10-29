## 0. Design gate

- [x] 0.1 Record measured bottlenecks and propose a replacement design without changing runtime code.
- [x] 0.2 Obtain review of cross-view dimension proofs, source-local generated identity, recovery fencing, batched readiness and component screens. Approved by direct product-owner response on 2026-10-28.

## 1. Disabled prototype (requires 0.2)

The implemented controls passed in the approved hosted run. Partial tasks stay
unchecked where process-death or live delivery/finalization validation remains
outstanding. See [prototype.md](prototype.md) for the exact scope and failed
performance screen.

- [x] 1.1 Map every restore/rebuild entry point and implement fence invalidation in the isolated harness. Verify generated hash behavior on the supported PostgreSQL image, including equal-sequence edits. Production hook integration remains an adoption obligation.
- [x] 1.2 Add bounded run/proof control metadata and exact-version dimension verification. Preserve terminal references, evidence age and per-device deferral.
- [x] 1.3 Implement one current v1 hash and independent normalized replay validation. Differentially verify SQL against the existing decoder/digest oracle.
- [ ] 1.4 Batch admission and readiness with unchanged predicates. Preserve per-device locks, durable repair ownership and crash-safe enumeration.
- [ ] 1.5 Add only missing behavior controls to the owning DB/capacity suites after test-audit review. Validate live 40/41 sequencing, proof expiry, restore fencing, partial failures and cleanup.

## 2. Measurement gate (separate run authorization)

- [x] 2.1 Request a bounded hosted run allocation and schedule for synthetic scratch schemas; copy protected physical `.bazelrc.remote` into every author/gate worktree. No local build fallback. One allocation approved directly and completed.
- [ ] 2.2 Measure dimensions, fact comparison and full orchestration against design budgets with two workers, at most 32 devices/cohort and existing timeout/page limits. Report cold/warm runs and resource use.
- [x] 2.3 Stop on a failed component screen. If screens and correctness pass, request the 20,000-host / 50-million-active-fact run separately. Record all cleanup evidence. Fact screen failed; no repeat/fleet run. Warehouse schemas/grants absent and canonical CNPG teardown/release passed.

Task 2.2 has first-run measurements only. The failed screen deliberately prevents
repeat execution; the warmed fixture is not a cold-database result. No rerun is
authorized merely to fill this checkbox.

## 3. Adoption (separate approval)

- [x] 3.1 Publish measured results through no-mistakes with current-head hosted checks. PR #6171 merged with all 18 hosted checks passing; the publication-only Test exception did not waive capacity. Parent task 1.6 remains open.
- [ ] 3.2 Review production migration/backfill cost, restore integration and rollback. Adopt only through a separately approved runtime PR and scheduled rollout.

## 4. Explicitly approved bounded diagnostic follow-up

- [x] 4.1 Record the later native fix approval for one separate small-profile hosted diagnostic allocation. Preserve the original failed report and source attribution.
- [x] 4.2 Add separate inclusive phase timings, batch sorted per-device session-lock calls, and remove the second measurement. Preserve two workers, 32-device cohorts, codec, snapshots, deadlines and all performance assertions.
- [x] 4.3 Add actual source/coverage plan capture outside measured intervals and extend the existing contention control for lock retention/release and caller-order outcomes.
- [x] 4.4 Complete prerequisite remote format/compile/core-quality through the outer executor, then execute the committed exact-tree hosted small-profile verification using the canonical lifecycle and fresh scratch schema. Correction execution source: `59385424a42dfde36bbf309d7bc7e982a8bd494d`.
- [x] 4.5 Inspect actual diagnostic and corrected plans for physical amplification, intermediate widths/copies/spills and replay cost. Evidence confirmed per-device generation lookup and reduced wide materialization; no further tuning is authorized.
- [x] 4.6 Record separate measured/control verdicts and verified row/schema/grant/observer/teardown/release cleanup; refresh the portable result with the corrected measurement, preserving both historical failures. See [corrected result](prototype.md#completed-post-correction-verification).

All approved allocations for this change are spent. The corrected fact screen
still failed; measured orchestration remains above budget and its assertion was
not reached. This change authorizes no repetition or fleet run. PR #6171 merged
under the publication-only Test exception in task 3.1; that exception did not
waive capacity. The later shared-scan diagnostic is recorded in
[refactor-exposure-cohort-source-scan](../refactor-exposure-cohort-source-scan/tasks.md).
Cold, repeat, fleet, process-death, and adoption work remain open, as does
parent task 1.6.
