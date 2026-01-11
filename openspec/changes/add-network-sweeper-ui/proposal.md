# Change: Add Network Sweeper Configuration UI and Config Distribution

## Why

The serviceradar-agent has high-performance network sweeper capabilities (TCP SYN half-open scanner, ICMP scanner) but no UI exists to configure sweep jobs. Users must manually edit configuration files. Additionally, there's no reusable pattern for distributing tenant-specific configurations to agents via the agent-gateway.

Key gaps:
1. No UI for creating/editing sweep jobs targeting device subsets
2. No admin UI for managing scanner profiles (protocols, ports, intervals)
3. No reusable Ash-based config distribution pattern for agent polling
4. Need to validate sweep results flow through agent-gateway → core-elx → DIRE

## What Changes

### 1. Agent Config Distribution (New Capability)
- Create reusable `ServiceRadar.AgentConfig` Ash domain for tenant-aware config generation
- Ash resources for config templates, config instances, and config versions
- GenServer-based config compilation and caching
- gRPC endpoint for agents to poll compiled configs
- Event-driven config invalidation on database changes

### 2. Sweep Job Management (New UI + Resources)
- Ash resources: `SweepJob`, `SweepProfile`, `SweepTarget`
- Admin Settings UI: "Networks" tab for profile management
- Bulk device edit: configure sweep settings across device selections
- Job status dashboard: last run time, operational status, error tracking
- Device selection DSL: IP range, CIDR, tags (discovery_sources), partition

### 3. Sweep Results Data Flow
- Validate agent → agent-gateway push for sweep results
- Implement agent-gateway → core-elx RPC forwarding with chunking/streaming
- Core processes sweep results through DIRE for device enrichment
- Update `ocsf_devices.is_available` and availability timestamps

### 4. Sweeper Spec Updates
- Add requirements for UI-driven configuration
- Add requirements for profile-based scanning
- Add requirements for results ingestion pipeline

## Impact

- **New specs**:
  - `agent-config`: Reusable config distribution pattern
  - `sweep-jobs`: Sweep job management and UI
- **Modified specs**:
  - `sweeper`: Add UI configuration requirements
  - `device-inventory`: Add availability enrichment from sweep results
- **Affected code**:
  - `elixir/serviceradar_core/lib/serviceradar/agent_config/` (new domain)
  - `web-ng/lib/serviceradar_web_ng_web/live/admin/settings_live/` (new Networks tab)
  - `web-ng/lib/serviceradar_web_ng_web/live/inventory/device_live/` (bulk edit)
  - `pkg/agent/sweep_service.go` (config polling integration)
  - `pkg/gateway/` (sweep results forwarding)
