## 0. Proposal

- [x] 0.1 Reconcile merged PR #6171 and record measured source/coverage amplification, existing indexes and writer contracts.
- [x] 0.2 Prepare the bounded source-scan design, alternatives and explicit approval boundary.
- [x] 0.3 Review and approve the disabled implementation. Direct product-owner approval on 2026-10-29; no measurement allocation included.

## 1. Disabled implementation (requires 0.3)

- [x] 1.1 Share cohort selection, validation and compact typed projection between fact and reference consumers in the same finite view.
- [x] 1.2 Resolve each distinct cohort dimension key once; preserve per-device generation and age checks, terminal references and fact multiplicity.
- [x] 1.3 Apply test-audit and author missing controls in the owning harness; retain the existing decoder/digest oracle and failure semantics. Execution remains in 2.2.
- [x] 1.4 Attribute fused statement cost conservatively to the fact screen; retain complete orchestration timing, logical-work counters and physical-plan diagnostics.
- [ ] 1.5 Complete remote review, required normal unit/quality checks and publication through no-mistakes. Exact-head remote unit tests passed 487 targets with two Swift skips, and explicit remote assembly of the manual target passed. `.bazelrc.remote` is present as a physical mode 0600 copy. `.bazelrc.local` is absent and was not copied. Publication remains blocked pending disposition of the negative measurement.

## 2. Measurement (separate allocation)

- [x] 2.1 Request and complete one bounded hosted allocation for the reviewed commit, the existing small profile, one run, and cleanup. Fleet selectivity and mostly-unique-key cases were outside that allocation.
- [ ] 2.2 Verify one physical cohort read, compact materialization, distinct-key lookup work and correctness; record truthful timings and resource evidence. The single run observed physical sharing, compact widths, fewer lookups, and passing correctness controls, and recorded a negative timing result. Fleet selectivity and mostly-unique-key evidence are still missing, so this task stays open.
- [x] 2.3 Stop on either component-screen failure and verify cleanup. The fact screen failed at about 16.5 seconds against 6 seconds. Recorded orchestration was about 2.0 seconds against 0.9 seconds, and its assertion was not reached. Cleanup was independently verified. No fleet request follows.

## 3. Delivery and adoption

- [ ] 3.1 Publish measured results with current-head hosted checks and portable evidence. Keep parent task 1.6 open pending the real fleet gate.
- [ ] 3.2 Review any runtime adoption separately; complete outstanding crash/live-finalization controls and scheduled rollout requirements.
