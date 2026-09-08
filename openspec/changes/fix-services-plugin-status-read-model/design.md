## Context
The `/services` LiveView currently loads SRQL history from `service_status` and separately loads current plugin rows from `platform.service_state`. `platform.service_state` already has a unique identity on `(agent_id, gateway_id, partition, service_type, service_name)` and is the right durable current-state table.

The symptoms indicate three distinct failure classes:
- **Read model freshness**: reload should read the latest current row from Postgres immediately instead of waiting for the next PubSub event or scheduled check.
- **Placeholder overwrite**: `ServiceStateRegistry.reconcile_plugin_assignments/1` seeds assignment placeholders. Those placeholders must never replace newer real plugin results or make an old failure look like the current state.
- **Execution/config regressions**: AWX reports missing `base_url`, Proxmox traps in TinyGo/JSON reflection, OTX/Dusk host-function calls fail, and several rows stay pending because no result reaches ingestion.
- **Package activation drift**: multiple approved versions of the same plugin can remain present, which lets stale assignments and current-state rows look like duplicate plugins.

## Goals
- Make `/services` deterministic on page reload from persisted current state.
- Preserve latest real plugin results across reconnects, page reloads, and assignment reconciliation.
- Keep historical `service_status` ingestion intact for SRQL/history.
- Add first-party plugin smoke coverage that exercises the same config shape agents receive.
- Surface actionable plugin failures without truncating away the root cause needed to debug.
- Keep plugin activation singular: one approved package version per plugin ID.

## Non-Goals
- Replace SRQL or remove `service_status` history.
- Add multitenancy or per-customer routing.
- Convert streaming media transport into plugin result payloads.
- Redesign the plugin package format.

## Proposed Approach
1. Treat `ServiceState` as the source of truth for active plugin cards.
   - Query active plugin states directly on `handle_params/3`.
   - Keep PubSub refresh for live updates, but do not rely on it for initial correctness.
   - Sort failures first, then newest observation time.

2. Make ingestion update the read model explicitly.
   - Plugin-result ingestion already writes historical `ServiceStatus`.
   - Ensure the same decoded plugin result also updates `ServiceState` using the exact identity used for the historical row.
   - Avoid double-decoding or inconsistent status/message normalization.

3. Make assignment placeholders monotonic.
   - Placeholder creation is allowed only when no active state exists, or when the active state is itself an assignment placeholder.
   - Assignment reconciliation must compare timestamps and must not move `last_observed_at` forward for a placeholder over a real result.
   - Disabled assignments/packages should deactivate their current-state row.

4. Repair stale/missing current state.
   - Provide an idempotent reconciler that rebuilds plugin `ServiceState` from the newest `service_status` row per identity.
   - Run it manually for repair and from tests; only schedule it automatically if the implementation needs a periodic safety net.

5. Fix first-party plugin config and runtime regressions.
   - Verify generated agent plugin config for AWX, Proxmox, OTX, Dusk, UniFi Protect, sample northbound, and HTTP/Hello plugins.
   - For credential-backed plugins, ensure assignment params resolve to the exact config schema required by the plugin.
   - For Proxmox, isolate and fix the TinyGo runtime trap with a minimal fixture test before changing inventory behavior.
   - For host-function failures, distinguish expected network/policy denial from runtime host-function bugs.

6. Enforce package activation invariants.
   - Add a partial unique index on approved plugin packages by plugin ID.
   - Make package approval revoke sibling approved packages before approving the selected package.
   - Disable assignments that reference packages revoked by migration or approval.

## Risks
- Updating both `service_status` and `service_state` must not create inconsistent records if one write succeeds and the other fails. The implementation should return/report partial failures and favor retryable idempotent writes.
- `service_state` identities must remain stable. Changing service names or agent IDs would fragment current-state rows.
- First-party plugin smoke tests may require mocked host functions rather than real external services to avoid flaky network dependencies.
- Revoking superseded packages must be coordinated with assignment disablement so agents do not keep receiving stale package versions.
