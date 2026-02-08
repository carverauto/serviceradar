## Program Tasks (This Change)

This is an umbrella change that defines the target parity end-state and the delivery plan. Implementation work MUST happen in smaller child changes. These tasks track the program plan and the creation/maintenance of the child changes.

## 1. Align On Scope And Slices
- [x] 1.1 Confirm SRQL-only constraint for charts/widgets (no Ecto chart queries)
- [x] 1.2 Confirm we are not introducing an akvorado-like filter language (SRQL only)
- [x] 1.3 Confirm which URL state parameter to use for Visualize (example: `nf=v1-...`)
- [ ] 1.4 Identify must-have parity items for v1 (Visualize page + 5 charts + dimensions + bidirectional + previous period)
- [ ] 1.5 Identify deferred items (OTX, dictionaries, SNI classification, per-user dashboards) and mark as Phase F/G

## 2. Child Change Breakdown (Create And Keep In Sync)
- [x] 2.1 Create child change: `add-netflow-visualize-page` (route + state model + redirect)
- [x] 2.2 Create child change: `add-netflow-d3-chart-suite` (shared D3 toolkit + missing chart types)
- [x] 2.3 Create child change: `add-netflow-dimensions-and-ranking` (dimensions UI + IP truncation + limitType)
- [ ] 2.4 Create child change: `add-netflow-interface-exporter-cache` (cache table + worker + SRQL dims)
- [ ] 2.5 Create child change: `add-netflow-units-and-capacity` (units + pct-of-capacity)
- [ ] 2.6 Create child change: `add-netflow-caggs-auto-resolution` (CAGGs + SRQL auto-resolution)
- [ ] 2.7 Create child change: `add-netflow-app-ip-ranges` (ip range DB + importer + SRQL tiering)
- [ ] 2.8 Create child change: `add-netflow-network-dictionaries` (dictionaries + SRQL `net:<dict>:<attr>`)
- [ ] 2.9 Create child change: `add-netflow-otx-feed` (OTX provider + settings)
- [ ] 2.10 Create child change: `add-netflow-dashboard-home` (dashboard widgets + persistence)
- [x] 2.11 Create child change: `add-netflow-overlays` (bidirectional + previous period overlays on Visualize)

## 3. Acceptance Criteria Per Phase (Program-Level)
- [x] 3.1 Phase A acceptance: `/netflow` exists with left panel options and shareable URL state; old netflows tab redirects preserving SRQL query
- [ ] 3.2 Phase B acceptance: 5 chart types exist and share consistent interactivity patterns (legend toggle, tooltip, responsive)
- [ ] 3.3 Phase B acceptance: bidirectional and previous-period overlays work on supported chart types
- [ ] 3.4 Phase C acceptance: dimension selector supports multi-dim ordering, top-N, limitType, and IP truncation for IP dims
- [ ] 3.5 Phase D acceptance: interface/exporter metadata appears in SRQL and UI (names, speeds, boundaries)
- [ ] 3.6 Phase E acceptance: long windows auto-use rollups; performance validated with EXPLAIN and demo data
- [ ] 3.7 Phase F acceptance: app IP ranges, dictionaries, and OTX are configurable and visible in SRQL/UI
- [ ] 3.8 Phase G acceptance: dashboard homepage widgets exist and persist per user

## 4. Ongoing Program Hygiene
- [ ] 4.1 Keep `proposal.md` and `design.md` updated as phases are completed
- [ ] 4.2 Keep spec deltas accurate, but ensure each child change owns the implementation tasks
- [ ] 4.3 Ensure each child change runs its own validation (`openspec validate <id> --strict`)
