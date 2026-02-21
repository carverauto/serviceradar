# Proposal 006: Job Scheduler Split-Brain & Downtime Handling

## Status
Proposed

## Context
When `serviceradar-core` experiences a split-brain scenario or disconnects from the ERTS network (or during general downtime), background jobs (like `sweep monitor check` and other scheduled tasks) continue to queue up or accumulate. Oban's scheduling plugins keep enqueuing these jobs because the schedule dictates it, but the worker nodes are unable to process them. 

Currently, almost all periodic workers in the codebase are configured with a hardcoded `unique` period (e.g., `period: 60` or `period: 3600`). This completely defeats Oban's built-in deduplication during any downtime that exceeds that hardcoded limit.

Once the core service is fully restored and reconnects to the database/network, the job scheduler (Oban) attempts to process the entire backlog simultaneously. 

This results in:
1. **Duplicate Executions:** Periodic jobs (e.g., a sweeper scheduled every 1 minute with `period: 60`) will have multiple instances enqueued during a 5-minute disconnect, resulting in 5 identical sweeper jobs executing back-to-back upon recovery. If down for 16 hours, it will queue nearly 1,000 redundant jobs.
2. **System Overload:** A thunderous herd of delayed jobs spikes CPU and database connections, potentially causing further instability.
3. **Redundant Work:** In reality, when the system recovers from a prolonged outage, we do not need to run hundreds of redundant catch-up jobs; we only need to run **one** job to assess the current state.

## Goals
1. **Deduplication:** Ensure that upon system recovery from a disconnect, only *one* instance of a backed-up periodic job is executed, regardless of whether the downtime was 5 minutes or 16 hours.
2. **Graceful Recovery:** Ensure that the system recovers from downtime or split-brain without a massive spike in background job processing for redundant tasks.

## Proposed Design

### 1. Robust Oban Unique Job Configuration
The primary issue is that we are artificially limiting Oban's intelligence by supplying a short, hardcoded uniqueness period.

We propose updating the uniqueness criteria for *all* periodic and scheduled jobs across the codebase (e.g., `SweepMonitorWorker`, `InterfaceThresholdWorker`, `AgentCommandCleanupWorker`, `NetflowSecurityRefreshWorker`, etc.):
*   **Infinite `period`:** By setting `period: :infinity`, Oban checks uniqueness across the entire history of jobs in the specified states. If a job is already queued or running, it doesn't matter if it's been down for 1 hour or 16 hours; Oban will inherently block duplicates.
*   **Unique `states`:** Restrict the infinite period to active states: `[:available, :scheduled, :executing, :retryable]`. Once a job finishes (moves to `completed` or `discarded`), the state restriction drops, and the next scheduled job can be gracefully inserted.
*   **Unique `keys`:** Uniquely identify the job's purpose using the `keys` option (e.g., `[:group_id, :target_id]`) to prevent identical work from being queued.

```elixir
use Oban.Worker,
  queue: :monitoring,
  # Make the job unique forever across these active states
  unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]
```

### 2. Startup Deduplication / Pruning Hook
In extreme split-brain scenarios where Oban might somehow bypass uniqueness constraints (e.g., due to database split-brain or extreme clock drift), we can introduce an application startup hook. Before Oban begins fetching and processing jobs from the `monitoring` queue, this hook would prune duplicates.
*   Query the `oban_jobs` table for jobs in the `:available` state.
*   Group them by `worker` and `args`.
*   Keep the most recently inserted job and `discard` or `cancel` the older duplicates.

### 3. Job-Level Pre-Flight Checks
For critical sweepers, we can add a check inside the `perform/1` function to see if another identical job has *already* run very recently or is currently executing. 
*   This can be done by checking the last run timestamp of the specific sweep group in the database before proceeding.
*   If the group was updated within the last X seconds (by another recovered job), the current job simply returns `:ok` or `:discard` without doing the heavy lifting.

### 4. Implementation of Job Expiry (TTL)
For jobs that shouldn't run if they've been sitting in the queue too long (e.g., a sweep that is now 30 minutes old), we will implement a `ttl` (Time-To-Live) mechanism.
*   Check `DateTime.diff(DateTime.utc_now(), job.inserted_at, :second)`.
*   If the difference exceeds a threshold, discard the job.

## Action Plan
1. Globally update all scheduled/periodic Oban workers (15+ workers currently identified, including `SweepMonitorWorker`, `InterfaceThresholdWorker`, `ThreatIntelFeedRefreshWorker`, `NetflowSecurityRefreshWorker`, etc.) to use `unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]`.
2. Implement a job expiry (TTL) check inside the `perform/1` function of time-sensitive workers.
3. Evaluate adding an Oban startup hook to prune redundant jobs in specific queues before processing begins.
