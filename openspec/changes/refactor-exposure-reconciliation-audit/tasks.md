## 0. Design gate

- [x] 0.1 Record measured bottlenecks and propose a replacement design without changing runtime code.
- [x] 0.2 Obtain review of cross-view dimension proofs, source-local generated identity, recovery fencing, batched readiness and component screens. Approved by direct product-owner response on 2026-10-28.

## 1. Disabled prototype (requires 0.2)

Source for 1.1-1.5 is present in the manual harness. These items stay unchecked
until their behavioral assertions run successfully. See [prototype.md](prototype.md).

- [ ] 1.1 Map every restore/rebuild entry point and implement fence invalidation in the isolated harness. Verify generated hash behavior on the supported PostgreSQL image, including equal-sequence edits.
- [ ] 1.2 Add bounded run/proof control metadata and exact-version dimension verification. Preserve terminal references, evidence age and per-device deferral.
- [ ] 1.3 Implement one current v1 hash and independent normalized replay validation. Differentially verify SQL against the existing decoder/digest oracle.
- [ ] 1.4 Batch admission and readiness with unchanged predicates. Preserve per-device locks, durable repair ownership and crash-safe enumeration.
- [ ] 1.5 Add only missing behavior controls to the owning DB/capacity suites after test-audit review. Validate live 40/41 sequencing, proof expiry, restore fencing, partial failures and cleanup.

## 2. Measurement gate (separate run authorization)

- [ ] 2.1 Request a bounded hosted run allocation and schedule for synthetic scratch schemas; copy protected physical `.bazelrc.remote` into every author/gate worktree. No local build fallback.
- [ ] 2.2 Measure dimensions, fact comparison and full orchestration against design budgets with two workers, at most 32 devices/cohort and existing timeout/page limits. Report cold/warm runs and resource use.
- [ ] 2.3 Stop on a failed component screen. If screens and correctness pass, request the 20,000-host / 50-million-active-fact run separately. Record all cleanup evidence.

## 3. Adoption (separate approval)

- [ ] 3.1 Publish measured results through no-mistakes with current-head hosted checks. Keep parent task 1.6 open unless the actual fleet gate passes.
- [ ] 3.2 Review production migration/backfill cost, restore integration and rollback. Adopt only through a separately approved runtime PR and scheduled rollout.
