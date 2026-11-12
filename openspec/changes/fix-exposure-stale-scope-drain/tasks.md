# Tasks: skip stale exposure scopes at claim time

- [x] 1. Spec (this change): proposal, design, spec deltas; `openspec validate fix-exposure-stale-scope-drain --strict` green with no errors; no conflict with `fix-exposure-publisher-drain` (extends its publisher requirement, does not restate it).
- [x] 2. Fail-first DB tests on `codex_*` scratch databases: claimed stale scope completes with no new generation; scope with no newer generation publishes; scope with only a newer aborted generation publishes; global generation fulfills an integer scope; nil scope never skips; legacy sweep adopts (fleet-wide when scopeless) then completes, invalid rows cancel. Existing publisher/scopes suites green.
- [x] 3. `Scopes.fulfilled_since_request?/2` + generation-less completion requiring the `publishing` claim; publisher `drive_scope` checks fulfillment after claim, before `publish_scope`; serial order, lock, and budgets untouched.
- [x] 4. Publisher `adopt_orphans` sweeps legacy-format `ExposureSnapshotWorker` Oban rows with the execution-time rule (adopt-if-absent, fleet-wide when scopeless, then complete; cancel outright when invalid); execution-time clause unchanged.
- [x] 5. Format + quality gates (`mix format`, `git diff --check`, Bazel `--config=remote` quality/test targets for the touched area), then no-mistakes gate (reviewer not claude), PR, `--merge`.
- [ ] 6. Demo measurement: pending-scope count and completions per minute from scope rows written after the rollout vs the ~1/minute pre-fix baseline, reported with row evidence; plus genuine-vs-skipped breakdown.
