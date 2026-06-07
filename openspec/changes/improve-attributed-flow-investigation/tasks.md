## 1. Data Contract

- [x] 1.1 Identify the existing attributed-flow query/API and flow-details route or component contract.
- [x] 1.2 Extend the attributed-flow result shape with stable flow identity, collecting agent, attribution status, CTI/OTX summary, reverse-DNS names, and human-readable byte formatting inputs.
- [x] 1.3 Ensure queries support deterministic pagination and filters for `attributed`, `unmatched`, and `all`.
- [x] 1.4 Reuse existing reverse-DNS and CTI lookup code where available; add shared helpers only if current code is duplicated or route-specific.

## 2. Attributed Flows Page

- [x] 2.1 Change the topbar title from generic ServiceRadar branding to "Attributed Flows" for this route.
- [x] 2.2 Default the table to attributed rows and expose unmatched/all through explicit stat-card or control filters.
- [x] 2.3 Add logs-style live mode with an on/off toggle; when off, preserve the current page and filters without auto-prepending rows.
- [x] 2.4 Add pagination controls with stable ordering and no horizontal overflow at common desktop widths.
- [x] 2.5 Make stat cards clickable filters and visually indicate the active filter.
- [x] 2.6 Make each row open NetFlow flow details via navigation or a modal without losing filter/page context.
- [x] 2.7 Compact the table: show endpoints with optional rDNS, process/agent summary, human-readable bytes/packets, protocol, attribution status, CTI indicator, and timestamp.
- [x] 2.8 Show reverse-DNS hostnames in attributed flow detail surfaces by reusing the existing `ip_rdns_cache` enrichment path.
- [x] 2.9 Keep summary cards SRQL-backed while reducing load by using one grouped attribution-status aggregate and attributed-flow partial indexes.

## 3. NetFlow Map Integration

- [x] 3.1 Add attribution state to NetFlow map path data.
- [x] 3.2 Render an operator-visible attribution cue on paths or tooltips when a flow maps to a known process.
- [x] 3.3 Allow map drill-down to open the same flow details used by the attributed flows table.
- [x] 3.4 Surface CTI/OTX hits alongside attribution state without obscuring normal traffic.

## 4. Verification

- [x] 4.1 Add focused tests for pagination/filter query behavior.
- [ ] 4.2 Add LiveView/browser coverage for live toggle, stat-card filters, row details, and no horizontal overflow.
  - [x] LiveView coverage for live toggle, stat-card filters, row details, pagination, protocol/rDNS/IOC rendering, and compact non-table rows.
  - [ ] Browser/screenshot coverage for horizontal overflow at common desktop widths.
- [ ] 4.3 Verify with demo data that attributed, unmatched, TCP, UDP, and CTI-marked rows render correctly.
  - [x] Demo DB has attributed and unmatched rows in the attributed-flow dataset.
  - [x] Demo DB has TCP, UDP, and ICMP attributed-flow rows.
  - [ ] Demo DB has CTI-marked rows that overlap current attributed-flow source/destination IPs.
- [x] 4.4 Run `openspec validate improve-attributed-flow-investigation --strict`.
- [ ] 4.5 Evaluate a dedicated Timescale continuous aggregate for attributed-flow status/byte summaries before enabling longer default windows or SaaS-scale retention.
- [ ] 4.6 Refactor `elixir/web-ng/lib/serviceradar_web_ng_web/live/log_live/index.ex` into smaller LiveView/data/component modules once the attributed-flow and NetFlow UI work stabilizes.
- [x] 4.7 Refactor `elixir/serviceradar_core/lib/serviceradar/flow_attribution.ex` into smaller persistence, correlation, retention, and event-normalization modules.
- [ ] 4.8 Refactor `elixir/web-ng/assets/js/hooks/OperationsTrafficMap.js` into smaller map geometry, tooltip, URL, and hook lifecycle modules.
- [ ] 4.9 Refactor `elixir/web-ng/lib/serviceradar_web_ng_web/live/flows/attributed_live.ex` into smaller query, state, component, and event-handler modules.
- [ ] 4.10 Refactor `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index.ex` into smaller data-loading, form-state, event-handler, and component modules.
- [ ] 4.11 Add first-class workload `context_name` support, make it the canonical user-facing workload context in attributed-flow/workload identity displays, stop surfacing `cluster_name`/`cluster_id` in workload identity paths, and keep namespace/pod as the locator under that context.
