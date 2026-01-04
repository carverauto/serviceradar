# Design: `serviceradar-web-ng` functionality map

## Philosophy: "The Core is a Daemon"
The Go application (`serviceradar-core`) is treated strictly as a **Data Ingestion Engine**. It scans networks, receives SNMP traps/Netflow, and writes to Postgres. It does **not** serve user traffic.

Phoenix (`serviceradar-web-ng`) reads that ingestion data and serves the UI/API using its own isolated application state.

## 1. Logic Porting Map (Go -> Elixir)
The following domains must be re-implemented. Note that Auth is a *replacement*, not a port.

| Domain | Legacy Go Source | Elixir Context (`ServiceRadarWebNG.*`) | Responsibility |
| :--- | :--- | :--- | :--- |
| **Inventory** | `unified_devices.go` | `Inventory` | Listing devices, Editing metadata (Shared Data). |
| **Topology** | `cnpg_discovery.go` | `Topology` | Querying the Apache AGE graph (Shared Data). |
| **Edge** | `edge_onboarding.go` | `Edge` | CRUD for onboarding packages (Shared Data). |
| **Infra** | `pollers.go` | `Infrastructure` | Viewing Poller status/health (Shared Data). |
| **Auth** | `auth.go` | `Accounts` | **NEW:** Fresh user management table (`ng_users`). |

## 2. Authentication Strategy (Fresh Start)
- **Table:** Create a new table `ng_users` (or similar) via `phx.gen.auth`.
- **Isolation:** Do NOT touch the legacy `public.users` table used by Go. This prevents collision and allows the Go daemon to continue internal operations if it relies on that table (though it shouldn't for ingestion).
- **Setup:** The first user to access the new UI will register a fresh admin account.

## 3. The API Gateway (Internal)
Phoenix will mount a `ServiceRadarWebNG.Api` scope.
- `POST /api/query` -> `QueryController.execute` (Calls Rust NIF for translation, then executes SQL via Ecto).
- All other legacy endpoints are deprecated and replaced by LiveView or new JSON endpoints as needed.

## 4. Embedded SRQL Translation (Rustler)
We are transforming `srql` from a **standalone HTTP service** to an **embedded translator library**.
- **No removal:** The `rust/srql` crate stays in the repo and continues to be maintained.
- **Additive migration:** The translator-only API is added without breaking existing SRQL server behavior so the legacy stack can keep using the SRQL HTTP service during the cutover.
- **Refactor:** Ensure `rust/srql` exposes a public translation API that returns:
  - parameterized SQL (`$1`, `$2`, ...)
  - bind parameters (in order)
  - pagination metadata (next/prev cursor, limit)
- **NIF:** Phoenix calls into SRQL via Rustler for translation only (pure computation).
- **Execution:** Phoenix executes the SQL via `Ecto.Adapters.SQL.query/4` (or equivalent) using the existing `ServiceRadarWebNG.Repo` pool.
- **Flow:** `UI/API -> Phoenix -> Rustler (translate) -> SQL -> Repo (execute) -> JSON`.
- **Deployment change:** The standalone `srql` HTTP container is no longer needed—requests are served by Phoenix.

## 5. Schema Ownership vs Data Access
- **Schema ownership (DDL):** Go Core owns the table structure for `unified_devices`, `pollers`, metrics, etc. Phoenix does NOT generate migrations for these.
- **Data access (DML):** Phoenix CAN read AND write to shared tables (e.g., editing device names, updating policies).
- **Phoenix-owned tables:** `ng_users`, `ng_sessions`, etc. Phoenix owns both schema and data.

## 6. Deployment
- The `web-ng` container will be deployed alongside `core`.
- `core` writes to DB (Telemetry/Inventory ingestion).
- `web-ng` reads/writes DB (Inventory edits, Auth, Settings).
- External Load Balancer routes traffic to `web-ng`.

## 7. Property-Based Testing (StreamData)

### Goals
- Catch edge-cases early for new Elixir contexts (especially token formats, parsing/validation, and serialization).
- Keep most property tests pure (no DB) so they run fast and deterministically in CI.
- Add targeted “safety net” properties at boundary layers (NIF input, JSON decoding/validation, changesets) to ensure garbage input never crashes the BEAM or the request process.

### Framework Choice
- Use `StreamData` via `ExUnitProperties` (standard Elixir ecosystem property-based testing).

### Conventions
- Put generators in `test/support/generators/*.ex` (shared across properties).
- Put properties in `test/property/**/*_property_test.exs`.
- Tag long-running properties with `@tag :slow_property` and keep CI defaults bounded (e.g., 50–200 cases/property) with an env override for deeper runs.
- Property tests MUST be part of normal `mix test` execution (no separate “optional” suite), unless explicitly excluded for performance reasons with a documented CI job.

### Starter Properties (Examples)
- **NIF Safety Net:** For any printable string input, `ServiceRadarWebNG.SRQL.query/1` MUST return `{:ok, _}` or `{:error, _}` and MUST NOT crash the test process.
- **Dual-Write Consistency:** For any sequence of create/update/delete operations on a Device, the Postgres row state MUST match the AGE node state after each operation.
- **Changeset Fuzzing:** For generated JSON-like maps that mimic Go ingestion shapes, changesets MUST return `{:ok, _}` or `{:error, changeset}` and MUST NOT raise.

## 8. SRQL-First Analytics UI and Composable Dashboards

### Principle: "Query-first UI"
For read-oriented pages (devices, pollers, metrics, traces, events, dashboards), SRQL is the primary interface:
- Pages declare a default SRQL query.
- The page executes that SRQL query via `POST /api/query`.
- The global navigation displays the exact SRQL query used to render the view.
- Users can edit and re-run the SRQL query to drive the page.

Non-analytics flows (auth, settings, edge onboarding CRUD) can remain context/API driven and use Ecto directly.

### Query Bar Contract
The app provides a shared "Query Bar" in the top navigation for SRQL-driven pages:
- Shows the active SRQL query string for the current page.
- Allows editing and submission (re-runs query and updates page state).
- Provides bounded error handling (invalid query shows an error panel, never crashes LiveView).
- Supports deep-linking by encoding the query in the URL (for shareable dashboards/pages).
- Provides a query builder toggle (icon) that expands a builder panel under the query bar.

### Query Builder
The query builder is a UI for constructing SRQL safely:
- The SRQL text input remains the source of truth (execution always runs SRQL).
- The builder produces SRQL output by updating the query bar text.
- The builder attempts to parse/reflect the existing SRQL into builder state when possible.
- If SRQL cannot be represented, the builder shows a bounded "read-only/limited" state and avoids destructive rewrites.
- The builder UI uses a visual, node/pill style with connector affordances (instead of a generic stacked form) and supports multiple filters.
- The builder SHOULD be driven by a centralized catalog of entities and field options so adding a new SRQL collection is a data/config change, not a template rewrite.

### SRQL Page Helpers
SRQL-driven pages share common patterns (query state, builder state, deep-linking, and execution). These are centralized in a helper module:
- Pages initialize SRQL state (default query + builder state).
- `handle_params/3` resolves `?q=` overrides and executes SRQL via the embedded translator + Ecto.
- Common `handle_event/3` handlers manage query editing, submit, builder toggle, and builder edits.

## 9. UI Components and Navigation Layout

### Component Organization
To keep the UI modular and swappable (Tailwind/daisyUI vs future alternatives), we centralize primitives as Phoenix function components:
- `UIComponents`: reusable primitives (buttons, inputs, panels, badges, tabs, dropdowns, toolbars)
- `SRQLComponents`: SRQL-specific composites (query bar, builder, results table, auto-viz panels)

Feature LiveViews should prefer calling these components instead of hardcoding CSS classes in templates.

### Navigation Layout
To avoid a cluttered top bar as more SRQL analytics pages are added:
- The SRQL query bar remains in the top header (always visible and consistent across SRQL-driven pages).
- Authenticated navigation is moved into a left sidebar (responsive drawer on mobile).

## 10. Future SRQL Composition (Open Question)
Users will likely want to enrich a primary query with related collections (e.g., "devices matching X" plus "events for those devices").
This suggests a future SRQL DSL extension for composing/expanding queries across entities (e.g., subquery piping or relationship expansion), which should be proposed explicitly as a follow-on change.

### Composable Dashboard Engine
Dashboards are built around SRQL queries and render "widgets" based on the query outputs:
- A dashboard definition can contain one or more SRQL queries.
- Each query result is mapped to one or more visualization candidates.
- The user can select a visualization, and the dashboard composes the widgets.

### Result Shape Detection and Visualization Hints
The dashboard engine should prefer explicit metadata from SRQL translation/execution over heuristics:
- Column names and types (time, numeric, categorical, id-like)
- Semantic hints (unit, series key, suggested visualization types)
- Pagination and time window semantics for hypertables

If explicit hints are unavailable, the engine can fall back to conservative heuristics (e.g., if a "time" column exists, suggest a time series chart).

### TimescaleDB and Apache AGE Coverage
Composable dashboards must support both:
- TimescaleDB hypertable patterns (time windows, aggregation/downsampling)
- Apache AGE relationship exploration (device/asset/interface graphs)

Preferred approach: keep SRQL as the unifying interface by extending the SRQL DSL/translator to express graph-oriented queries (compiled into SQL that uses AGE `cypher()`), so dashboards can treat graph data as another SRQL-backed data source.

### Extensibility
The dashboard system must be easy to extend:
- Provide stable Elixir behaviours for new widgets/visualizations.
- Keep visualizations pure where possible (inputs: SRQL string + result set + metadata; output: a LiveComponent render).
- Make it straightforward to add a new visualization without modifying core dashboard code (registry/discovery pattern).

## 11. Legacy UI Parity Map (`web/` -> `web-ng/`)

The legacy UI in `web/` contains several top-level destinations that users expect. This table is the “porting backlog” for `web-ng/`.

| Legacy Route (`web/`) | Phoenix Route (`web-ng/`) | Status | Notes |
| :--- | :--- | :--- | :--- |
| `/dashboard` | `/dashboard` | ✅ Exists | SRQL-driven dashboard engine with plugins (timeseries, categories, topology, table). |
| `/analytics` | `/analytics` | ✅ Exists | Operator overview hub (KPIs, charts, severity summaries, drill-down). |
| `/devices` | `/devices` | ✅ Exists | Inventory table includes Online/Offline + bulk ICMP sparkline health column. |
| `/devices/:id` | `/devices/:device_id` | ✅ Exists | SRQL-driven details page with metric charts (cpu/memory/disk). |
| `/events` | `/events` | ✅ Exists | SRQL list page. |
| `/logs` | `/logs` | ✅ Exists | SRQL list page. |
| `/services` | `/services` | ✅ Exists | SRQL list page. |
| `/interfaces` | `/interfaces` | ✅ Exists | SRQL list page. |
| `/metrics` | (new) `/metrics` | ❌ Missing | Legacy “system metrics” views; can be recreated via SRQL metrics entities + charts. |
| `/network` | (new) `/network` | ❌ Missing | Network discovery, sweeps, SNMP summaries (likely mixes SRQL tables + purpose-built dashboards). |
| `/observability` | (new) `/observability` | ❌ Missing | Logs/traces/metrics tabs; SRQL can cover read views, but may need richer UI patterns. |
| `/identity` | (new) `/identity` | ❌ Missing | Identity reconciliation UI; likely needs non-trivial workflow UIs beyond SRQL tables. |
| `/admin/*` | (new) `/admin/*` | ❌ Missing | Edge onboarding packages UI and other admin tools have not been ported. |

## 12. UI Component Strategy (Tailwind + daisyUI + MCP)

- `web-ng/` uses Tailwind + daisyUI for styling.
- All reusable primitives MUST live in `ServiceRadarWebNGWeb.UIComponents` (and SRQL composites in `ServiceRadarWebNGWeb.SRQLComponents`) so feature LiveViews do not hand-roll class soup.
- When introducing new UI components, prefer daisyUI component patterns (cards, stats, badges, tables, dropdowns, tooltips) and derive their markup from the daisyUI snippet catalog (via the daisy MCP server) before custom-building.

## 13. Charting & Visualization Strategy

### Principles
- Prefer server-rendered SVG for small “micro charts” (sparklines) to keep LiveView fast and dependency-light.
- Use the existing dashboard plugin system for “real” charts on `/dashboard` and the planned `/analytics` hub.
- Keep visualizations bounded: cap points/series and degrade gracefully to tables when results are not chartable.

### Planned Additions
- Add an `/analytics` LiveView implemented as a curated dashboard definition (multiple SRQL queries -> multiple panels).
- Extend visualization support where needed:
  - “KPI/Stat” panels (single-value outputs).
  - “Donut/Pie” or “Stacked” availability chart (optional; can start as categories bars).

## 14. ICMP Sparkline in Device Inventory (Data + Performance)

### Data source
ICMP latency is ingested into the database and is queryable via SRQL (typically through `timeseries_metrics` where `metric_type = "icmp"`).

### Query strategy (avoid N+1)
- The device list page MUST NOT fetch metrics per row.
- Fetch ICMP sparkline data in a single bulk query scoped to the current page’s device IDs and a fixed time window (e.g., last 1h).
- Downsample on the server (TimescaleDB `time_bucket`) to a small, fixed point count suitable for an inline sparkline (e.g., <= 20 points per device).

### Rendering strategy
- Render each sparkline as SVG (polyline/area) with a color derived from the latest latency bucket (e.g., green/yellow/red thresholds).
- Tooltip can be implemented with a native `<title>` or daisyUI tooltip patterns, but must not require per-point client JS.

### Guardrails
- Cap device count (page size) and point count to prevent heavy queries.
- Use bounded refresh semantics (e.g., manual refresh or a conservative interval), and ensure empty/no-data cases render cleanly.
