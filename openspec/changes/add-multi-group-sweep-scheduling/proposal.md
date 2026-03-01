# Change: Add Multi-Group Sweep Scheduling

## Why
Agents currently flatten multiple sweep groups into a single sweep configuration, which destroys per-group schedules and can cause unintended high-frequency scanning. We need agents to respect multiple sweep groups per agent and schedule each group independently.

## What Changes
- Preserve sweep groups as distinct entries in the agent sweep config payload.
- Introduce agent-side scheduling that runs each sweep group on its own interval/cron schedule.
- Ensure sweep results are attributed to the correct sweep group without merging targets or settings.

## Impact
- **Affected Specs:** `sweep-jobs`
- **Affected Code:** Sweep config compilation (core), sweep config parsing + scheduling (agent), sweep service execution context (agent)
