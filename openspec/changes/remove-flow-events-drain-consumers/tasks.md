# Tasks: remove flow events-drain consumers

- [x] 1. Spec (this change): proposal, design, spec deltas;
  `openspec validate remove-flow-events-drain-consumers --strict` green.
  Checked pending deltas for repeated wording: only
  `restore-anomaly-alerting-and-surfacing` 8.3a names this contract, and this
  change implements it (that change ticks the box). No `specs/` requirement
  repeats the drain wording, so no MODIFIED delta is needed.
- [x] 2. Fail-first regression tests (invented fixtures only): `load_flow()`
  emits no `best_effort` / `_EVENTS_DRAIN` entries; release (elx) runtime
  config never provisions or consumes `flow.attributed.>`; all six fail on the
  unfixed tree for the intended reason. Reworked existing drain assertions to
  the absence contract; hand-built generic-machinery fixtures kept.
- [x] 3. Implement: delete `maybe_append_events_drain_streams/1` and the
  `EVENT_WRITER_FLOW_DRAIN_EVENTS` read; delete `ATTRIBUTED_FLOW` from the
  elx release runtime; correct the `extra_flow_subjects` live-only comment;
  retire orphan `events` flow-drain durables and `attributed-flow` durables
  through `Config.load/0` `retired_consumers` (`ConsumerReconciler`);
  update `docs/docs/netflow.md`.
- [x] 4. Format + quality gates (`git diff --check`, Bazel
  `--config=remote` quality/test targets for the touched area), then
  no-mistakes gate (reviewer not claude), PR, `--merge`.
- [ ] 5. Demo verification after rollout: core startup logs contain none of
  the three warnings; all EventWriter consumers bind on their declared
  streams.
