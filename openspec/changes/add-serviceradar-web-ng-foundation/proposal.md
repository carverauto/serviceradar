# Change: Add `serviceradar-web-ng` (The New Monolith)

## Why
- **Complete Replacement:** We are replacing the existing React/Next.js frontend and the Go HTTP API entirely. The new Phoenix application will be the sole interface for users and API clients.
- **Architecture Shift:** Moving from Microservices (Kong + Go API + Rust Service + Next.js) to a Monolith (Phoenix + Embedded Rust).
- **Core Isolation:** `serviceradar-core` (Go) is being demoted to a background ingestion daemon. It will continue to write to the DB, but its HTTP endpoints will be bypassed and eventually ignored.
- **Simplification:** We are removing the need for the Kong API Gateway and the standalone SRQL HTTP service container. SRQL itself remains—it becomes an embedded library called via Rustler NIF.

## What Changes
- **New App:** Create `web-ng/` hosting `:serviceradar_web_ng`.
- **SRQL (Translator-Only):** Embed `rust/srql` via Rustler (NIF) as a *pure translator* that converts SRQL -> parameterized SQL (+ bind params + pagination metadata). Phoenix executes the SQL via Ecto/Postgrex using the existing `Repo` connection pool.
  - **Compatibility:** Translator-only mode MUST be additive. The existing SRQL HTTP service (and its query-execution behavior) remains supported during the migration.
- **SRQL-First Analytics:** All read-oriented analytics views (devices, pollers, metrics, traces, events, dashboards) are driven by SRQL queries executed via `POST /api/query` (translate in Rust, execute in Phoenix via Ecto).
  - **Query Visibility:** SRQL-driven pages MUST display the active SRQL query in a top navigation input (editable to re-run).
  - **Composable Dashboards:** Dashboards are built from one or more SRQL queries and auto-generate visualizations when the result shape is recognized; the visualization system MUST be modular and extensible.
- **UI Parity & Improvements (Legacy `web/` -> `web-ng/`):**
  - Recreate the missing “Analytics” hub (summary KPIs + charts) using SRQL-driven queries and dashboard visualizations.
  - Enhance the Device Inventory table to include health signals (online/offline + ICMP sparkline latency) without per-row N+1 queries.
  - Standardize UI primitives using Tailwind + daisyUI, with components expressed via Phoenix function components.
- **Database:** Connect Ecto to the existing Postgres/AGE instance.
  - *Telemetry Data:* Mapped to existing tables (Read-Only).
  - *App Data:* Fresh tables created/managed by Phoenix (Read/Write).
- **Auth:** **Fresh Start.** Implement standard `phx.gen.auth` using a new table (e.g., `ng_users`). We will **not** use the legacy `users` table or migrate old credentials.
- **Logic Porting:** Re-implement user-facing business logic from Go into Elixir Contexts.
- **Testing:** Establish property-based testing patterns early using `StreamData` (`ExUnitProperties`) for core invariants (token formats, parsing/validation, and “never crash” boundaries like NIF input handling).

## Non-Goals
- **No Go Changes:** We will not modify `serviceradar-core` source code.
- **No Auth Migration:** Legacy user accounts are abandoned. Users will register fresh accounts in the new system.
- **No API Compatibility:** The new API will follow Phoenix conventions, not strictly mimic the legacy Go API structure.
- **No SRQL DB Runtime in NIF:** SRQL MUST NOT open database connections, manage a separate pool, or require a Tokio runtime inside the Phoenix process. Query execution is handled by Phoenix via Ecto.
- **No SRQL Writes:** SRQL is the query engine for reads/analytics, not the primary mechanism for writes or stateful workflows (auth/settings/edge onboarding remain API + Ecto driven).
- **No Kubernetes Cutover Yet:** We will iterate in the local Docker Compose stack before making any k8s routing/cutover changes.

## Impact
- **Routing:** Local Docker Compose Nginx routes `/*` and `/api/*` to Phoenix for iteration; Kubernetes cutover is deferred.
- **Security:** Phoenix becomes the sole Authority for Identity.
- **Performance:** Elimination of internal HTTP hops for Query and API responses.
  - Translator-only SRQL reduces overhead (no extra DB pool/runtime in NIF) and consolidates DB access under Ecto.

## Status
- In progress (local compose iteration; k8s cutover deferred).
- SRQL translator-only pivot complete: Rust now translates SRQL -> parameterized SQL + typed bind params + pagination metadata; Phoenix executes via Ecto using `ServiceRadarWebNG.Repo`.
- Added safety checks: unit tests and debug-mode bind-count validation to ensure SQL placeholder arity matches returned params.
- SRQL-first analytics UX implemented (query bar + builder + SRQL-driven list pages).
- Dashboard renders charts/graphs when SRQL metadata supports it (Timeseries/Topology plugins), plus table fallback.
- Device details page exists at `/devices/:device_id` (SRQL-driven), including related CPU/memory/disk metric charts.
- UI parity gaps remain vs `web/`: `/analytics` hub, `/network`, `/observability`, `/identity`, and device list health (ICMP sparkline) are not yet ported.
- UI remains Tailwind + daisyUI (no Mishka Chelekom adoption at this time).
