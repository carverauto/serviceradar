## Context
Sweep groups are authored with independent schedules and targeting. The compiled sweep config already emits a `groups` array, but the agent currently flattens that into a single sweep config, selecting a single schedule and merging settings. This breaks per-group schedules and can increase network load.

## Goals / Non-Goals
- Goals:
  - Preserve multiple sweep groups in the agent configuration.
  - Schedule and execute each group independently using its own interval/cron.
  - Attribute results to the originating sweep group.
- Non-Goals:
  - Redesign of sweep group or profile authoring UI.
  - Changes to SRQL targeting semantics or core-side device query evaluation.

## Decisions
- Decision: Keep the sweep config wire format as `{ "groups": [...] }` and update the agent to handle multiple groups instead of flattening.
- Decision: Use a per-group sweeper execution context (group-specific interval, targets, and settings) rather than a global merged config.
- Decision: Continue to accept interval schedules first; cron support is optional but if present should be handled per group consistently.

## Risks / Trade-offs
- Managing multiple sweepers per agent increases resource usage; mitigate with per-group concurrency limits and careful lifecycle management.
- Group updates must cleanly stop old schedules and start new ones to avoid duplicate scans.

## Migration Plan
1. Update agent parsing to retain `groups` and create/update per-group schedules.
2. Keep backward compatibility: if only one group is present, behavior remains unchanged.
3. Deploy and verify that multi-group agents execute distinct schedules without merging.

## Open Questions
- Should cron schedules be enabled per group in the agent now, or remain rejected until implemented end-to-end?
- Do we need a cap on the number of active sweep groups per agent to prevent overload?
