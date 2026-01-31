# Change: Fix Armis integration execution in demo

## Why

- GH-2625 reports that an Armis integration configured in the UI never executes in the demo environment.
- In `demo`, an enabled `integration_sources` row exists for Armis and is assigned to `k8s-agent`, but `last_sync_at`, `last_sync_result`, and `last_error_message` remain empty, indicating no sync runs have occurred.
- The demo namespace has no dedicated sync service pod, and the agent logs show only sweep/sysmon activity with no Armis/sync execution, despite docs stating the sync runtime is embedded in the agent.
- This breaks the Armis demo flow and makes it hard to diagnose whether the issue is configuration, scheduling, or runtime availability.

## What Changes

- Implement/enable the embedded sync runtime in the agent to consume IntegrationSource config from agent-gateway and execute Armis discovery/poll cycles on schedule.
- Ensure sync runs report lifecycle updates (start, success, failure) and error messages back to core so `integration_sources` fields populate.
- Improve operational visibility so the UI clearly indicates when an integration is enabled but not executing (e.g., agent disconnected, sync runtime disabled).
- Update demo Helm/K8s wiring so the agent has sync runtime enabled and the Armis faker endpoint is reachable.

## Impact

- Affected specs: `sync-service-integrations` (execution + status reporting), `build-web-ui` (status visibility if added).
- Affected code:
  - Go agent runtime (embedded sync loop + Armis adapter)
  - Agent-gateway config payload handling for sync sources
  - Core sync ingestion/status updates (IntegrationSource lifecycle)
  - Web UI integrations list/details (status + diagnostics)
  - Helm/demo config for agent runtime enablement
