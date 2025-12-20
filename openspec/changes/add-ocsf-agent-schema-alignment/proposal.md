# Change: OCSF Agent Schema Alignment

## Why

ServiceRadar currently treats agents as devices, auto-registering them in the `ocsf_devices` table when they report via pollers. This conflates two distinct concepts:

1. **Devices** - The infrastructure being monitored (servers, routers, switches, endpoints)
2. **Agents** - The monitoring software components that observe and report on devices

OCSF v1.7.0 explicitly defines an [Agent object](https://schema.ocsf.io/1.7.0/objects/agent) separate from Device, recognizing that agents are "specialized software components" for monitoring, detection, and collection. Aligning with this standard enables:

- Cleaner data model separating monitoring infrastructure from monitored assets
- Better agent lifecycle management (version tracking, capability enrollment)
- OCSF-compliant event emission where agent metadata is properly structured
- Dedicated UI views for agent management vs device inventory

## What Changes

1. **New `ocsf_agents` table** - Stores agent metadata following OCSF Agent schema
2. **Stop agent-to-device conversion** - Remove calls to `registerAgentAsDevice()` in pollers.go
3. **New agent registration flow** - Register agents in `ocsf_agents` instead of `ocsf_devices`
4. **Update `ocsf_devices.agent_list`** - Reference agents properly as OCSF Agent objects
5. **New Agent Registry API** - REST endpoints for agent listing, details, and search
6. **UI agent views** - Separate agent management pages in web-ng (separate follow-up)

## Impact

- **Affected specs**: New `agent-registry` capability
- **Affected code**:
  - `pkg/db/cnpg/migrations/` - New migration for `ocsf_agents` table
  - `pkg/core/pollers.go` - Remove `registerAgentAsDevice()`, add `registerAgentInRegistry()`
  - `pkg/models/agent.go` - OCSF-aligned agent model
  - `pkg/core/api/agent_registry.go` - New API handlers
  - `pkg/registry/` - Agent registry queries
- **Breaking changes**: None - agents currently in `ocsf_devices` can remain for backwards compatibility during migration
- **Migration**: Existing agent entries in `ocsf_devices` are preserved; new agent data goes to `ocsf_agents`
