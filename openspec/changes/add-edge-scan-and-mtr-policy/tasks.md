# Tasks: Add scan sharding and MTR capacity, policy and UI

## 1. Moved from `unify-sweep-results-proto`

Each task keeps its original text and number from `unify-sweep-results-proto`; its last line states what remained
when it moved.

- [ ] 1.1 (was `unify-sweep-results-proto` 6.3) Add deterministic scan shards and per-site/global MTR target,
  trace/probe-rate, concurrency, duration, interval-overlap, backlog, and
  storage admission budgets, including monotonic assignment fencing for
  reassigned target ranges.
- [ ] 1.2 (was `unify-sweep-results-proto` 6.4) Add baseline sampling/rotation, critical-target selection, and
  anomaly/incident-triggered MTR policies so fleet-wide deep tracing is an
  explicit capacity decision rather than an hourly default.
- [ ] 1.3 (was `unify-sweep-results-proto` 6.5) Preserve on-demand command/control responses as lightweight status and
  trace correlation; persist the full result only through the canonical MTR
  event lane, and update the UI to resolve the trace after EventWriter commit
  with pending, failed, quarantined, and timeout states.
  Remaining as of the move (2026-11-02): the persistence half moves with
  `move-agent-telemetry-to-edge-records` task 3.1; the UI pending, failed,
  quarantined and timeout states remain.

## 2. Validate

- [ ] 2.1 Run the Go, Elixir and Bazel suites for every touched target and
  `openspec validate add-edge-scan-and-mtr-policy --strict`.
