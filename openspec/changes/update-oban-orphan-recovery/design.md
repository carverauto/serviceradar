## Context
ServiceRadar uses Oban for recurring maintenance, inventory, integration, and operator-triggered background jobs. Oban jobs can remain in `executing` if the owning BEAM node exits before the job is acknowledged as complete or failed. When those jobs participate in uniqueness constraints, a stale row can block future scheduled or manual runs while the UI still appears to accept an enqueue request.

The July 6, 2026 production incident exposed this through `ServiceRadar.Integrations.ArmisNorthboundRunWorker`, but the same failure mode applies to any queue and worker using shared `platform.oban_jobs`.

## Goals / Non-Goals
- Goals:
  - Recover stale `executing` Oban jobs with a single platform-level mechanism.
  - Keep recovery owned by the Oban coordinator so all nodes see consistent cleanup behavior.
  - Avoid adding worker-specific reaper entries for every subsystem.
  - Preserve immediate manual-run feedback when a uniqueness conflict is stale but cannot be cleared synchronously.
- Non-Goals:
  - Introduce Oban Pro-only dependencies.
  - Infer per-worker liveness from Kubernetes pods in this change.
  - Remove existing subsystem-specific stale-run bookkeeping in the same incident fix.

## Decisions
- Use `Oban.Plugins.Lifeline` in `serviceradar_core` as the system-wide recovery mechanism.
- Run Lifeline only from the core Oban coordinator, alongside Cron and database peer leadership.
- Default `rescue_after` to 240 minutes and expose `OBAN_LIFELINE_RESCUE_AFTER_MS` for production tuning.
- Handle stale `executing` uniqueness conflicts in the shared `ObanSupport.safe_insert/2` path so manual enqueue callers get one common retry/error behavior.
- Discard the stale blocking row before the synchronous insert retry; the new insert is the replacement work item, while Lifeline remains the background path that rescues non-exhausted orphans back to `available`.
- Let subsystem workers pass a shorter conflict threshold only when their workflow has a tighter freshness contract than the global Lifeline threshold.

## Alternatives Considered
- Expand `ReapStalePeriodicJobsWorker` with more worker allowlists.
  - Rejected because it keeps recovery fragmented by subsystem and misses non-periodic jobs.
- Replace Lifeline with a custom query over every `executing` row.
  - Rejected because Oban already provides the generic engine-aware transition semantics and telemetry hooks.
- Use a very short rescue threshold.
  - Rejected because some ServiceRadar background jobs can legitimately run longer than a few minutes; the first pass should favor avoiding duplicate execution.

## Risks / Trade-offs
- Lifeline is time-based and can rescue a legitimately long-running job if it exceeds the threshold.
  - Mitigation: use a conservative four-hour default, make it configurable, and rely on the ServiceRadar requirement that Oban workers are idempotent.
- Existing subsystem-specific cleanup may overlap with Lifeline.
  - Mitigation: treat Lifeline as the platform baseline and retire bespoke reapers in follow-up work once each subsystem's status bookkeeping is checked.

## Migration Plan
1. Enable Lifeline in core Oban configuration.
2. Route manual enqueue paths through shared stale-conflict recovery.
3. Deploy with the conservative default threshold.
4. Monitor Oban plugin telemetry/logs and job history for rescued or discarded jobs.
5. Replace remaining subsystem-specific stale-job reapers with shared recovery helpers in later cleanup changes.
