## 1. UI Architecture & Routing
- [ ] 1.1 Create `/netflow` LiveView route and `NetflowLive.Index` module with left-panel/right-panel layout
- [ ] 1.2 Add redirect from `/observability` netflows tab to `/netflow` with query param preservation
- [ ] 1.3 Implement options panel layout: time range, dimensions, filters, graph type, units, SRQL query input
- [ ] 1.4 Implement URL state serialization/deserialization with LZString compression (`v1-` prefix format)
- [ ] 1.5 Add saved view management (create, load, delete named views persisted to DB)

## 2. D3 Chart Components (LiveView Hooks)
- [ ] 2.1 Build shared D3 utility module: axes, tooltips, legends, responsive layout, color palette (5 base colors with 11 shades each, light/dark theme support)
- [ ] 2.2 Implement Stacked Area chart hook with gradient fills, hover tooltip (value + timestamp), legend toggle, brush selection for time range zoom
- [ ] 2.3 Implement 100% Stacked Area chart hook (normalized to percentages, same interactivity as stacked)
- [ ] 2.4 Implement Line Series chart hook (multiple independent lines, per-series hover values)
- [ ] 2.5 Implement Grid chart hook (multi-panel layout, auto-calculate rows/cols via sqrt, independent Y-axes per panel)
- [ ] 2.6 Upgrade existing Sankey hook to match new shared utility patterns (consistent tooltips, color palette, responsive layout)
- [ ] 2.7 Implement bidirectional mode: dual Y-axes (forward axis 1, reverse axis 2), direction labels, tooltip showing both directions
- [ ] 2.8 Implement previous period overlay: detect period (hour/day/week/month/year), render ghost series with reduced opacity, tooltip showing current vs previous values
- [ ] 2.9 Implement data table below chart: tabular dimension breakdowns with statistics columns (average, min, max, 95th percentile per series)
- [ ] 2.10 Implement brush-to-zoom: D3 brush on time-series charts pushes new time range to LiveView, which re-queries and updates URL

## 3. Dimension System
- [ ] 3.1 Implement dimension selector component: multi-select from server-provided dimension list, drag-and-drop reordering, color-coded categories
- [ ] 3.2 Add IP truncation option for IP-type dimensions (configurable prefix length: /8, /16, /24 for IPv4; /32, /48, /64 for IPv6)
- [ ] 3.3 Add top-N limit control (1-50 items per dimension)
- [ ] 3.4 Add "top-by" mode selector (average, max, last) for ranking series
- [ ] 3.5 Define dimension categories with color coding:
  - Exporter: ExporterName, ExporterGroup, ExporterSite (blue)
  - Source: SrcIP, SrcAS, SrcCountry, SrcPort, SrcNetPrefix (green)
  - Destination: DstIP, DstAS, DstCountry, DstPort, DstNetPrefix (purple)
  - Ingress Interface: InIfName, InIfDescription, InIfSpeed, InIfBoundary (cyan)
  - Egress Interface: OutIfName, OutIfDescription, OutIfSpeed, OutIfBoundary (orange)
  - Other: Proto, EType, App, Direction, TCPFlags (grey)

## 4. SRQL Filter Bar
- [ ] 4.1 Implement filter input with syntax highlighting for SRQL tokens (field names, operators, values, time ranges)
- [ ] 4.2 Add auto-completion dropdown populated from SRQL catalog (field names, known values for enum fields like protocol_group, direction, etype)
- [ ] 4.3 Add real-time validation that shows parse errors inline as user types
- [ ] 4.4 Add saved filter management: save current filter expression with a name, load saved filters from dropdown, share/unshare filters

## 5. Units & Aggregation
- [ ] 5.1 Add units selector: bits/sec (L3), bytes/sec, packets/sec, percentage of interface capacity
- [ ] 5.2 Implement percentage-of-capacity unit: requires interface speed from cache, formula `(traffic_bps / if_speed_bps) * 100`
- [ ] 5.3 SRQL: support `units:` parameter that controls aggregation (sum bytes → bps, sum packets → pps)

## 6. Interface Name Resolution
- [ ] 6.1 Create `platform.flow_interface_cache` table: `(sampler_address, if_index) → if_name, if_description, if_speed, if_boundary, device_id, device_name, updated_at`
- [ ] 6.2 Create `FlowInterfaceCacheRefreshWorker` (Oban): queries distinct `(sampler_address, input_snmp, output_snmp)` from recent flows, joins to interface inventory via device lookup (sampler_address → device IP → device_id → interfaces by if_index), upserts cache
- [ ] 6.3 SRQL: add `in_if_name`, `out_if_name`, `in_if_speed`, `out_if_speed`, `in_if_description`, `out_if_description`, `in_if_boundary`, `out_if_boundary` as filter and group-by dimensions via LEFT JOIN to `flow_interface_cache`
- [ ] 6.4 SRQL: add `exporter_name` dimension derived from sampler_address → device name lookup in same cache
- [ ] 6.5 Add interface name display in flow detail panel and flow table columns

## 7. Exporter Metadata
- [ ] 7.1 Extend `flow_interface_cache` to include exporter-level metadata: `exporter_name`, `exporter_site`, `exporter_role`, `exporter_group` (from device inventory attributes)
- [ ] 7.2 SRQL: add `exporter_site`, `exporter_role`, `exporter_group` as filter/group-by dimensions
- [ ] 7.3 Add exporter overview widget on dashboard: list of active exporters with interface counts, flow rates, last seen timestamps

## 8. Deep Application Classification
- [ ] 8.1 Create `platform.netflow_app_ip_ranges` table: `(id, cidr, app_label, provider, source, priority, enabled, notes, updated_at)`
- [ ] 8.2 Ship default IP range dataset for major services: Netflix, YouTube/Google, Microsoft/Xbox, Cloudflare, AWS, GCP, Azure, Akamai, Fastly, Apple, Meta/Facebook, Discord, Steam, Roblox, Minecraft/Mojang, Spotify, Zoom, Slack, Twitch, TikTok
- [ ] 8.3 Create `AppIpRangeRefreshWorker` (Oban): scheduled import from configurable URL sources (JSON/CSV format), idempotent upsert with source tracking
- [ ] 8.4 SRQL: update app classification expression to 3-tier: `COALESCE(admin_rule_match, ip_range_match, port_baseline, 'unknown')`
- [ ] 8.5 Admin UI: manage IP range entries with CRUD, bulk import/export, source filtering
- [ ] 8.6 Add provider IP range auto-import for AWS (`ip-ranges.json`), GCP, Azure, Cloudflare published IP lists

## 9. Additional Flow Schema Fields
- [ ] 9.1 Add `etype` column (integer, 0x0800=IPv4, 0x86dd=IPv6) to `ocsf_network_activity` if not present; populate from flow export data
- [ ] 9.2 Add `tcp_flags` column (integer, bitmask) and `tcp_flags_decoded` (text array: SYN, ACK, FIN, RST, PSH, URG) to schema
- [ ] 9.3 Add `ip_tos` / `dscp` column (integer) for QoS/DSCP marking visibility
- [ ] 9.4 Add `next_hop` column (inet) for routing path analysis
- [ ] 9.5 Add `flow_direction` column (enum: undefined/ingress/egress) for exporter-perspective directionality (distinct from our computed direction)
- [ ] 9.6 Add `src_vlan` / `dst_vlan` columns (integer) for VLAN visibility
- [ ] 9.7 Add `sampling_rate` column (integer) for accurate volume scaling
- [ ] 9.8 SRQL: register all new fields as filter and group-by dimensions
- [ ] 9.9 Verify NetFlow collector exports these fields; document any fields requiring collector-side changes

## 10. AlienVault OTX Integration
- [ ] 10.1 Add `alienvault_otx` as a feed provider type in `ThreatIntelFeedRefreshWorker`
- [ ] 10.2 Implement OTX API client: fetch pulses via `/api/v1/indicators/export`, parse JSON response, extract IPv4/IPv6 CIDR indicators with severity mapping
- [ ] 10.3 Add OTX API key configuration to `netflow_settings` (encrypted via AshCloak)
- [ ] 10.4 Add OTX pulse subscription configuration (subscribe to specific pulses or use default)
- [ ] 10.5 Test with real OTX data and verify indicators appear in threat intel cache

## 11. Network Dictionary System
- [ ] 11.1 Create `platform.network_dictionaries` table: `(id, name, description, enabled, created_at, updated_at)`
- [ ] 11.2 Create `platform.network_dictionary_entries` table: `(id, dictionary_id, cidr, attributes JSONB, enabled, priority)` with GIST index on cidr
- [ ] 11.3 SRQL: add `net:<dict_name>:<attr>` syntax for group-by dimensions (e.g., `net:zones:zone_name`)
- [ ] 11.4 Admin UI: dictionary CRUD, entry CRUD with bulk import (CSV: cidr, attr1, attr2, ...)
- [ ] 11.5 Ship example dictionaries: RFC1918 zones, cloud provider ranges

## 12. Multi-Resolution Continuous Aggregates
- [ ] 12.1 Create 5min CAGG on `ocsf_network_activity`: aggregate bytes_total, packets_total, flow count by (time_bucket, sampler_address, src_endpoint_ip, dst_endpoint_ip, src_endpoint_port, dst_endpoint_port, protocol_num, direction, app)
- [ ] 12.2 Create 1h CAGG: further aggregate the 5min CAGG
- [ ] 12.3 Create 1d CAGG: further aggregate the 1h CAGG
- [ ] 12.4 Add retention policies: raw=30d, 5min=90d, 1h=1y, 1d=3y (configurable)
- [ ] 12.5 SRQL: implement auto-resolution selection based on query time range (< 6h → raw, 6h-48h → 5min, 2d-30d → 1h, 30d+ → 1d)

## 13. Dashboard Homepage
- [ ] 13.1 Create dashboard layout with configurable widget grid
- [ ] 13.2 Implement flow rate gauge widget (current bps/pps with sparkline trend)
- [ ] 13.3 Implement top-N pie/donut chart widgets (configurable: by AS, country, exporter, protocol, port, application)
- [ ] 13.4 Implement active exporters list widget (name, interface count, flow rate, last seen)
- [ ] 13.5 Implement mini traffic graph widget (24h stacked area, configurable dimension)
- [ ] 13.6 Implement last flow detail widget (most recent flow with full field display)
- [ ] 13.7 Make widget configuration persistent per user (which widgets enabled, order, top-N selections)

## 14. Geo Heatmap Enhancements
- [ ] 14.1 Upgrade geo heatmap to support both source and destination country views (toggle)
- [ ] 14.2 Add country-level click-to-filter (clicking a country adds `src_country:XX` or `dst_country:XX` filter)
- [ ] 14.3 Add city-level granularity when zoomed in (requires city-level GeoIP data, already in enrichment cache)
- [ ] 14.4 Add traffic flow lines between countries (animated arcs showing major traffic paths)

## 15. Validation & Testing
- [ ] 15.1 Run `openspec validate overhaul-netflow-analytics-parity --strict`
- [ ] 15.2 Unit tests for all D3 chart hooks (render with sample data, verify SVG output)
- [ ] 15.3 SRQL tests for new dimensions (in_if_name, exporter_name, etype, tcp_flags, etc.)
- [ ] 15.4 Integration tests for interface resolution cache worker
- [ ] 15.5 Integration tests for application IP range classification
- [ ] 15.6 Integration tests for AlienVault OTX feed import
- [ ] 15.7 Performance benchmarks: multi-resolution CAGG query times vs raw table for 24h/7d/30d windows
- [ ] 15.8 Verify all chart types render correctly with sample data in demo environment
- [ ] 15.9 Verify URL state serialization round-trips correctly for all parameter combinations

## 16. Documentation & Migration
- [ ] 16.1 Update user-facing docs for new `/netflow` route and features
- [ ] 16.2 Document application IP range import format and auto-import sources
- [ ] 16.3 Document network dictionary configuration
- [ ] 16.4 Document AlienVault OTX setup
- [ ] 16.5 Add migration guide for users moving from netflows tab to dedicated page
