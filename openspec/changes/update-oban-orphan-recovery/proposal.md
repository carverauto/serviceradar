# Change: Add system-wide Oban orphan recovery

## Why
An Armis northbound run in production remained in Oban's `executing` state after its owning node exited, and the stale row continued to satisfy uniqueness constraints. The immediate incident was Armis-specific, but the failure mode is generic to any Oban-backed worker that can be orphaned by a pod restart, node loss, or failover.

## What Changes
- Enable a coordinator-owned, system-wide Oban orphan recovery path for stale `executing` jobs across queues and workers.
- Keep the stale threshold configurable so operators can tune the duplicate-execution trade-off without code changes.
- Preserve explicit user-facing error handling for manual enqueue paths that still encounter stale uniqueness conflicts before the background recovery tick runs.
- Stop expanding subsystem-specific stale-job allowlists as the primary recovery mechanism.

## Impact
- Affected specs: `job-scheduling`
- Affected code:
  - `elixir/serviceradar_core/config/config.exs`
  - `elixir/serviceradar_core/config/runtime.exs`
  - `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/oban_support.ex`
  - `elixir/serviceradar_core/lib/serviceradar/integrations/armis_northbound_run_worker.ex`
  - `elixir/serviceradar_core/test/serviceradar/sweep_jobs/oban_support_test.exs`
  - `elixir/serviceradar_core/test/serviceradar/integrations/armis_northbound_run_worker_test.exs`
