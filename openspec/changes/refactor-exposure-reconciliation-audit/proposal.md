# Proposal: bounded exposure audit with shared dimension evidence

Status: proposed; design review only. Related epic: [#5745](https://github.com/carverauto/serviceradar/issues/5745).

## Why

Exposure reconciliation still misses its fleet capacity gate. The completed
Decision 27 experiment passed its tested correctness controls, but the best
200-device / 500,000-active-fact run took about 64 seconds against its roughly
9-second rate screen. Repeated dimension verification and CNPG digest work both
remain material. Increasing the cohort alone did not solve either cost.

The [measured report](https://agentboard.farm01.carverauto.dev/documents/220)
records the experiment and its limits. This proposal does not claim a speedup.

## What Changes

- Verify each published dimension content version once per bounded audit run,
  then reuse that evidence only for the exact source version a cohort observes.
- Compute the existing current-fact digest once in the database. Check retained
  replay independently through normalized field comparison, without building a
  second JSON after-image or hashing it again.
- Admit bounded cohorts and evaluate readiness for those devices together,
  preserving per-device results, recovery obligations and generation fences.
- Measure the entire orchestration path against an explicit time budget before
  requesting a fleet run. The 15-minute fleet reconciliation limit is unchanged.

## Impact

This is a subordinate proposal to
[`add-srql-exposure-intelligence`](../add-srql-exposure-intelligence/design.md),
not an alternative exposure feature. It adds requirements to that capability;
it does not replace its snapshot, delivery, retention, freshness or repair
contracts. The parent proposal remains unarchived. The separate experiment
report publication is not modified by this branch.

Possible implementation surfaces are `ExposureReconciliationComparison`,
`ExposureReconciliationWorker`, `ExposureReadiness`, dimension source metadata,
Ash resources/migrations for audit control records, and the existing capacity
harness. No CNPG exposure projection, telemetry path, warehouse write bypass,
public query API, ordinal width or fact digest format changes are proposed.

## Approval Requested

Approve this design for a bounded, disabled prototype and its validation plan,
including cross-view reuse of content-bound dimension evidence and the proposed
component budgets. This approval would permit prototype implementation only.
Hosted run allocation/scheduling, a 50-million-row run, production adoption and
rollout require their subsequent explicit approvals. Task 1.6 remains open.

See [design.md](design.md), [tasks.md](tasks.md) and the
[workflow diagram](../../../docs/architecture/exposure-reconciliation-audit.html).
