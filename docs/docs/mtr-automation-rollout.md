# MTR Automation Rollout

This runbook controls automated MTR behavior in `serviceradar_core` without changing code.

## Feature flags

- `MTR_AUTOMATION_ENABLED`: global default for all automated MTR workers.
- `MTR_AUTOMATION_BASELINE_ENABLED`: baseline scheduler (`MtrBaselineScheduler`).
- `MTR_AUTOMATION_TRIGGER_ENABLED`: state-transition trigger worker (`MtrStateTriggerWorker`).
- `MTR_AUTOMATION_CONSENSUS_ENABLED`: cohort consensus + causal emitter worker (`MtrConsensusWorker`).

`MTR_AUTOMATION_*_ENABLED` flags default to the global value when unset.

## Recommended staged rollout

1. Baseline only:
   - `MTR_AUTOMATION_ENABLED=true`
   - `MTR_AUTOMATION_BASELINE_ENABLED=true`
   - `MTR_AUTOMATION_TRIGGER_ENABLED=false`
   - `MTR_AUTOMATION_CONSENSUS_ENABLED=false`
2. Add state-triggered capture:
   - set `MTR_AUTOMATION_TRIGGER_ENABLED=true`
3. Add consensus + causal emission:
   - set `MTR_AUTOMATION_CONSENSUS_ENABLED=true`

## Rollback switches

- Stop all automated MTR immediately:
  - `MTR_AUTOMATION_ENABLED=false`
- Stop only event-driven runs:
  - `MTR_AUTOMATION_TRIGGER_ENABLED=false`
- Stop only causal consensus/emission while keeping dispatch:
  - `MTR_AUTOMATION_CONSENSUS_ENABLED=false`
- Stop only baseline scheduling while keeping incident capture:
  - `MTR_AUTOMATION_BASELINE_ENABLED=false`

After flag changes, restart/redeploy `serviceradar_core` so the supervision tree is rebuilt with the new worker set.

## Helm values

For chart-based deploys, set the same behavior under:

```yaml
core:
  mtrAutomation:
    enabled: false
    baselineEnabled: false
    triggerEnabled: false
    consensusEnabled: false
    baselineTickMs: 60000
    consensusCohortRetentionMs: 300000
```
