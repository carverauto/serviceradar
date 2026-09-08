## 1. Design

- [x] 1.1 Define the bulk MTR job contract, including job state, target state, queue semantics, and progress reporting.
- [x] 1.2 Define the dedicated agent execution model for bulk MTR, including worker concurrency, socket/resource reuse, fairness against ad-hoc traces, and failure behavior.
- [x] 1.3 Define the control-plane persistence model for bulk jobs, per-target results, retries, and cancellation.

## 2. Backend

- [x] 2.1 Add core resources, migrations, and actions for bulk MTR jobs and target rows.
- [x] 2.2 Add command-dispatch support for bulk MTR jobs without relying on one `mtr.run` command per target.
- [x] 2.3 Implement agent-side bulk queueing, bounded worker pools, and progress/result emission.
- [x] 2.4 Rework MTR execution plumbing to support pooled raw-socket and enrichment resources for high-throughput bulk runs.
- [x] 2.5 Add cancellation, retry, timeout, and terminal-state handling for bulk jobs and targets.
- [x] 2.6 Add recurring job scheduling with overlap prevention and persisted run-history metrics.
- [x] 2.7 Add first-run calibration and throughput measurement for representative inventory jobs.

## 3. UI

- [x] 3.1 Add a bulk MTR submission workflow that supports large target lists, explicit source-agent selection, and execution-profile controls.
- [x] 3.2 Add diagnostics views for job progress, queued/running/completed/failed counts, and per-target drill-down.
- [x] 3.3 Ensure terminal jobs render as terminal in the UI and no longer offer active-job actions.
- [x] 3.4 Add UI guidance and validation for recurring schedules, including warnings when configured intervals are tighter than measured job duration or safe throughput.

## 4. Validation

- [x] 4.1 Add agent and core tests for queueing, fairness, cancellation, and high-target-count job acceptance.
- [x] 4.2 Add UI tests for bulk submission and terminal-state rendering.
- [x] 4.3 Validate the OpenSpec change with `openspec validate add-bulk-queued-mtr-diagnostics --strict`.
