## Context

The same inventory device can be reachable from one agent and intentionally unreachable from another. In the isolation-verification use case, a failed TCP/ICMP check from an OT-segment agent can be the desired outcome, while a successful check from an intranet agent confirms the device is online.

The current single `is_available` field cannot represent this without losing context. Recent sweep history already records agent IDs, but the device summary and integrations consume a single collapsed value.

There is also an active Armis northbound proposal that pushes availability back to Armis. That work needs a richer source selector so a customer can export "available from intranet" or "isolated from OT segment" rather than whatever global field happened to win.

## Goals

- Store one latest availability state per `(device, agent)` and keep enough metadata to explain it.
- Let operators choose the agent whose state drives canonical `Device.is_available` for a device or selected device set.
- Let Armis northbound updates choose the availability source used for the outbound value.
- Make the device details UI show per-agent availability clearly and compactly.
- Keep a single canonical device inventory row per device.

## Non-Goals

- Do not duplicate inventory devices per agent or partition.
- Do not make Armis responsible for determining availability.
- Do not remove the canonical `is_available` field; keep it as a derived compatibility field for existing UI, SRQL, and integrations.
- Do not infer isolation semantics automatically beyond exposing the selected source and raw per-agent outcomes.

## Decisions

### Availability state model

Add a database-backed latest-state relation keyed by canonical device UID and agent ID. This state should be updated from sweep ingestion and should include:
- `device_uid`
- `agent_id`
- `agent_label` or display name when available
- `is_available`
- `checked_at`
- protocol/check status summary for ICMP, TCP SYN, and TCP connect where available
- response time
- open ports
- sweep group/profile/execution identifiers
- raw bounded metadata for troubleshooting

Historical sweep result rows remain the source for recent history; the latest-state relation is the fast-read surface for device details, SRQL filters, and northbound jobs.

### Primary availability selection

Canonical `ocsf_devices.is_available` stays available but becomes derived from a configured primary source:
- default: current behavior/fallback, using the best available consolidated state so existing installs keep working
- configured: a selected `agent_id` for a device or device selection

Primary-source configuration has two layers:
- per-device override for one-off corrections or exceptions
- availability source profile for repeatable assignment, where a profile contains an SRQL `in:devices ...` query and a selected canonical `agent_id`

Profiles are evaluated against the current inventory and apply their selected agent to matching devices. If multiple enabled profiles match the same device, the system must use a deterministic precedence such as profile priority followed by stable ID ordering. A per-device override wins over profile-derived assignment.

### Northbound source selection

Armis northbound configuration should include an availability source selector:
- canonical device availability
- a specific agent's latest availability

The outbound value is computed from that selected source. For isolation use cases, the user can select the OT-segment agent and map `false` to the desired Armis custom-property/tag value in the northbound configuration.

### SRQL exposure

SRQL should support filtering and grouping by canonical availability as it does today, and add per-agent filters so users can find devices by vantage point without inspecting JSON metadata.

Proposed query shape can be finalized during implementation, but the capability should support:
- devices available/unavailable from a specific agent
- devices whose primary availability source is a specific agent
- devices with differing availability between two agents
- devices matching an availability source profile's SRQL scope, for preview and audit

## Risks / Trade-offs

- Writing latest per-agent availability on every sweep batch can become hot at large scale. Use upsert/batch paths and avoid per-row Ash action overhead where the existing ingestion path already has batch machinery.
- `is_available` semantics may be misunderstood if the selected primary source is hidden. The UI must show which source drives the global value.
- Armis northbound updates could produce incorrect customer-facing tags if source selection is misconfigured. The configuration UI should preview the selected source and last run counts.
- Stale per-agent availability must not look fresh. Include freshness timestamps and make stale states visually distinct.

## Migration Plan

1. Add the latest per-agent availability relation and backfill from recent sweep results when possible.
2. Preserve existing `ocsf_devices.is_available` values until new latest-state data is present.
3. Default primary availability selection to current behavior.
4. Add per-device controls and availability source profiles for assigning a primary agent.
5. Update Armis northbound to use canonical availability by default and allow selecting an agent-specific source.

## Open Questions

- Should profile-derived source assignments be materialized onto `ocsf_devices.availability_source_agent_id`, stored in a related effective-assignment table, or resolved at read time?
- Should stale per-agent availability be ignored after a configurable age, or displayed as stale while still preserving the last known value?
- Should Armis northbound support value mapping in the same change, or only source selection with the current boolean behavior?
- What is the exact SRQL syntax for comparing two agents' availability without overcomplicating the query language?
