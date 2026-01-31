## 1. Investigation
- [x] 1.1 Confirm IntegrationSource config is included in agent-gateway GetConfig payload for `k8s-agent`.
- [x] 1.2 Trace current agent config application path and identify where sync sources should be applied.
- [x] 1.3 Verify faker endpoint connectivity from the agent pod.

## 2. Embedded Sync Runtime (Agent)
- [x] 2.1 Add sync runtime module to parse `config_json` sources into `models.SourceConfig`.
- [x] 2.2 Implement Armis adapter to fetch devices from the configured endpoint and map to `models.SweepResult` updates.
- [x] 2.3 Schedule per-source discovery/poll loops honoring `poll_interval` and `discovery_interval`.
- [x] 2.4 Include `sync_service_id`, `source`, and `integration_type` metadata on emitted updates.
- [x] 2.5 Ensure config changes restart/reschedule sync loops without duplicates.

## 3. Core Sync Status Reporting
- [x] 3.1 Wire sync lifecycle updates to IntegrationSource actions (`sync_start`, `sync_success`, `sync_failed`).
- [x] 3.2 Record error messages and device counts from sync ingestion results.
- [x] 3.3 Emit OCSF sync events for start/finish/failure with source identifiers.

## 4. UI Visibility
- [x] 4.1 Add UI status messaging when enabled sources have never run (agent disconnected, sync runtime disabled).
- [x] 4.2 Surface last error message and last sync timestamp consistently on list + detail views.

## 5. Demo Deployment
- [x] 5.1 Enable sync runtime in the demo agent deployment/Helm values.
- [x] 5.2 Validate Armis faker endpoint settings for the demo source.

## 6. Tests
- [ ] 6.1 Unit test Armis adapter mapping and pagination.
- [ ] 6.2 Integration test: enabled source triggers sync lifecycle updates.
- [ ] 6.3 Demo smoke test: Armis integration shows recent sync + devices in SRQL.
