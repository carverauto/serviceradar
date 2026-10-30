# Exposure publication validation proposal receipt

The product owner approved a disabled scratch prototype on 2026-10-29.
The implementation is authored; it is not a measured optimization.
Source baseline: `c29846f422a6cf68baa122bfb36058b0fc57f7d2`.

## Artifacts

- [Complete proposal review](exposure-publication-validation.openspec.html)
- [Workflow](exposure-publication-validation.html)
- [Workflow source](exposure-publication-validation.workflow.json)
- [OpenSpec source](../../openspec/changes/add-exposure-publication-validation-receipts/design.md)

| Artifact | SHA-256 |
| --- | --- |
| Workflow source | `4713a35af2bd85c3213217886a9914b39e718f8e6b715fafa6f61a945e1f8b85` |
| Workflow HTML | `de4dfddbaeab1fb47f8edd48bb8690001ae5ab83eff3f4f57e2897db448079a1` |
| Proposal HTML | `e02a6472cac8dc8743a5c45cd0edea00cdce9c0554c15cae9a6fa3910f19adf6` |

## Validation

- Strict OpenSpec validation passed for this change.
- Archify workflow delivery passed all 9 showcase checks, with zero errors
  and warnings. Two geometry correction rounds reduced the diagram to four
  columns; the final lane label distinguishes independent inputs correctly.
- Automated browser evidence passed at 1440x900, 1600x1000, 1920x1080 and
  2048x1320. Light/dark captures passed. The final rendered diagram was
  visually inspected; labels, routes and cards are readable.
- The complete proposal was checked at 1440x900 light and 500x900 dark with
  all four source sections expanded. No horizontal overflow or broken local
  links were found. The inline workflow loaded. Screenshots were inspected.
- The portable report uses ServiceRadar Web-NG's brand green and light/dark
  surface colors. Export reported zero unresolved local assets.
- Markdown is ASCII and `git diff --check` passed. The worktree has a
  physical, mode-0600 `.bazelrc.remote` copy matching the primary checkout;
  `.bazelrc.local` was absent at the source.

## Prototype validation

- The existing manual target assembled remotely. This builds its declared
  inputs; it does not execute the scratch migration or database controls.
- Remote core formatting and [quality validation](https://carverauto.buildbuddy.io/invocation/62bbd3c8-3274-4f2f-bed1-9204887332bb) passed.
- The [repository-wide remote unit run](https://carverauto.buildbuddy.io/invocation/4de98a99-cc59-4156-a40e-83efccf523dc)
  passed: 488 targets passed, 2 skipped. The manual audit is excluded.
- The updated portable proposal passed desktop and narrow-screen checks with
  all source sections expanded; screenshots were inspected. Export has zero
  unresolved local assets. The unchanged workflow again passed all 9 checks.
- Ripwire flagged added scratch schema/control volume, recent churn and the
  second use of the batch array-upsert idiom. These are reviewed trade-offs,
  not a zero-debt result; the controls remain with their owning harness.

No production runtime code or production migration changed. New database
controls are authored but unexecuted. No manual hosted measurement, fleet run,
rollout, source-write/WAL/storage measurement or live-finalization validation
was performed. No-mistakes publication remains pending. The parent exposure
capacity and protocol gates remain open.
