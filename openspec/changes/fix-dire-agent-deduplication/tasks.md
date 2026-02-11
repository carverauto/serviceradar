## 1. Register agent_id in AgentGatewaySync

- [x] 1.1 In `ensure_device_for_agent`, after successful `upsert_device_for_agent`, call `IdentityReconciler.register_identifiers` with the agent's identifiers
- [x] 1.2 Add test: agent enrollment registers `agent_id` in `device_identifiers`
- [x] 1.3 Add test: second enrollment from different IP resolves to same device

## 2. Register agent_id in SyncIngestor

- [x] 2.1 Add `:agent_id` to `build_identifier_records` alongside armis, integration, netbox, mac
- [x] 2.2 Add `:agent_id` to `cached_device_id` lookup chain (first position, highest priority)
- [x] 2.3 Add test: sync ingestion with agent_id registers it in `device_identifiers`

## 3. Data cleanup (one-time, after deploy)

- [x] 3.1 Write migration to consolidate duplicate k8s-agent devices: keep oldest, reassign interfaces/metrics/identifiers from duplicates to canonical, delete duplicates
- [x] 3.2 Write migration to backfill `device_identifiers` for any device that has `ocsf_devices.agent_id` set but no `:agent_id` row in `device_identifiers`
- [ ] 3.3 Verify: after deploy, restart k8s-agent pod and confirm same `sr:` device UID is reused
