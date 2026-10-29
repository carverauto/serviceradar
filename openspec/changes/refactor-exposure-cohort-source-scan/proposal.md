# Proposal: one bounded source scan per exposure cohort

Status: disabled implementation approved by the product owner on 2026-10-29.
Implementation is prepared for review; executable measurements need a separate allocation.
Related epic: [#5745](https://github.com/carverauto/serviceradar/issues/5745).

## Why

The corrected audit prototype in [PR #6171](https://github.com/carverauto/serviceradar/pull/6171)
still missed its component screens. Fact comparison took about 12 seconds
against 6 seconds; orchestration took about 4.4 seconds against 0.9 seconds.
Its actual plans show a second assessment scan for dimension coverage, wide
JSON-bearing materialization, and repeated dimension lookups for references
shared by a cohort. These are concrete candidates for reducing work without
moving validation into a persistent cache.

## What Changes

- Produce fact summaries and required dimension references from one cohort
  assessment read in one finite source view.
- Materialize only the typed values needed downstream; keep the existing
  publication validator, normalization and v1 digest.
- Resolve each distinct dimension key once in that view, then apply its proof
  and evidence age to each dependent device.
- Require physical-work evidence and unchanged correctness controls before
  interpreting a timing improvement.

This approval covers a disabled manual-harness implementation only. Another hosted
allocation needs separate authorization with a concrete run count and profile.
It does not authorize a fleet run, runtime adoption, schema changes or rollout.

## Impact

This change supplements
[refactor-exposure-reconciliation-audit](../refactor-exposure-reconciliation-audit/design.md)
and its `exposure-intelligence` requirements. Parent exposure task 1.6 and all
capacity gates remain open.

Implementation touches the manual `exposure_audit_sql.exs`,
`exposure_audit_prototype.exs` and their owning controls.
Production writers, retained JSON publications, repair sequences, snapshot
markers, readiness predicates and warehouse schemas remain as specified.

See [design.md](design.md), [tasks.md](tasks.md), and the
[workflow](../../../docs/architecture/exposure-source-validation.html).
