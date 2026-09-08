# Change: Add NetFlow Stats Dashboard with Reusable Stat Components

## Why

The `/flows` page has powerful visualization and query capabilities but lacks a stats-first landing experience — the "Top N" summaries, bandwidth gauges, and capacity planning views that network admins reach for first when investigating traffic. Issue #2965 outlines five categories of stats: Top-N dashboards, time-series/capacity planning, security/troubleshooting, routing/edge, and QoS. Most of the underlying data, enrichment, and chart infrastructure is already built; what's missing is the **aggregated stat components** and the **dashboard homepage** that ties them together.

Critically, these stat components (Top-N tables, stat cards, sparkline mini-charts, protocol/app breakdowns) must be **reusable Phoenix function components** so they can be embedded in device details, flow detail panels, and future contexts without duplication.

## What Changes

### Phase 1: Reusable Stat Component Library
- New `flow_stat_components.ex` module with composable function components:
  - `<.stat_card>` — single KPI (e.g., total bandwidth, active flows, unique talkers) with optional sparkline
  - `<.top_n_table>` — ranked table (Top Talkers, Top Listeners, Top Conversations, Top Apps, Top Protocols) with click-to-filter drill-down callback
  - `<.protocol_breakdown>` — donut/pie chart showing protocol or app distribution
  - `<.traffic_sparkline>` — small inline time-series (bps/pps) for embedding in cards or table cells
  - `<.bandwidth_gauge>` — percent-of-capacity gauge (requires interface speed from `netflow_interface_cache`)
- All components accept data via assigns (no internal SRQL queries) — the caller fetches data and passes it in
- All components emit events via configurable callback attrs for drill-down integration

### Phase 2: TimescaleDB Continuous Aggregates (CAGGs)
- 5-minute, 1-hour, and 1-day materialized CAGGs over `platform.ocsf_network_activity`
- Auto-resolution: SRQL engine selects raw vs CAGG based on query time window (<6h raw, 6-48h 5min, 2-30d 1h, 30d+ 1d)
- CAGGs pre-aggregate: bytes, packets, flow count by (src_ip, dst_ip, protocol, dst_port, app, sampler_address, direction)
- Refresh policies: 5min CAGG refreshes every 5 minutes, 1h every hour, 1d every day

### Phase 3: Flows Dashboard Homepage
- New landing view at `/flows` (current visualize page moves to `/flows/visualize`)
- Dashboard layout: grid of stat cards + top-N tables + traffic sparkline
- Default widgets: Total Bandwidth (bps), Active Flows, Top 10 Talkers, Top 10 Listeners, Top 10 Conversations, Top 5 Applications, Top 5 Protocols, Traffic Over Time (sparkline area chart)
- Time window selector (Last 1h / 6h / 24h / 7d / 30d) — drives CAGG auto-resolution
- Click any stat/row to navigate to `/flows/visualize` with pre-applied SRQL filter
- Units selector: bits/sec, bytes/sec, packets/sec

### Phase 4: Capacity Planning Extensions
- 95th percentile calculation on bandwidth CAGGs (per-interface, per-subnet)
- Percent-of-capacity display using interface speed from `netflow_interface_cache`
- Subnet/VLAN traffic distribution grouping (by configurable CIDR blocks from `netflow_local_cidrs`)

## Impact
- Affected specs: `build-web-ui` (new dashboard route + components), `cnpg` (new CAGGs)
- Affected code:
  - `web-ng/lib/serviceradar_web_ng_web/components/flow_stat_components.ex` (NEW)
  - `web-ng/lib/serviceradar_web_ng_web/live/netflow_live/dashboard.ex` (NEW)
  - `web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize.ex` (route change)
  - `web-ng/assets/js/hooks/charts/` (sparkline + gauge hooks)
  - `elixir/serviceradar_core/` (CAGG migrations, SRQL auto-resolution)
  - `web-ng/lib/serviceradar_web_ng_web/router.ex` (route restructure)
- Reuse surface: `flow_stat_components` will be consumed by device details flows tab, topology drill-downs, and alert context panels in future changes
