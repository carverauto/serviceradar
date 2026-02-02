# Change: Fix Sweep Interval Configuration Propagation

## Why
Users have reported that the configured sweep interval (e.g., 6 hours) is ignored by the agent, which defaults to a 5-minute scan cycle. This causes excessive network noise and ignores user intent. See issue #2646.

## What Changes
- Clarify the requirement for sweep interval propagation from Profile to Agent Config.
- Explicitly define the behavior when multiple sweep jobs have conflicting intervals (shortest vs longest).
- Ensure the agent receives and respects the configured interval.

## Impact
- **Affected Specs:** `sweep-jobs`
- **Affected Code:** Agent configuration compilation logic (Core) and Agent sweep scheduling logic (Agent).
