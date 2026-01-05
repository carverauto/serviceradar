## 1. Protocol + Identity
- [x] 1.1 Extend agent/agent-gateway Hello/GetConfig to identify sync services and service class
- [x] 1.2 Define mTLS identity classification for platform vs tenant services (SPIFFE/CN rules)
- [x] 1.3 Enforce tenant scoping in agent/agent-gateway based on mTLS identity
- [x] 1.4 Reserve platform tenant slug and validate platform/non-platform usage
- [x] 1.5 Reject zero UUID for platform tenant identity and require explicit gateway tenant_id

## 2. Core Ash Resources
- [x] 2.1 Create SyncService Ash resource with attributes: component_id, name, service_type (:saas/:on_prem), endpoint, status, is_platform_sync, capabilities, last_heartbeat_at, tenant_id
- [ ] 2.2 Create DiscoveredDevice Ash resource with: device_id, source_type, ip_addresses, mac_addresses, hostname, device_type, raw_data, agent_uid, integration_source_id, tenant_id
- [x] 2.3 Add sync_service_id foreign key to IntegrationSource with belongs_to relationship
- [ ] 2.4 Create database migrations for sync_services and discovered_devices tables
- [x] 2.5 Add migration to add sync_service_id column to integration_sources
- [x] 2.6 Emit IntegrationSource create/update events to OCSF events pipeline

## 3. Platform Bootstrap
- [x] 3.1 Generate and persist random platform tenant UUID on first boot
- [x] 3.2 Issue platform service mTLS certs with stable identifiers
- [x] 3.3 Auto-create SaaS sync service record with is_platform_sync: true at bootstrap
- [ ] 3.4 Generate minimal sync bootstrap config during platform bootstrap
- [ ] 3.5 Add tests for bootstrap tenant + sync service creation

## 4. Proto & gRPC Changes
- [ ] 4.1 Confirm sync pushes results via StreamStatus with ResultsChunk-compatible semantics
- [ ] 4.2 Add SweepConfig message to proto
- [ ] 4.3 Add sweep field to AgentConfigResponse
- [ ] 4.4 Generate Go protobuf stubs
- [ ] 4.5 Generate Elixir protobuf stubs

## 5. Sync Service Runtime (Go)
- [x] 5.1 Remove datasvc/KV clients and config code
- [x] 5.2 Implement Hello + GetConfig bootstrap against agent-gateway
- [ ] 5.3 Maintain per-tenant config cache and run per-tenant sync loops
- [ ] 5.4 Push device updates to agent-gateway via StreamStatus with ResultsChunk-compatible chunking
- [x] 5.5 Build sync GetConfig payloads from IntegrationSource data (per tenant)

## 6. Device Ingestion + DIRE
- [ ] 6.1 Ingest sync results from StreamStatus chunks in agent-gateway/core pipeline
- [ ] 6.2 Validate tenant scope using mTLS identity and request metadata
- [ ] 6.3 Route sync updates through DIRE for canonical device records
- [ ] 6.4 Persist optional discovered_devices staging records (if needed)
- [ ] 6.5 Add tests for sync ingestion path

## 7. Sweep Config Generation
- [ ] 7.1 Add build_sweep_config/2 to AgentConfigGenerator
- [ ] 7.2 Query DiscoveredDevice or canonical device inventory to build sweep targets
- [ ] 7.3 Extract networks from device IPs (compute CIDR ranges)
- [ ] 7.4 Build device_targets list with ports from source data
- [ ] 7.5 Include sweep config in GetConfig response
- [ ] 7.6 Add tests for sweep config generation

## 8. Agent Sweep Config Application
- [ ] 8.1 Add sweep config handling to Go agent's fetchAndApplyConfig
- [ ] 8.2 Update SweepService to accept config from GetConfig (not just sweep.json)
- [ ] 8.3 Add fallback to sweep.json for backward compatibility
- [ ] 8.4 Remove KV dependency from agent sweep config path
- [ ] 8.5 Add tests for agent sweep config application

## 9. Sync Service Onboarding + UI
- [ ] 9.1 Implement heartbeat tracking (update last_heartbeat_at)
- [ ] 9.2 Add status computation (online if heartbeat < 2 min, offline otherwise)
- [ ] 9.3 Add on-prem sync service onboarding endpoint in web-ng
- [x] 9.4 Generate minimal sync bootstrap config during edge onboarding
- [x] 9.5 Add "Add Edge Sync Service" button under "+ New Source" in Integrations UI
- [ ] 9.6 Add sync service selector + status to Integrations UI

## 10. KV Deprecation
- [ ] 10.1 Add feature flag for "sweep config from GetConfig" vs "sweep.json from KV"
- [ ] 10.2 Remove sync_to_datasvc calls from IntegrationSource (behind flag)
- [ ] 10.3 Update documentation for new device discovery flow
- [ ] 10.4 Add migration guide for customers using on-prem sync

## 11. Testing & Documentation
- [ ] 11.1 Add integration tests for full device discovery → DIRE → inventory flow
- [ ] 11.2 Add tests for sync service onboarding and tenant isolation
- [ ] 11.3 Validate results streaming chunking behavior and gRPC size limits against legacy core + sync
- [ ] 11.4 Update architecture docs with new data flow
- [ ] 11.5 Add API documentation for sync results streaming (ResultsRequest/ResultsChunk)
