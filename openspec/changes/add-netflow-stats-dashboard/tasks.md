## 1. Reusable Stat Component Library

- [x] 1.1 Create `flow_stat_components.ex` module with `@moduledoc` describing reuse contract
- [x] 1.2 Implement `<.stat_card>` component (title, value, unit, trend, optional sparkline slot)
- [x] 1.3 Implement `<.top_n_table>` component (columns, rows, rank, click callback, loading state)
- [x] 1.4 Implement `<.protocol_breakdown>` component (data assigns, donut chart hook integration)
- [x] 1.5 Implement `<.traffic_sparkline>` component (time-series data, area fill, responsive)
- [x] 1.6 Implement `<.bandwidth_gauge>` component (current bps, capacity bps, percent display)
- [x] 1.7 Create `FlowSparkline` JS hook (lightweight canvas area, responsive)
- [x] 1.8 Create `FlowDonut` JS hook (canvas donut/pie, legend, theme-aware)
- [x] 1.9 Create `BandwidthGauge` JS hook (placeholder for future animation)
- [x] 1.10 Add unit formatting helpers (bps/Bps/pps with SI prefix abbreviation)

## 2. TimescaleDB Continuous Aggregates

- [x] 2.1 Existing 5-minute traffic CAGG already present (`ocsf_network_activity_5m_traffic`)
- [x] 2.2 Create 1-hour traffic CAGG (hierarchical from 5-min CAGG)
- [x] 2.3 Create 1-day traffic CAGG (hierarchical from 1-hour CAGG)
- [x] 2.4 Add refresh policies (1h: every hour, 1d: every day, listeners/conversations: 5min)
- [x] 2.5 Create hourly listeners CAGG (by dst_endpoint_ip)
- [x] 2.6 Create hourly conversations CAGG (by src_endpoint_ip + dst_endpoint_ip)
- [ ] 2.7 Add 95th percentile aggregate function (query-time calculation — Phase 4)

## 3. Dashboard Homepage

- [x] 3.1 Create `NetflowLive.Dashboard` LiveView module
- [x] 3.2 Update router: `/flows` → Dashboard, `/flows/visualize` → existing Visualize
- [x] 3.3 Add redirect from `/flows?nf=...` to `/flows/visualize?nf=...` for backward compat
- [x] 3.4 Implement time window selector (1h / 6h / 24h / 7d / 30d)
- [x] 3.5 Implement units selector (bits/sec, bytes/sec, packets/sec)
- [x] 3.6 Wire stat card: Total Bandwidth (bps in + out)
- [x] 3.7 Wire stat card: Active Flows (unique flow count in window)
- [x] 3.8 Wire stat card: Unique Talkers (distinct src IPs)
- [x] 3.9 Wire top-N table: Top 10 Talkers (by bytes) with drill-down
- [x] 3.10 Wire top-N table: Top 10 Listeners (by bytes) with drill-down
- [x] 3.11 Wire top-N table: Top 10 Conversations (src↔dst pairs) with drill-down
- [x] 3.12 Wire top-N table: Top 10 Applications with drill-down
- [x] 3.13 Wire top-N table: Top 10 Protocols with drill-down
- [x] 3.14 Wire traffic-over-time sparkline area chart
- [x] 3.15 Implement drill-down: click stat/row → navigate to `/flows/visualize` with SRQL filter
- [x] 3.16 Update all cross-file references from `/flows` to `/flows/visualize` (device_live, log_live)

## 4. Capacity Planning

- [x] 4.1 Add percent-of-capacity calculation using `netflow_interface_cache` speeds
- [x] 4.2 Wire bandwidth gauge components for top interfaces
- [x] 4.3 Add subnet/VLAN traffic distribution view (group by local CIDRs)
- [x] 4.4 Add top interfaces table with capacity display
