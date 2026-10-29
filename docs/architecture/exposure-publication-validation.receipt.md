# Exposure publication validation proposal receipt

This is a proposed design, not an implemented or measured optimization.
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
| Proposal HTML | `36ebad54277da933a62ea1ab8ea10b3fc6ad2000f522997414c0a530e4a2cf78` |

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

No runtime code, test code, migration or benchmark was changed. No product
tests, manual hosted measurement or fleet run were performed for this design
checkpoint. No-mistakes publication and required remote checks remain ahead
of any PR. The parent exposure capacity and protocol gates remain open.
