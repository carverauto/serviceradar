# Change: OCSF Agent Schema Alignment

**Status**: Implementation Complete (pending integration testing)

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
5. **SRQL `agents` entity** - Query support for agent data via `/api/query`
6. **UI agent views** - Agent list, detail views, and dashboard card in web-ng (all using SRQL)

## Impact

- **Affected specs**: New `agent-registry` capability
- **Affected code**:
  - `pkg/db/cnpg/migrations/` - New migration for `ocsf_agents` table
  - `pkg/core/pollers.go` - Removed `registerAgentAsDevice()`, added `registerAgentInOCSF()`
  - `pkg/models/ocsf_agent.go` - OCSF-aligned agent model
  - `pkg/db/cnpg_ocsf_agents.go` - Write path only (`UpsertOCSFAgent`)
  - `rust/srql/src/query/agents.rs` - SRQL agent query module (all reads)
  - `rust/srql/src/parser.rs` - Added `agents` entity type
  - `web-ng/lib/serviceradar_web_ng_web/live/agent_live/` - Agent UI views
- **Breaking changes**: None - agents currently in `ocsf_devices` can remain for backwards compatibility during migration
- **Migration**: Existing agent entries in `ocsf_devices` are preserved; new agent data goes to `ocsf_agents`

## Implementation Summary

### Completed

1. **Database Schema** - Migration `00000000000008_ocsf_agents.up.sql` creates `ocsf_agents` table with OCSF v1.7.0 aligned fields
2. **Go Agent Model** - `pkg/models/ocsf_agent.go` with `OCSFAgentRecord` struct and type constants
3. **Write Path** - `pkg/db/cnpg_ocsf_agents.go` with `UpsertOCSFAgent()` for agent registration
4. **Registration Flow** - `registerAgentInOCSF()` in pollers.go called during service processing
5. **Legacy Cleanup** - Completely removed `registerAgentAsDevice()` and `CreateAgentDeviceUpdate()`
6. **SRQL Support** - `agents` entity queryable via `/api/query` with filters (type_id, poller_id, capabilities, name, version)
7. **Web-NG Views** - Agent list/detail views at `/agents` route, all using SRQL queries
8. **Dependency Cleanup** - Removed unused `lib/pq` dependency (pgx handles arrays natively)

### Architecture Decision: Write Path (Go) / Read Path (SRQL)

The implementation follows a clean separation:
- **Write path**: Go `UpsertOCSFAgent()` called during poller heartbeat processing
- **Read path**: All agent queries go through SRQL `agents` entity via REST API

This avoids duplicate read logic in Go and leverages SRQL's query capabilities for filtering, ordering, and pagination.
