## Context

ServiceRadar's monitoring hierarchy is: Poller -> Agent -> Checker -> Device. Currently, when agents report via poller heartbeats, `processIndividualServices()` in `pkg/core/pollers.go` calls `registerAgentAsDevice()` which creates device entries in `ocsf_devices`. This design decision was made before OCSF alignment, treating agents as just another type of discovered device.

The OCSF schema explicitly separates Agent (monitoring software) from Device (monitored asset). Devices have an `agent_list` field containing Agent objects that monitor them. This is the correct relationship model.

**Stakeholders**: Core team, UI team, integration partners expecting OCSF-compliant data.

## Goals / Non-Goals

**Goals**:
- Create dedicated `ocsf_agents` table aligned with OCSF Agent object schema
- Stop creating device entries for agents during self-registration
- Provide agent-specific registry queries and API endpoints
- Enable future agent management UI

**Non-Goals**:
- Migrating existing agent entries from `ocsf_devices` to `ocsf_agents` (can be done separately)
- Removing the existing `agents` service registry table (kept for operational tracking)

**Completed (originally non-goals)**:
- Agent UI views in web-ng (list and detail views at `/agents`)

## Decisions

### Decision 1: Separate `ocsf_agents` Table

**What**: Create new `ocsf_agents` table with OCSF Agent schema fields.

**Why**: Clean separation of concerns; agents are not devices. The existing `agents` service registry table tracks operational status (heartbeats, health), while `ocsf_agents` tracks agent identity and capabilities per OCSF.

**Alternatives considered**:
- Use a view on `ocsf_devices` filtering by `component_type='agent'` - Rejected: perpetuates the conflation problem
- Add agent fields to existing `agents` table - Rejected: mixes operational and identity concerns

### Decision 2: Preserve Existing Service Registry

**What**: Keep the existing `pollers`, `agents`, `checkers` registry tables for operational tracking.

**Why**: These tables track heartbeats, health status, and parent relationships. They serve a different purpose than OCSF identity tables. The `ocsf_agents` table is for agent metadata/identity, while `agents` is for operational status.

### Decision 3: Registration Flow Change

**What**: In `processIndividualServices()`:
- Remove: `registerAgentAsDevice(ctx, svc.AgentId, pollerID, sourceIP, partition)`
- Add: `registerAgentInOCSF(ctx, svc.AgentId, pollerID, sourceIP, agentVersion, capabilities)`

**Why**: Agents should only be registered in the OCSF agents table, not as devices.

### Decision 4: Write Path (Go) / Read Path (SRQL) Split

**What**: Go code only implements `UpsertOCSFAgent()` for writes. All read operations go through SRQL `agents` entity.

**Why**:
- Avoids duplicate query logic in Go and Rust
- Leverages SRQL's existing query capabilities (filtering, ordering, pagination)
- Web-NG already uses SRQL for all data fetching via `/api/query`
- Keeps Go db layer focused on write operations

**Implementation**:
- `pkg/db/cnpg_ocsf_agents.go` - Single method: `UpsertOCSFAgent()`
- `rust/srql/src/query/agents.rs` - Full query support with filters
- No Go methods for GetOCSFAgent, ListOCSFAgents, etc. (removed as unused)

## OCSF Agent Schema Fields

Based on [OCSF Agent v1.7.0](https://schema.ocsf.io/1.7.0/objects/agent):

| Field | Type | OCSF Req | Description |
|-------|------|----------|-------------|
| uid | TEXT | Recommended | Unique agent identifier (sensor ID) |
| name | TEXT | Recommended | Agent designation (e.g., "serviceradar-agent") |
| type_id | INTEGER | Recommended | Agent type enum (0=Unknown, 4=Performance, 6=Log, etc.) |
| type | TEXT | Optional | Human-readable type caption |
| version | TEXT | Optional | Semantic version of the agent |
| vendor_name | TEXT | Optional | Agent vendor (ServiceRadar) |
| uid_alt | TEXT | Optional | Alternate ID (e.g., configuration UID) |
| policies | JSONB | Optional | Applied policies array |

**ServiceRadar Extensions**:

| Field | Type | Description |
|-------|------|-------------|
| poller_id | TEXT | Parent poller reference |
| capabilities | TEXT[] | Registered capabilities (icmp, snmp, sysmon, etc.) |
| first_seen_time | TIMESTAMPTZ | When agent first registered |
| last_seen_time | TIMESTAMPTZ | Last heartbeat time |
| ip | TEXT | Agent IP address |
| metadata | JSONB | Additional agent metadata |

## Risks / Trade-offs

**Risk**: Agents appearing in both `ocsf_devices` (legacy) and `ocsf_agents` (new).
**Mitigation**: During transition, document that `ocsf_agents` is authoritative. Add a future migration task to clean up legacy device entries.

**Risk**: Breaking existing queries that look for agents in `ocsf_devices`.
**Mitigation**: Leave existing entries in place; only new registrations go to `ocsf_agents`. Update API to query both tables during transition.

## Migration Plan

1. Deploy new `ocsf_agents` table via migration
2. Update registration code to write to `ocsf_agents`
3. Stop writing agent entries to `ocsf_devices`
4. Add new API endpoints for agent registry
5. Future: Optional cleanup migration to remove legacy agent entries from `ocsf_devices`

**Rollback**: Revert code changes; `ocsf_agents` table can be dropped if unused.

## Open Questions

1. ~~Should we backfill existing agents from `ocsf_devices` to `ocsf_agents`?~~ Deferred - new agents go to `ocsf_agents`, legacy entries remain
2. ~~What agent types map to OCSF type_id values?~~ Resolved - Using `Unknown (0)` as default, with `ServiceRadar` as vendor_name. Type classification can be refined based on agent capabilities in future iterations.
