# Exposure publication validation proposal receipt

The product owner approved a disabled scratch prototype on 2026-10-29.
The implementation is authored; it is not a measured optimization.
Proposal source baseline: `c29846f422a6cf68baa122bfb36058b0fc57f7d2`.
Publishing head: `5d28b659ea499da0ed4b6b5bf7af22d4e6728b96`
on staging `64e91d0c3ab6dfccdfb5e2019dc4d6c8ac772828`.

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

- Ordinary remote unit validation of publishing head `5d28b659` passed
  488 tests and skipped 2:
  `//build/arrow_swift:ios_compile_test` and
  `//build/arrow_swift:swift_regression_test`.
  [Invocation](https://app.buildbuddy.io/invocation/675cb465-5eb2-481c-aa59-b2fe6cae4cf1).
  The manual audit target was not selected. This run does not execute the
  scratch migration, SQL, or warehouse controls.
- The implementation commit's manual-target assembly, [core quality run](https://carverauto.buildbuddy.io/invocation/62bbd3c8-3274-4f2f-bed1-9204887332bb),
  and [unit run](https://carverauto.buildbuddy.io/invocation/4de98a99-cc59-4156-a40e-83efccf523dc)
  predate the review fixes and this head. They do not certify it. Assembly
  builds declared inputs and does not execute the scratch migration.
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
