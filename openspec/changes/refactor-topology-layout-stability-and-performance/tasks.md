## 1. Layout Stability
- [ ] 1.1 Define deterministic layout invariants for unchanged topology revisions.
- [ ] 1.2 Add infrastructure-anchor weighting/priority strategy compatible with current snapshot contracts.

## 2. Performance
- [ ] 2.1 Profile and reduce expensive per-snapshot layout computations.
- [ ] 2.2 Add bounded compute budgets for layout refresh paths.

## 3. Verification
- [ ] 3.1 Add regression tests for stable coordinates across overlay-only updates.
- [ ] 3.2 Add performance baselines for high-node-count snapshots.
- [ ] 3.3 Run `openspec validate refactor-topology-layout-stability-and-performance --strict`.
