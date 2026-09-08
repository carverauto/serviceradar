# Change: Allow sweep group creation when Oban is unavailable

## Why
Creating sweep groups currently crashes when Oban is not running in the process that owns the sweep changes, preventing admins from saving network sweep configuration. This blocks configuration in dev and any deployment where Oban is misconfigured or temporarily down.

## What Changes
- Make sweep group creation/update resilient to missing Oban by deferring scheduling instead of raising.
- Surface a clear, non-fatal warning to the UI when scheduling is deferred.
- Reconcile deferred sweep schedules when Oban becomes available again.

## Impact
- Affected specs: sweep-jobs, job-scheduling
- Affected code: core sweep scheduling change, Oban bootstrap/config, web-ng UI messaging for sweep group save feedback
