# Design: NetFlow Application Analytics

## Goals
- Provide multiple SRQL-driven NetFlow analytics widgets (charts + tables) that load reliably for common time windows.
- Introduce a consistent definition of "application" for NetFlow, with admin overrides.
- Avoid Ecto queries for chart data: SRQL is the source of truth for visualization queries.

## Definition: "Application"
In this change, "application" is a label derived from flow metadata, not a DPI-based L7 decoder.

Baseline strategy:
1. Prefer any explicit application/service tag already derived for the flow (if present).
2. Otherwise map `{protocol, dst_port}` (and optionally `{protocol, src_port}`) to an application label.
3. If no mapping matches, label the flow as `unknown`.

Override strategy:
- Admin-defined rules can override the baseline mapping for a subset of traffic.
- Rule evaluation MUST be deterministic and bounded in cost.

## Rule Model
Introduce `platform.netflow_app_classification_rules` (partition-scoped).

Planned fields (draft):
- `partition` (TEXT, default `default`)
- `enabled` (BOOL)
- `priority` (INT, higher wins)
- `protocol_num` (INT, nullable)
- `dst_port` (INT, nullable)
- `src_port` (INT, nullable)
- `dst_cidr` (CIDR, nullable) optional refinement
- `src_cidr` (CIDR, nullable) optional refinement
- `app_label` (TEXT, required)
- `notes` (TEXT, nullable)
- `inserted_at`, `updated_at`

Precedence:
- First match by `priority DESC`, then most-specific match (ports + cidrs), then stable tie-break (id).

Performance notes:
- Evaluate rules using indexed predicates (port/protocol first, then CIDR containment only when CIDRs are present).
- Consider a two-phase evaluation: compute baseline label first, then override only if there exist enabled rules for the selected protocol/port.

## SRQL
Add a new filter/group-by field `app` for `in:flows` that corresponds to the derived label.

Query shapes:
- `in:flows time:last_1h stats:"sum(bytes_total) as bytes by app" sort:bytes:desc limit:8`
- `in:flows time:last_1h app:https stats:"sum(bytes_total) as bytes by dst_endpoint_ip" ...`

## UI
Add three primary widgets in the NetFlows view:
- Activity by protocol (stacked area)
- Frequent talkers tables (packets vs bytes)
- Activity by application (stacked area) with a legend on the right and drilldowns

Orientation:
- Charts will follow the existing convention: time on the x-axis, traffic metric (bytes/packets) on the y-axis.

