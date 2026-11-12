# Tasks: fix exposure publisher drain

- [ ] 1. Spec amendment (this change): proposal, design, spec deltas, `openspec validate fix-exposure-publisher-drain --strict` green on arrival with no errors.
- [ ] 2. Publisher inline finalization: after `track_generation`, wait for the drain then call `Finalizer.step` inline with the D1 result mapping (ok with a complete generation → complete, otherwise wait; pending/incomplete/errors → bounded wait; input_missing → abort-fail path); budgets unchanged; tick untouched.
- [ ] 3. Legacy adopt-and-discard: queue-executed legacy `perform` (integer job id) completes when the scope row exists, inserts-if-absent plus ensure when absent, adopts the fleet-wide scope when `device_ord` is absent, cancels on an invalid scope; direct calls (nil id) keep the legacy contract byte-for-byte.
- [ ] 4. Clear `error` on `Scopes.complete/2`.
- [ ] 5. Fail-first DB tests on `codex_*` scratch databases: legacy adopt/discard/fleet-wide adopt/cancel; settle-mapping without StarRocks (incomplete, aborted, scan-error waits); existing publisher/scopes suites green.
- [ ] 6. Gate (`no-mistakes`, reviewer not claude), PR, `--merge`.
- [ ] 7. Demo measurement: completions per minute from scope rows written after the rollout vs the ~1/minute pre-fix baseline, reported with row evidence.
