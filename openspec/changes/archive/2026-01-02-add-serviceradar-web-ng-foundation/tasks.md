## 1. Foundation & Plumbing

### Application & DB
- [x] 1.1 Scaffold `serviceradar_web_ng` (Phoenix 1.7+, LiveView) in `web-ng/`.
- [x] 1.2 Configure `Ecto` to connect to the existing CNPG/AGE database.
  - [x] *Note:* Support remote dev via `CNPG_*` env vars + TLS client certs.
  - [x] *Note:* Publish CNPG for workstation access via Compose `CNPG_PUBLIC_BIND`/`CNPG_PUBLIC_PORT` and cert SANs via `CNPG_CERT_EXTRA_IPS`.
- [x] 1.3 Port the Graph Abstraction (`ServiceRadarWebNG.Graph`) from `Guided` to support AGE queries.
  - [x] *Note:* Add `mix graph.ready` to validate AGE connectivity.

### SRQL Engine (Rustler)
- [x] 1.4 Refactor `rust/srql` to expose public library functions.
- [x] 1.5 Implement `native/srql_nif` in Phoenix (Async NIF pattern).
- [x] 1.6 Implement `ServiceRadarWebNG.SRQL` module.
- [x] 1.6a Pivot to **translator-only** SRQL architecture (no DB/runtime in NIF).
  - [x] Refactor `rust/srql` to expose a stable translate API (SQL + bind params + pagination metadata).
  - [x] Update `native/srql_nif` to export translate-only functions (no Tokio runtime, no DB connections).
  - [x] Update Phoenix to execute translated SQL via Ecto using `ServiceRadarWebNG.Repo`.
  - [x] Add integration tests to validate SRQL translation + execution from Elixir.
  - [x] Add bind/placeholder arity validation in Rust (tests + debug checks).
  - [x] Ensure existing SRQL HTTP service behavior remains intact (run existing `rust/srql` tests).
- [x] 1.6b Extend SRQL translate output with visualization metadata (column types, semantic hints) to support composable dashboards.
- [x] 1.6c Extend SRQL to support query patterns required by dashboards:
  - [x] TimescaleDB-friendly time windowing and downsampling helpers.
  - [x] AGE relationship queries (compiled into SQL using AGE `cypher()`), so graph panels can be SRQL-driven.

### Property-Based Testing (StreamData)
- [x] 1.7 Add `stream_data` (and `ExUnitProperties`) to the `web-ng` ExUnit suite.
  - [x] Add the dependency to `web-ng/mix.exs` (`stream_data`) under `only: :test`.
  - [x] Ensure `ExUnitProperties` is available in tests.
- [x] 1.8 Integrate property-based testing into the `web-ng` ExUnit suite.
  - [x] Add shared generators under `web-ng/test/support/generators/`.
  - [x] Add `web-ng/test/property/` with at least one starter property test.
  - [x] Ensure `mix test` runs property tests by default with bounded case-counts and an env override for deeper runs.

## 2. Authentication (Fresh Implementation)
- [x] 2.1 Run `mix phx.gen.auth Accounts User ng_users`.
  - [x] *Note:* Using `ng_users` ensures we do not conflict with the legacy `users` table.
- [x] 2.2 Run migrations to create the new auth tables.
  - [x] *Note:* Use a dedicated Ecto migration source table to avoid collisions in shared CNPG (e.g., `ng_schema_migrations`).
- [x] 2.3 Verify registration/login flow works independently of the legacy system.

## 3. Logic Porting (Shared Data)

### Inventory & Infrastructure
- [x] 3.1 Create Ecto schemas for `unified_devices`, `pollers`, `services` (no migrations).
  - [x] *Note:* Use `@primary_key {:id, :string, autogenerate: false}`.
  - [x] *Note:* "No migrations" means Phoenix does not own the table DDL—Go Core does. Phoenix CAN still read/write data to these tables.
  - [x] 3.1a Add `unified_devices` schema.
  - [x] 3.1b Add `pollers` schema.
  - [x] 3.1c Add `services` schema.
- [x] 3.2 Implement `Inventory.list_devices`.
- [x] 3.3 Implement `Infrastructure.list_pollers`.

### Edge Onboarding
- [x] 3.4 Port `EdgeOnboardingPackage` schema (Shared Data).
- [x] 3.5 Implement token generation logic in Elixir.
  - [x] 3.5a Add property tests for token encode/decode invariants (round-trip, URL-safe encoding, and invalid input handling).

## 4. UI & API Implementation

### SRQL-First UX (Analytics Pages)
- [x] 4.0 Add a global SRQL query bar in the top navigation for SRQL-driven pages.
  - [x] *Note:* It MUST display the exact SRQL query used to render the current view.
  - [x] *Note:* It MUST allow editing + re-running the query with bounded errors (no LiveView crashes).
  - [x] *Note:* It SHOULD support deep-linking by storing the SRQL query in the URL (shareable links).
- [x] 4.0a Add SRQL-driven page helpers (common LiveView patterns: query state, loading/error states, query execution).
- [x] 4.0b Add property tests to ensure query input handling never crashes (malformed queries, malformed params).
- [x] 4.0c Add an SRQL query builder UI accessible from the query bar (toggle icon + expandable panel).
  - [x] 4.0d Keep SRQL text as the source of truth; builder generates SRQL by updating the query bar.
  - [x] 4.0e Implement a bounded fallback state when SRQL can't be represented by the builder (no destructive rewrites).
  - [x] 4.0f Render the builder panel under the navbar (no navbar height changes).
  - [x] 4.0g Support multiple filters in the builder UI (add/remove).
  - [x] 4.0h Drive builder entities/fields from a catalog (easy to extend beyond devices/pollers).

### API Replacement
- [x] 4.1 Create `ServiceRadarWebNG.Api.QueryController` (SRQL endpoint).
  - [x] 4.1a Add property tests for request validation/decoding to ensure malformed JSON and random inputs never crash the endpoint.
- [x] 4.1b Update `/api/query` implementation to translate SRQL -> SQL and execute via Ecto (translator-only plan).
- [x] 4.2 Create `ServiceRadarWebNG.Api.DeviceController`.
  - [x] 4.2a Include property tests for any new parsing/validation logic introduced by the device API (IDs, filters, and pagination).

### Dashboard (LiveView)
- [x] 4.3 Re-implement the main Dashboard using LiveView (SRQL-first and composable).
  - [x] 4.3a Implement a composable dashboard engine (query-driven widgets, visualization selection).
  - [x] 4.3b Implement result-shape detection and visualization inference (prefer SRQL-provided metadata).
  - [x] 4.3c Implement a plugin/registry mechanism for adding new visualizations without rewriting the engine.
  - [x] 4.3d Implement time series widgets suitable for TimescaleDB hypertables (time-bounded windows, aggregation).
  - [x] 4.3e Implement relationship/topology widgets backed by Apache AGE graph queries.
  - [x] 4.3f Support deep-linking dashboards from SRQL (store query or dashboard definition in URL).
  - [x] 4.3g Add tests for dashboard query execution and bounded error handling.
  - [x] 4.3h Add SRQL-first Dashboard LiveView at `/dashboard` (query bar + results table).
  - [x] 4.3i Add initial auto-viz inference (heuristics; replace with SRQL metadata in 1.6b/4.3b).
- [x] 4.4 Implement Device List view.
  - [x] *Note:* Add authenticated `GET /devices` (initial scaffolding).
  - [x] 4.4a Migrate `/devices` to be SRQL-driven and show the active SRQL query in the global query bar.
- [x] 4.5 Implement Poller List view.
  - [x] *Note:* Add authenticated `GET /pollers` (initial scaffolding).
  - [x] 4.5a Migrate `/pollers` to be SRQL-driven and show the active SRQL query in the global query bar.
- [x] 4.6 Implement Events List view (SRQL-driven).
- [x] 4.7 Implement Logs List view (SRQL-driven).
- [x] 4.8 Implement Services List view (SRQL-driven).
- [x] 4.9 Implement Interfaces List view (SRQL-driven).
- [x] 4.10 Add sidebar navigation layout (move analytics navigation to sidebar; keep SRQL query bar in the top header).

## 5. Docker Compose Cutover (Local)
- [x] 5.1 Update `docker-compose.yml` to expose `web-ng` on port 80/443.
- [x] 5.2 Remove `kong` container from deployment.
- [x] 5.3 Remove standalone `srql` HTTP service container from deployment (SRQL is now embedded in Phoenix via Rustler).

## 6. UI Polish & UX (Follow-up)
- [x] 6.1 Move ServiceRadar branding/logo into the left navigation sidebar.
- [x] 6.2 Reduce sidebar width and tighten spacing.
- [x] 6.3 Improve table styling across SRQL-driven pages (readability, hover, truncation).
- [x] 6.3a Format SRQL table cells (dates/URLs/badges) for readability.
- [x] 6.3b Upgrade Events/Logs/Services pages with panels + quick filters.
- [x] 6.4 Ensure Dashboard renders charts/graphs when results support it (not table-only).
- [x] 6.5 Add Device details page (SRQL-driven, with related charts where available).
- [x] 6.5a Hide metric sections when no data is present (no empty charts).
- [x] 6.6 Default Dashboard query to a metrics entity so charts render out-of-the-box.
- [x] 6.7 Add CPU/memory/disk metric chart sections to Device details.
- [x] 6.7a Reduce CPU panel noise (aggregate across cores by default).
- [x] 6.7b Improve timeseries charts (labels + shaded area + min/max/latest).
- [x] 6.8 Add `/analytics` hub page (SRQL-driven, chart-first).
  - [x] 6.8a Add sidebar navigation entry for Analytics.
  - [x] 6.8b Implement “KPI cards” (total devices, offline devices, high latency, failing services).
  - [x] 6.8c Add at least 4 visualization panels (timeseries/categories) with sensible defaults (no empty dashboard).
  - [x] 6.8d Add drill-down interactions (click KPI/chart -> navigate with pre-filtered SRQL).
- [x] 6.9 Upgrade `/devices` table for operational at-a-glance.
  - [x] 6.9a Add “Health & Metrics” column with Online/Offline + ICMP sparkline latency.
  - [x] 6.9b Query ICMP sparkline data in bulk (no per-row N+1 queries) for the current page device IDs.
  - [x] 6.9c Ensure bounded performance (downsample, cap points, conservative refresh).
  - [x] 6.9d Add tooltip/legend affordances for sparkline thresholds.

## 7. Kubernetes Cutover (Deferred)
- [ ] 7.1 Add `serviceradar-web-ng` image build/push for k8s deployment.
- [ ] 7.2 Update demo k8s ingress/service routing to point to `web-ng`.
- [ ] 7.3 Remove Kong and SRQL HTTP service from k8s deployment.

## 8. UI Polish Phase 2 (Dracula Theme & Styling)
- [x] 8.1 Implement Dracula color theme in daisyUI config.
  - [x] Update dark theme to use proper Dracula colors (purple, pink, cyan, green, orange).
  - [x] Reduced border width to 1px for cleaner look.
- [x] 8.2 Improve timeseries chart styling.
  - [x] Update chart colors to Dracula palette (green, cyan, purple, pink, orange, yellow).
  - [x] Improve gradient fills with higher opacity for better visibility.
- [x] 8.3 Improve ICMP sparkline in device inventory.
  - [x] Add gradient fill under the line (like React version).
  - [x] Use SVG path for area fill instead of plain polyline.
  - [x] Use Dracula colors for tone-based styling (green for success, orange for warning, red for error).
  - [x] Improve line styling with rounded caps/joins.
- [x] 8.4 Improve KPI cards in analytics dashboard.
  - [x] Add larger icon boxes with better contrast.
  - [x] Add hover scale effect for interactivity.
  - [x] Use tone-based coloring for values (warning/error numbers stand out).
  - [x] Add uppercase tracking for titles.

## 9. Known Issues (To Investigate)
- [x] 9.1 SRQL stats query issue - "missing ':' in token" error.
  - This error originates from the SRQL Rust parser (srql crate).
  - Fixed parser to accept unquoted `stats:count() as total` by consuming `as <alias>` tokens as part of the `stats` expression.
  - Implemented in `rust/srql` crate parser with regression tests.
- [x] 9.2 KPI cards showing 0 total devices.
  - Fixed: Stats queries now execute correctly after 9.1 fix.
  - Service counts now show unique services (by device_id:service_name composite key) instead of raw status check records.
- [x] 9.3 Scalability considerations for 50k+ devices.
  - Design principle established: All UI must work at scale (50k to 2mil assets).
  - Analytics KPI cards use aggregate queries, not per-device iteration.
  - Service counts use bounded queries with unique counting logic.
  - Remaining scale considerations tracked in Section 10.

## 10. UI Polish Phase 3 (Scale-First Design)

**Design Principle:** All UI must work seamlessly from 1 device to 2 million devices.

### Recent Fixes (Completed)
- [x] 10.1 Fix critical logs/events widget scrolling in analytics dashboard.
  - Changed from `ui_panel` to explicit flex structure with proper overflow handling.
- [x] 10.2 Add hover tooltips to timeseries charts (like React/Recharts version).
  - Added `TimeseriesChart` JavaScript hook with mousemove/mouseleave handlers.
  - Tooltip shows value and timestamp at cursor position with vertical line indicator.
- [x] 10.3 Make device details overview compact (inline key-value pairs).
  - Replaced verbose table layout with horizontal flex wrap.
- [x] 10.4 Fix timeseries chart width (was 1/5 of container, now full-width).
  - Changed `preserveAspectRatio` and increased chart width to 800px.
- [x] 10.5 Remove verbose timeseries labels ("Timeseries value over timestamp").
  - Simplified chart headers to show series name + latest value only.
- [x] 10.6 Fix service count showing all status checks instead of unique services.
  - Count unique services by `device_id:service_name` composite key.
  - Changed labels from "Total Services" to "Active Services (unique)".

### Events Stream Improvements
- [x] 10.7 Consolidate events table columns (reduce horizontal scroll).
  - [x] Show only essential columns: timestamp, severity, source, message summary.
  - [x] Hide `event_type` column (not populated in current data).
  - [x] Map raw column names to human-readable labels (Time, Severity, Source, Message).
- [x] 10.8 Add Event details page (`/events/:id`).
  - [x] Show full event payload (all fields not shown in table).
  - [x] Link from table row click to details page.
  - [x] JSON syntax highlighting for structured payloads.

### Logs Stream Improvements
- [x] 10.9 Consolidate logs table columns (reduce horizontal scroll).
  - [x] Show only essential columns: timestamp, level, service, message snippet.
  - [x] Map raw column names to human-readable labels (Time, Level, Service, Message).
- [x] 10.10 Add Log details page (`/logs/:id`).
  - [x] Show full log entry (complete message body, all metadata).
  - [x] Link from table row click to details page.
  - [x] JSON syntax highlighting for structured log payloads.
  - [x] Show trace/span IDs when available.

### Services Page Improvements
- [x] 10.11 Add visualization to Services availability page.
  - [x] Add KPI cards (total checks, available, unavailable) with percentage.
  - [x] Add "By Service Type" horizontal bar chart showing availability breakdown.
  - [x] Design works at scale: computes stats from bounded page results only.
  - [x] Groups by service type with color-coded available/unavailable bars.
- [x] 10.12 Ensure Services page performs at 50k+ services.
  - [x] Use pagination with bounded page sizes (default 50, max 200).
  - [x] Aggregate counts computed from current page only (not full inventory).
