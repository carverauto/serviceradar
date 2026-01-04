## 1. Core Ash Resources

- [ ] 1.1 Create SyncService Ash resource with attributes: name, service_type (:saas/:on_prem), endpoint, status, is_platform_sync, capabilities, last_heartbeat_at, tenant_id
- [ ] 1.2 Create DiscoveredDevice Ash resource with: device_id, source_type, ip_addresses, mac_addresses, hostname, device_type, raw_data, agent_uid, integration_source_id, tenant_id
- [ ] 1.3 Add sync_service_id foreign key to IntegrationSource with belongs_to relationship
- [ ] 1.4 Create database migrations for sync_services and discovered_devices tables
- [ ] 1.5 Add migration to add sync_service_id column to integration_sources

## 2. Platform Bootstrap

- [ ] 2.1 Add ensure_platform_sync_service/0 to platform bootstrap logic
- [ ] 2.2 Create SaaS sync service record with is_platform_sync: true at bootstrap
- [ ] 2.3 Add platform sync service to tenant onboarding (all tenants get access to SaaS sync)
- [ ] 2.4 Add tests for bootstrap sync service creation

## 3. Proto & gRPC Changes

- [ ] 3.1 Add SyncDevicesRequest/Response messages to proto/monitoring.proto
- [ ] 3.2 Add DiscoveredDevice proto message
- [ ] 3.3 Add SyncDevices RPC to AgentGatewayService
- [ ] 3.4 Add SweepConfig message to proto
- [ ] 3.5 Add sweep field to AgentConfigResponse
- [ ] 3.6 Generate Go protobuf stubs
- [ ] 3.7 Generate Elixir protobuf stubs

## 4. Device Sync Flow

- [ ] 4.1 Implement SyncDevices handler in AgentGatewayServer (Elixir)
- [ ] 4.2 Create DiscoveredDevice upsert logic (create or update by device_id + source)
- [ ] 4.3 Add device deduplication by IP/MAC
- [ ] 4.4 Update Go sync service to call SyncDevices RPC after discovery
- [ ] 4.5 Add tests for device sync flow

## 5. Sweep Config Generation

- [ ] 5.1 Add build_sweep_config/2 to AgentConfigGenerator
- [ ] 5.2 Query DiscoveredDevice by agent_uid to build sweep targets
- [ ] 5.3 Extract networks from device IPs (compute CIDR ranges)
- [ ] 5.4 Build device_targets list with ports from source data
- [ ] 5.5 Include sweep config in GetConfig response
- [ ] 5.6 Add tests for sweep config generation

## 6. Agent Sweep Config Application

- [ ] 6.1 Add sweep config handling to Go agent's fetchAndApplyConfig
- [ ] 6.2 Update SweepService to accept config from GetConfig (not just sweep.json)
- [ ] 6.3 Add fallback to sweep.json for backward compatibility
- [ ] 6.4 Remove KV dependency from agent sweep config path
- [ ] 6.5 Add tests for agent sweep config application

## 7. Sync Service Onboarding

- [ ] 7.1 Add SyncServiceHello RPC for on-prem sync registration
- [ ] 7.2 Implement heartbeat tracking (update last_heartbeat_at)
- [ ] 7.3 Add status computation (online if heartbeat < 2 min, offline otherwise)
- [ ] 7.4 Add on-prem sync service onboarding endpoint in web-ng
- [ ] 7.5 Generate onboarding credentials for on-prem sync

## 8. UI - Integration Sources

- [ ] 8.1 Query SyncService availability on IntegrationsLive mount
- [ ] 8.2 Show "No sync service available" banner when none onboarded
- [ ] 8.3 Disable "Add Integration" button until sync available
- [ ] 8.4 Add sync service selector dropdown to integration form
- [ ] 8.5 Show sync service name in integration list table
- [ ] 8.6 Add sync service status indicator (online/offline)

## 9. UI - Sync Services Management

- [ ] 9.1 Add "Sync Services" tab to InfrastructureLive (platform admin only)
- [ ] 9.2 Show SaaS sync service status and last heartbeat
- [ ] 9.3 Add "Add On-Prem Sync" button with onboarding flow
- [ ] 9.4 Show list of on-prem sync services with status
- [ ] 9.5 Add sync service details view (integrations using it, device counts)

## 10. KV Deprecation

- [ ] 10.1 Add feature flag for "sweep config from GetConfig" vs "sweep.json from KV"
- [ ] 10.2 Remove sync_to_datasvc calls from IntegrationSource (behind flag)
- [ ] 10.3 Update documentation for new device discovery flow
- [ ] 10.4 Add migration guide for customers using on-prem sync

## 11. Testing & Documentation

- [ ] 11.1 Add integration tests for full device discovery → sweep config flow
- [ ] 11.2 Add tests for sync service onboarding
- [ ] 11.3 Update architecture docs with new data flow
- [ ] 11.4 Add API documentation for SyncDevices RPC
