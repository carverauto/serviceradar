# Change: Add bulk queued MTR diagnostics

## Why

The current MTR implementation is shaped around ad-hoc operator traces and low-volume automation. It hard-caps on-demand execution to two concurrent traces per agent and treats each trace as an independent control-stream command. That is acceptable for interactive troubleshooting, but it does not meet the operational requirement to run MTR across 2,400+ targets from a single agent attached to a core cluster.

We need a fleet-sized bulk execution path that can accept thousands of targets in one request, queue them on one agent, drive them through a high-throughput worker model, and expose accurate job progress and completion state to operators. This must be a first-class capability, not a control-plane loop that fires thousands of individual `mtr.run` commands and hopes agent-side throttles are enough.

## What Changes

- Add a bulk queued MTR job model that allows one operator action to target at least 2,400 destinations on one connected agent.
- Introduce a dedicated bulk MTR execution path on the agent that is separate from the current interactive `mtr.run` concurrency cap.
- Add agent-local queueing, bounded worker concurrency, and batch-oriented progress reporting for bulk MTR jobs.
- Require the bulk executor to reuse long-lived raw-socket and enrichment resources where possible so large jobs complete materially faster than per-target cold starts.
- Add control-plane persistence and lifecycle tracking for bulk MTR jobs and per-target outcomes.
- Extend the MTR diagnostics UI with bulk submission, progress, terminal-state handling, and result drill-down for large queued jobs.
- Add recurring bulk MTR scheduling with overlap protection so a new cycle never silently piles on top of an unfinished prior cycle.
- Add first-run calibration and throughput guidance so operators get an evidence-based recommended interval before enabling recurring full-inventory jobs.

## Impact

- Affected specs: `mtr-diagnostics`, `build-web-ui`
- Affected code:
  - `go/pkg/agent/control_stream.go`
  - `go/pkg/agent/mtr_checker.go`
  - `go/pkg/mtr/`
  - new agent-side bulk queue / executor components
  - `elixir/serviceradar_core/lib/serviceradar/edge/agent_command_bus.ex`
  - new core resources/actions for bulk MTR jobs and targets
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/diagnostics_live/*`

## Risks

- High-rate probing from one agent can create local CPU, socket-buffer, and network-pressure spikes if concurrency is not bounded.
- A single large job can starve interactive diagnostics unless bulk and ad-hoc execution are isolated.
- Persisting thousands of targets per job adds write amplification unless job state and target state are modeled carefully.
- Operators may expect "all at once" behavior; the system needs explicit queue and progress semantics so bounded batching is visible and predictable.
