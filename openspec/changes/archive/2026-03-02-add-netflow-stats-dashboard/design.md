## Context

The `/flows` page currently serves as both the entry point and the visualization surface. Issue #2965 requests a stats-first dashboard experience. The existing D3 chart hooks (stacked area, line, Sankey, grid, 100% stacked) and the SRQL-driven query pipeline are mature. What's needed is a component layer that aggregates stats and a CAGG layer that makes long-window queries fast.

The user explicitly requires **reusable components** — the stat cards, top-N tables, and sparklines built here will be embedded in device details flows tab, topology panels, and other contexts in subsequent changes.

## Goals / Non-Goals

- **Goals:**
  - Build a `flow_stat_components.ex` module of pure function components (no internal state, no SRQL queries)
  - Create TimescaleDB CAGGs for fast aggregation over large time windows
  - Deliver a dashboard homepage at `/flows` with drill-down to `/flows/visualize`
  - Support units selection (bps/Bps/pps) and capacity-percentage display
  - All components work in both light and dark themes (daisyUI)

- **Non-Goals:**
  - Per-user widget persistence / customizable dashboard layout (future)
  - QoS/DSCP visualization (separate change)
  - Threat intel / security dashboards (already feature-flagged in observability dashboard)
  - New enrichment sources (OTX, app IP ranges — separate Phase F changes)

## Decisions

### Component Architecture: Pure Function Components
- **Decision:** All stat components are Phoenix function components in a single module, accepting data via assigns and emitting events via callback attrs
- **Why:** Maximum reuse — any LiveView can render `<.top_n_table rows={@top_talkers} on_click={&drill_down/1} />` without coupling to the dashboard's data-fetching logic
- **Alternative:** LiveComponent with internal data loading — rejected because it couples the component to a specific SRQL query pattern and prevents embedding in non-flow contexts

### CAGG Strategy: 3-Tier with Auto-Resolution
- **Decision:** 5min / 1h / 1d CAGGs with SRQL engine auto-selecting based on query window
- **Why:** Matches TimescaleDB best practices; 5min gives good resolution for <48h, 1h for weeks, 1d for months
- **Alternative:** Single rollup table with custom aggregation — rejected; CAGGs are maintained automatically by TimescaleDB and are query-transparent

### Route Restructure: `/flows` → dashboard, `/flows/visualize` → current page
- **Decision:** Dashboard becomes the landing page; existing visualize page gets a sub-route
- **Why:** Stats-first experience matches what network admins expect; visualize is a drill-down destination
- **Alternative:** Dashboard as a tab within current page — rejected; the dashboard has a fundamentally different layout (widget grid vs two-panel)

### Sparkline Hook: Lightweight D3 Micro-Chart
- **Decision:** New `FlowSparkline` JS hook — minimal D3 area chart, no axes/legends, responsive, theme-aware
- **Why:** Existing `NetflowStackedAreaChart` is too heavy for inline use in cards/tables; sparklines need to be <50 lines of JS
- **Alternative:** CSS-only sparklines — rejected; insufficient for smooth area fills and responsive resizing

## Risks / Trade-offs

- **CAGG migration on large tables:** Creating CAGGs on existing hypertables with significant data may take time. Mitigation: run CAGG creation in a migration with `IF NOT EXISTS`, and initial refresh is incremental.
- **Route change breaks bookmarks:** `/flows` currently points to visualize. Mitigation: redirect `/flows?nf=...` to `/flows/visualize?nf=...` preserving state params.
- **Component API stability:** The function component API (assigns) becomes a contract for downstream consumers. Mitigation: document required vs optional assigns in module docs; keep the interface minimal.

## Open Questions

- Should the dashboard auto-refresh on a timer (e.g., every 60s), or only refresh on manual action?
- Should we support a "compact" variant of stat components for embedding in sidebars/panels vs the full-width dashboard?
