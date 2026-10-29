## 0. Design review

- [x] 0.1 Record the failed shared-scan result and trace validation/projection ownership.
- [x] 0.2 Define content binding, independent checks, preparation and recovery semantics.
- [ ] 0.3 Obtain approval for a disabled receipt prototype before implementation.

## 1. Disabled prototype after approval

- [ ] 1.1 Add scratch-only generated source fingerprint and bounded receipt metadata.
- [ ] 1.2 Prepare receipts with the existing decoder and digest; condition persistence on unchanged source content.
- [ ] 1.3 Use bound receipts in the manual audit while retaining independent current and warehouse hashes.
- [ ] 1.4 Extend the owning harness after test-audit: stale/invalid receipts, current-only drift, duplicate facts, terminal references, revision change, concurrent preparation and deletion.
- [ ] 1.5 Verify no sequence/outbox side effects, finite preparation progress, proof age, recovery fences and before/after-finalization live changes.
- [ ] 1.6 Run ordinary remote validation and no-mistakes; do not dispatch a manual benchmark without a separate allocation.

## 2. Separately authorized measurement

- [ ] 2.1 Bind an exact-commit allocation with source-write/storage limits fixed in advance.
- [ ] 2.2 Measure cold preparation, steady state, live churn, physical selectivity and complete audit costs; stop on a failed screen.
- [ ] 2.3 Independently verify scratch cleanup and publish the actual result, including negative findings.
- [ ] 2.4 Request a fleet run only if the bounded gates pass; keep parent task 1.6 open until its full gate passes.

## 3. Separate adoption decision

- [ ] 3.1 Review production Ash resources, migration/backfill cost, preparation ownership, permissions, upgrade/restore coverage and rollback.
- [ ] 3.2 Reconcile pending exposure deltas and obtain explicit runtime adoption approval.
