## 1. Protocol + Identity
- [x] 1.1 Update Hello/GetConfig to advertise agent sync capability (replace sync service class)
- [x] 1.2 Define mTLS identity classification for platform vs tenant services (SPIFFE/CN rules)
- [x] 1.3 Enforce tenant scoping in agent/agent-gateway based on mTLS identity
- [x] 1.4 Reserve platform tenant slug and validate platform/non-platform usage
- [x] 1.5 Reject zero UUID for platform tenant identity and require explicit gateway tenant_id
- [x] 1.6 Remove platform sync identity handling in agent-gateway (superseded by agent-embedded sync)

## 2. Core Ash Resources
- [x] 2.1 Remove SyncService resource; model sync capability on Agent (or AgentCapability)
- [x] 2.2 Replace IntegrationSource sync_service_id with agent_id assignment
- [x] 2.3 Add migrations for agent assignment; drop sync_services table if needed
- [x] 2.4 Emit IntegrationSource create/update events to OCSF events pipeline
- [x] 2.5 Remove sync service status tracking (use agent heartbeat)

## 3. Platform Bootstrap
- [x] 3.1 Generate and persist random platform tenant UUID on first boot
- [x] 3.2 Remove platform sync service bootstrap (sync certs/config/records)
- [x] 3.3 Ensure platform bootstrap does not issue sync onboarding packages

## 4. gRPC/API
- [x] 4.1 Confirm agent-embedded sync pushes results via StreamStatus with ResultsChunk semantics
- [x] 4.2 Add integration source payloads to Agent GetConfig (agent-scoped)
- [x] 4.3 Remove sync-specific Hello/GetConfig fields (if any)
- [ ] 4.4 Regenerate protobuf stubs (Go/Elixir) if changed

## 5. Agent Runtime (Go)
- [x] 5.1 Embed sync runtime into agent binary
- [x] 5.2 Implement per-agent sync loop + config cache
- [x] 5.3 Push device updates via StreamStatus with chunking
- [ ] 5.4 Remove standalone sync service binary/deployments/config docs
- [x] 5.5 Remove datasvc/KV clients and config code from sync runtime

## 6. Device Ingestion + DIRE
- [x] 6.1 Ingest sync results from StreamStatus chunks in agent-gateway/core pipeline
- [x] 6.2 Validate tenant scope using mTLS identity and request metadata
- [x] 6.3 Route sync updates through DIRE for canonical device records
- [x] 6.4 Remove discovered_devices staging path (out of scope)
- [x] 6.5 Add tests for sync ingestion path

## 7. Onboarding + UI
- [x] 7.1 Require sync-capable agent before integrations can be created
- [x] 7.2 Replace "Add Edge Sync Service" UI with "Add Edge Agent" onboarding
- [x] 7.3 Remove edge sync onboarding endpoint `/api/admin/edge-packages/sync`
- [x] 7.4 Update edge onboarding bundles to include agent sync bootstrap config
- [ ] 7.5 Add agent selector + status in Integrations UI (if multiple agents)

## 8. KV Deprecation
- [x] 8.1 Remove sync_to_datasvc calls from IntegrationSource (behind flag)
- [x] 8.2 Update documentation for new device discovery flow
- [ ] 8.3 Add migration guide for customers moving from standalone sync to agent-embedded sync

## 9. Testing & Documentation
- [ ] 9.1 Add integration tests for full device discovery → DIRE → inventory flow (agent-embedded sync)
- [ ] 9.2 Update architecture + sync docs for agent-embedded sync
