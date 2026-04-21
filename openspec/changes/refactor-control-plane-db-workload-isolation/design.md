## Context
The current architecture uses per-service Ecto pools, but `core-elx` still multiplexes too many distinct workload types through the same database budget. In practice, Oban job execution, scheduler loops, enrichment refreshes, reconciliation work, MTR automation, and interactive control-plane persistence all contend for the same repo/pool. This allows optional or low-priority work to delay critical workflows.

Recent runtime evidence showed:
- bulk MTR commands were dispatched to the agent and completed there, but `AgentCommandStatusHandler` failed to persist target/result updates while `core-elx` was saturated by maintenance and integrations work
- analytics and control-plane pages timed out behind DB queue pressure
- the stack remained noisy even on a nearly empty install, proving the problem is workload budgeting rather than customer scale alone

The design goal is not to hide the issue by disabling features. The system must keep major subsystems enabled while preserving predictable control-plane behavior.

## Goals
- Preserve control-plane critical workflows under background load.
- Support feature-complete operation in Docker Compose and larger deployments.
- Make DB and queue budgets explicit and observable.
- Prevent background job concurrency from exceeding the DB capacity assigned to that workload class.

## Non-Goals
- Replacing Postgres/CNPG with a different storage engine.
- Making all background work synchronous.
- Treating MTR as a privileged or premium-only subsystem.
- Solving scaling solely by increasing `max_connections`.

## Decision
Adopt explicit database workload isolation and budget governance.

The implementation should separate at least two workload classes:
- `control-plane`
  - interactive/operator reads and mutations
  - auth/session flows
  - agent heartbeats and status updates
  - MTR dispatch/result persistence and comparable diagnostics/control workflows
- `background`
  - Oban-driven maintenance and cron work
  - enrichment/reconciliation refresh loops
  - optional analytics/materialization refreshes
  - long-running or bursty scheduler-owned jobs

The preferred mechanism is separate repos/pools or an equivalent architecture that provides hard isolation rather than soft prioritization inside a single shared pool.

## Rationale
Using a single repo/pool forces unrelated workloads to compete for checkout slots, transaction time, and queue budget. Even with tuned pool sizes, queue widths and schedulers can still overwhelm the shared budget. Hard workload isolation keeps critical writes and reads alive while still permitting background jobs to run.

This also scales more cleanly:
- small deployments can use small but explicit budgets for both classes
- larger deployments can scale each class independently
- queue widths can be sized against the background budget instead of the total service budget

## Required Runtime Properties

### 1. Critical-path DB budget is reserved
Control-plane workflows must continue to make forward progress while background jobs are active. Background saturation must not block command status persistence, heartbeat updates, or comparable operator-facing flows.

### 2. Queue widths map to capacity
Oban queue widths and scheduler fan-out must be budgeted against the background DB capacity. It must be impossible to configure dozens of job executors against a pool that cannot sustain them without pervasive queue timeouts.

### 3. Scheduler loops remain cheap
Recurring “ensure scheduled” loops and maintenance checks must not impose material DB churn when no useful work is pending. Their presence must not erode the capacity reserved for control-plane paths.

### 4. Deployment defaults are valid
Compose defaults must represent a real supported deployment profile, not a crippled debug mode. All major subsystems may be enabled, but their budgets must be sane for a single-node footprint.

### 5. Observability is first-class
Operators must be able to see:
- per-workload pool utilization
- queue timeouts and checkout pressure
- executing/available jobs by queue and workload class
- control-plane latency degradation when background pressure rises

## Open Questions
- Whether `web-ng` should keep only read-mostly control-plane access or also own a distinct analytics-oriented budget.
- Whether some refresh/materialization jobs should move away from Oban entirely if they remain too chatty even within the background budget.
- Whether PgBouncer should be added later as a connection smoothing layer after workload isolation is in place.
