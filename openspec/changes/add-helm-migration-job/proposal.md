# Change: Run schema migrations via Helm upgrade job

## Why
Manual tenant migration runs are easy to miss during deployments, leading to schema drift and runtime errors after core upgrades. A Helm hook job that runs migrations during install/upgrade makes deployments repeatable and prevents pods from starting against stale schemas.

## What Changes
- Add a Helm hook Job that runs public and tenant schema migrations during `helm install` and `helm upgrade`.
- Gate the job behind Helm values (enabled by default) with explicit failure behavior to block upgrades on migration errors.
- Document the migration hook behavior and how to disable or re-run it when needed.

## Impact
- Affected specs: run-migrations
- Affected code: Helm chart templates/values, core release migration invocation, deployment docs
