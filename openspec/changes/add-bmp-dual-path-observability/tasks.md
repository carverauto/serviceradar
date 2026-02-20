## 1. Data Path Semantics
- [ ] 1.1 Ensure BMP raw routing messages are always persisted to `platform.bmp_routing_events`.
- [ ] 1.2 Ensure BMP-to-OCSF writes are limited to promoted/high-signal events.
- [ ] 1.3 Add tests that verify route-update firehose messages do not flood `platform.ocsf_events`.

## 2. SRQL Support
- [x] 2.1 Add SRQL parser support for `in:bmp_events`.
- [x] 2.2 Implement SRQL query execution for `bmp_events` with filters for time, event_type, severity, router_ip, peer_ip, and prefix.
- [x] 2.3 Add SRQL viz/catalog metadata for `bmp_events`.
- [x] 2.4 Add SRQL tests for filter behavior, ordering, and pagination.

## 3. Database Query Performance
- [x] 3.1 Add or validate indexes on `platform.bmp_routing_events` for investigative filter patterns.
- [ ] 3.2 Verify retention policy and query plans remain acceptable for expected BMP volume.

## 4. UI: Observability BMP
- [x] 4.1 Add a BMP observability page/route in web-ng using SRQL (`in:bmp_events`).
- [x] 4.2 Implement routing-centric table fields and filters with drill-through to related events where available.
- [x] 4.3 Add summary counters for recent BMP activity (e.g., route updates/withdraws, peer transitions).

## 5. Correlation and Validation
- [ ] 5.1 Verify raw BMP rows and promoted OCSF rows preserve stable correlation identifiers/topology keys.
- [ ] 5.2 Validate end-to-end flow in `demo` with active GoBGP feed (raw BMP present, curated OCSF present, no OCSF flood).
- [ ] 5.3 Run `openspec validate add-bmp-dual-path-observability --strict`.
