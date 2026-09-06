## Context

SRQL is a closed, read-only query language compiled by a Rust NIF to
parameterized `SELECT`/`WITH` SQL. Device Ash policies are permission-level
(`devices.view`), not row-level. Built-in roles all hold the view keys, so
stock viewer/operator/admin are unaffected. Custom `RoleProfile` rows can
omit them.

GitHub #4088 documents the hole and the rejected alternative (SRQL →
Ash.Query + tenant isolation). That leftover lives in `openspec/specs/ash-api`
and fights the dedicated-deployment model (CNPG `search_path`).

## Goals / Non-Goals

- Goals:
  - Catalog-key gate on the shared execute path used by HTTP, LiveView, and MCP.
  - 403 for a custom profile that lacks the mapped view key.
  - Viewer still queries entities whose keys remain on `@all_roles`.
  - Tests fail if `scope` is dropped from `Access.execute_query/2`.
- Non-Goals:
  - Translating SRQL to Ash.Query.
  - Row-level device-group **read** grants (write-only today).
  - Filtering `GET /api/srql/catalog` by permission.

## Decisions

- Decision: Map entities to catalog keys; do not compile SRQL as Ash.Query.
  - Rationale: #4088. SRQL already cannot mutate or target identity/security
    tables. The hole is "authenticated but not authorized."
  - Result: `ServiceRadarWebNG.SRQL.EntityAccess` owns the map. `Api.Access`
    and `SRQL.query_request` / `query_arrow` call it before SQL.

- Decision: Mapping (UI surface, not table name):
  - `devices.view` — devices, agents, gateways, interfaces, wifi, field
    survey, public endpoints, endpoint inventory, virtualization, addon
    fleet, topology graph.
  - `services.view` — services, availability, monitored services, SLOs,
    composite results.
  - `observability.logs.view` — logs.
  - `observability.metrics.view` — timeseries, SNMP, sysmon, OTEL metrics,
    capacity forecasts, rperf.
  - `observability.traces.view` — traces / OTEL traces / summaries / MTR.
  - `observability.events.view` — events, security findings, scan/DNS/BMP
    activity.
  - `observability.netflow.view` — flows, attributed_flows.
  - `observability.alerts.view` — alerts.
  - dashboards — passthrough to existing Ash search.

- Decision: Unknown entity is a compiler error, not 403.
  - Rationale: 403 on a typo looks like a permission bug and leaks nothing
    useful. The map is exhaustive for catalog + parser aliases; a new entity
    without a map entry is caught by a unit test against `Catalog.entities/0`.

- Decision: HTTP 403 JSON is `{"error":"forbidden",...}`. MCP tool errors
  stay JSON-RPC 200 with `isError` (protocol), with text `forbidden`.

## Risks / Trade-offs

For the completed detail-loader follow-up, see the
[SRQL access contract](../../../docs/docs/rbac-and-roles.md#srql-and-detail-page-access).

- Fail-open on unmapped entities until the catalog test is updated. That is
  deliberate so a new entity is a test failure, not a production 403 storm.
