# Exposure source design review receipt

This receipt validates documentation, not product behavior or capacity.

- Diagram type: workflow.
- Deterministic validation: 9/9 showcase checks; 0 composition errors, 0 warnings.
- Automated browser evidence: passed for the delivered diagram.
- Perceptual review: passed; light and dark screenshots inspected at desktop sizes.
- Diagram correction rounds: 0.
- Portable proposal: exported with no unresolved local assets; four full source sections and embedded diagram render.
- Proposal browser review: original desktop light/dark and narrow checks passed. The approved implementation update was rechecked at 1440 x 900 dark and 500 x 900 light: all four sections expand, no horizontal overflow, and the embedded diagram renders. Both updated screenshots were inspected.
- Design source: existing ServiceRadar exposure review pages.
- Strict OpenSpec validation: new proposal and preceding audit change passed.
- The initial proposal checkpoint ran documentation checks only. Later remote unit checks are ordinary unit validation, not live-product scenarios. They do not waive the negative performance result. On 2026-10-29 the product owner approved a publication-only Test exception for that negative result. The exception does not accept the failed performance screens.

## Artifact bindings

- `exposure-source-validation.workflow.json`: `0aeb04f7b873bdf26a8c8d17223c47f55a324d8b1362b0fc51a1f5ca63c63142`.
- `exposure-source-validation.html`: `ed436d40a76345b4bdb344eae399ac86cd31b0db6f09af3a6e31668e8f19e417`.
- `exposure-source-validation.openspec.html`: `9053d5dd85f8a5aacccb436f0ba357b78685e9fad9e1a3c15bb9768598dfd66c`.

## Diagram browser scope

- 1440 x 900, light: containment passed.
- 1600 x 1000, light: containment passed.
- 1920 x 1080, light: containment passed.
- 2048 x 1320, light: containment passed.

The unchanged workflow records the design structure. Approval, the negative measurement, and open fleet work are recorded in the updated proposal.

## Remote unit and assembly

Commit `768bb8cebc1edcab762624c130c410eb9e6654ec` was tree-verified remotely. `.bazelrc.remote` is a physical mode 0600 file in this checkout. `.bazelrc.local` is absent and was not copied.

- Initial remote unit gate [80440558-3c53-4fd8-b7e4-d5ba6413ff57](https://carverauto.buildbuddy.io/invocation/80440558-3c53-4fd8-b7e4-d5ba6413ff57): 486 tests passed, one unrelated `camera_storage_test` failed with `transport_error`, and two Swift tests were skipped.
- Retry of that unchanged camera test passed. Pre-rebase remote unit gate [54111622-354a-4dc3-9cc2-3a63c9274ed4](https://carverauto.buildbuddy.io/invocation/54111622-354a-4dc3-9cc2-3a63c9274ed4): 487 tests passed and two Swift tests were skipped. This receipt predates the rebased head.
- Exact-head remote unit gate [93810e7f-fdf4-4376-aee7-603607ceb341](https://carverauto.buildbuddy.io/invocation/93810e7f-fdf4-4376-aee7-603607ceb341): 487 tests passed and two Swift tests were skipped.
- Explicit remote assembly of `//elixir/serviceradar_core:exposure_reconciliation_audit` passed on that tree. Assembly does not execute the SQL or its controls. These unit and assembly results are separate from the hosted behavior controls below.

## Hosted measurement

One allocation was consumed and cleaned up. Hosted execution [b7ddf7ab-a7ad-4b94-95ef-0c8164395730](https://carverauto.buildbuddy.io/invocation/b7ddf7ab-a7ad-4b94-95ef-0c8164395730) matched all 200 synthetic devices and passed the implemented correctness controls, including physical sharing of the assessment read. It failed the 6-second fact assertion at about 16.5 seconds. Recorded orchestration was about 2.0 seconds against 0.9 seconds, and that assertion was not reached. The whole audit was about 34 seconds, compared with about 31 seconds previously. Changed accounting prevents reading the fact and orchestration columns as isolated improvements.

Cleanup was verified independently. Scratch tables were empty before removal. Schemas, temporary grants, and run-owned CNPG fixture databases were removed. Generation release passed. No cluster was created or removed. The run used existing shared infrastructure. Both execution locations had zero run-owned databases. No raw plan, address, or operational credential is recorded here.

This is a negative performance result. It is not a pass, a waiver, or a fleet result. Task 2.2 stays open for fleet selectivity and mostly-unique-key evidence. Parent task 1.6, fleet execution, and adoption stay open. No further allocation is approved. The publication-only exception covers publishing this negative report. It does not accept the performance screens. The wording corrections in the portable proposal, including the 2026-10-30 pointers to the later receipt prototype, have not had a new perceptual browser pass; earlier screenshot receipts remain historical.
