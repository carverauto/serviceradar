## Context

The current MTR path is optimized for operator-driven single traces. The control plane dispatches individual `mtr.run` commands and the agent enforces a hard concurrency cap of two concurrent traces. That protects the agent for interactive work, but it makes large one-agent jobs fundamentally infeasible. A request for 2,400+ targets would either be rejected, crawl through the system as thousands of tiny commands, or force operators to distribute work manually across many agents.

The concrete requirement here is different:

- one connected agent must be able to own a bulk MTR job against at least 2,400 targets
- the job must queue and drain predictably on that agent
- the path must be materially faster than per-target cold-start execution
- the UI and control plane must expose progress and terminal states accurately
- recurring full-inventory jobs must not overlap blindly
- operators should get interval guidance from measured first-run throughput rather than guessing

This is also the right boundary for the feature. We do not need 2,400 simultaneous full traceroutes. We need a dedicated bulk execution system that accepts thousands of targets and runs them as quickly as the agent and network can safely sustain.

## Goals / Non-Goals

- Goals:
  - support a single bulk MTR job with at least 2,400 targets on one agent
  - isolate bulk execution from the existing ad-hoc `mtr.run` path
  - provide explicit queue, progress, completion, and failure semantics
  - reduce per-target overhead through long-lived worker and socket reuse
  - preserve protocol choice, hop detail, and existing MTR result ingestion
- Non-Goals:
  - execute 2,400 full traces simultaneously without bounds
  - remove the current interactive two-trace ad-hoc safety cap
  - require multiple agents for the initial bulk use case
  - redesign the entire MTR storage model before bulk execution exists

## Decisions

- Decision: add a new bulk command and job model instead of reusing individual `mtr.run` commands.
  - Rationale: thousands of independent control-stream commands create avoidable dispatch overhead, weak lifecycle semantics, and poor progress reporting.

- Decision: keep interactive and bulk execution separate.
  - Rationale: operators still need low-latency ad-hoc traces. Bulk jobs must not consume the same tiny concurrency pool or starve interactive troubleshooting.

- Decision: use an agent-local queue with bounded worker concurrency.
  - Rationale: the control plane should describe work at the job level, while the agent owns fine-grained scheduling, pacing, and fairness for actual probe execution.

- Decision: bulk execution must reuse long-lived resources where possible.
  - Rationale: repeatedly constructing tracers, resolvers, MMDB readers, and raw sockets for thousands of short-lived traces wastes the exact overhead we need to avoid. The bulk executor should keep reusable resources warm and amortize setup cost across the job.

- Decision: the UI must model bulk jobs explicitly.
  - Rationale: an operator launching 2,400 targets needs queued/running/completed/failed counts, cancellation, retry, and target-level drill-down. Reusing the current single-trace diagnostics table is not enough.

- Decision: recurring schedules must enforce no-overlap semantics by default.
  - Rationale: for large inventories, overlapping runs create misleading backlog, distorted timings, and self-inflicted load. The default behavior should skip or defer the next cycle until the current run finishes.

- Decision: the first completed bulk run should establish a baseline throughput profile for that agent + execution profile.
  - Rationale: operators need evidence-based interval guidance. The system should measure targets-per-minute, completion time, and failure rate before recommending recurring cadence.

- Decision: bulk execution should expose named execution profiles such as `fast`, `balanced`, and `deep`.
  - Rationale: raw concurrency alone does not make bulk MTR fast enough. Operators need simple, intentional tradeoffs between speed and trace depth without tuning every low-level probe knob.

## Architecture

### Control Plane

Add persistent bulk MTR job records and target records:

- `mtr_bulk_jobs`
  - job identity
  - requested agent
  - execution profile
  - aggregate counts
  - lifecycle status
  - submitted / started / completed timestamps
- `mtr_bulk_job_targets`
  - job identity
  - target
  - per-target status
  - attempt count
  - last error
  - resulting trace linkage

The control plane submits one bulk job to one agent, not one command per target. Progress and results flow back as job-scoped status updates plus ordinary trace ingestion.

### Agent

Add a dedicated bulk MTR executor:

- accepts one or more bulk jobs
- expands targets into an in-memory runnable queue
- applies bounded worker concurrency from a bulk execution profile
- keeps interactive `mtr.run` isolated from bulk capacity
- streams aggregate progress updates and per-target completion/failure

The bulk executor should share reusable components across workers:

- raw-socket receive/send infrastructure
- DNS resolver pool
- MMDB enricher
- allocator / scratch buffers where practical

This does not require one monolithic "trace 2,400 targets at once" algorithm. It requires a warm worker system that makes each target cheaper than a cold start and keeps the agent busy without overrunning the host.

### UI

The diagnostics UI should add:

- bulk submission from pasted targets, uploaded lists, or selected device cohorts
- explicit source-agent selection
- bulk execution profile selection
- job list with queued/running/completed/failed/canceled counts
- per-target detail and direct navigation to stored traces
- recurring schedule configuration with explicit no-overlap behavior
- first-run calibration results and recommended interval guidance

Terminal jobs must render as terminal. They must not retain active actions like cancel once the last target has reached a terminal state.

### Recurring Scheduling And Calibration

Recurring bulk MTR should behave like a bounded scheduler, not a blind cron trigger:

- if the previous run is still active at the next scheduled fire time, the default action is `skip`
- optional future modes may include `defer_until_clear` or `cancel_previous_then_start`, but `skip` should be the safe default
- each completed run should persist:
  - total targets
  - successful targets
  - failed / timed-out targets
  - wall-clock duration
  - effective targets-per-minute
  - execution profile and requested concurrency

The first successful run for a recurring profile acts as calibration. The UI should derive at least:

- measured job duration
- measured throughput
- a recommended minimum interval with headroom
- a warning when the configured interval is tighter than measured duration or recommended interval

## Risks / Trade-offs

- Higher worker concurrency improves throughput but raises packet-rate and CPU pressure.
  - Mitigation: execution profiles with bounded concurrency and adaptive defaults.

- One agent owning a large job is operationally simple but creates a single hot spot.
  - Mitigation: keep the control-plane model open to future multi-agent sharding without making it mandatory for the first version.

- Queue persistence on the control plane and execution on the agent can drift during disconnects or restarts.
  - Mitigation: make target states idempotent and resumable from control-plane truth.

## Migration Plan

1. Add bulk job persistence and UI surfaces behind the new capability.
2. Add agent support for the bulk command and queue model.
3. Wire progress and target completion back into the UI.
4. Keep existing interactive `mtr.run` behavior intact.

## Open Questions

- How much per-target retry behavior should be automatic before a target is marked failed?
- Should very large jobs be resumable after agent restart in v1, or is control-plane requeue sufficient?
