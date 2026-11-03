# Change: Add scan sharding and MTR capacity, policy and UI

## Why

`move-agent-telemetry-to-edge-records` moves every MTR trace onto an agent-scheduled contract (task 3.1). What it does not cover is policy: sharding large sweeps, admitting scans against downstream backlog, budgeting MTR targets and probe rates, choosing which targets get deep traces, the path-graph projection, and showing an on-demand trace in the UI once it is durable.

Split out of `unify-sweep-results-proto` on 2026-11-02, when that change's task list was reconciled against `staging`. The requirements and tasks below moved verbatim; none of them blocks shipping the durable edge pipeline or archiving `unify-sweep-results-proto`.

## What Changes

- Shard large sweeps deterministically and admit scans against spool, stream and database backlog.
- Give MTR explicit per-site and global budgets plus sampling and incident-triggered policies.
- Project committed traces into the AGE path graph through an idempotent outbox, with identity keys in `mtr_traces`/`mtr_hops`.
- Resolve an on-demand trace in the UI after durable projection, with pending, failed, quarantined and timeout states.

## Impact

- Affected specs: age-graph, build-web-ui, mtr-diagnostics, sweep-jobs.
- Affected code: sweep scheduler, agent MTR scheduling, EventWriter MTR projector, web-ng MTR views.
- Depends on: `move-agent-telemetry-to-edge-records` task 3.1 (agent-scheduled MTR contract).
