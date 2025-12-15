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
