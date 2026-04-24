## 1. Approval
- [x] 1.1 Review and approve this OpenSpec proposal before implementation starts.
- [x] 1.2 Confirm the initial dashboard route and whether it becomes the authenticated landing page.

## 2. Sidebar Shell
- [x] 2.1 Audit current web-ng layouts, route navigation, and existing sidebar/header components.
- [x] 2.2 Implement a reusable authenticated sidebar shell with active route state, collapse behavior, account controls, and responsive mobile behavior.
- [x] 2.3 Migrate the new dashboard route into the shell without disrupting existing route entry points.
- [x] 2.4 Add component/layout tests for active navigation state and responsive shell rendering.
- [x] 2.5 Propagate the shared operations shell to primary authenticated app routes and preserve SRQL controls inside that shell.

## 3. Dashboard Surface
- [x] 3.1 Build the dashboard LiveView route and layout with top KPI cards, map region, security event trend chart, FieldSurvey/Wi-Fi heatmap region, camera operations panel, observability metrics, vulnerable asset cards, and SIEM alert feed placeholders.
- [x] 3.2 Wire KPI and posture cards to existing health, inventory, and NetFlow summary data where already available.
- [x] 3.3 Render vulnerable asset and SIEM cards as explicit unconnected/empty states until follow-up proposals define real feeds.
- [x] 3.4 Add LiveView tests for default loading, authorization, and missing-feed states.
- [x] 3.5 Add read-only camera fleet and Wi-Fi/FieldSurvey summary panels using existing data where available and explicit empty states otherwise.
- [x] 3.6 Start bounded relay-backed camera previews from relay-capable camera inventory when the connected dashboard loads.
- [x] 3.7 Rename the event trend panel to "Events Over Time" and render trend data as a stacked area visualization rather than bars.
- [x] 3.8 Make dashboard event, alert, and camera widgets navigate to detail pages.

## 3A. Camera Operations
- [x] 3A.1 Add a camera-first `/cameras` route under the authenticated LiveView session.
- [x] 3A.2 Build a camera multiview layout with 2/4/8/16/32 viewport controls.
- [x] 3A.3 Use existing camera inventory and relay session plumbing to open live streams where available.
- [x] 3A.4 Keep observability camera relay diagnostics routes available but remove them as the primary Cameras sidebar target.
- [x] 3A.5 Add camera detail routes under `/cameras/:camera_source_id` that open the selected camera feed.

## 4. Network Traffic Map
- [x] 4.1 Identify reusable deck.gl/luma hooks, layer helpers, and visual conventions from the existing topology view.
- [x] 4.2 Add bounded NetFlow summary query/service support for map links/arcs over the selected time window.
- [x] 4.3 Implement the dashboard map with observed-flow animation, empty states, and no synthetic traffic fallback.
- [x] 4.4 Add read-only MTR overlay animation driven by existing diagnostic summaries.
- [x] 4.6 Use topology edge interface telemetry, including SNMP-derived rate/capacity fields already present in the runtime graph, for dashboard map edge animation and hover details.
- [x] 4.7 Add bounded dashboard topology edge hover sparklines from existing SNMP interface timeseries.
- [x] 4.8 Extend GodView node or edge inspectors with compact interface metric sparklines when historical SNMP timeseries is available.
- [x] 4.9 Add a visible world-map backdrop and richer NetFlow hover details using available GeoIP/IP enrichment while still displaying observed non-enriched flows.
- [x] 4.5 Add browser/screenshot checks for desktop and mobile viewports, including nonblank canvas verification.

## 5. Validation
- [x] 5.1 Run `openspec validate add-dashboard-sidebar-shell --strict`.
- [ ] 5.2 Run the applicable web-ng quality command: `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix`.
- [x] 5.3 Document follow-up OpenSpec proposals for vulnerable asset tracking and SIEM alert feed ingestion.
