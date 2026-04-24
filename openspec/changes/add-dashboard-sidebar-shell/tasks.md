## 1. Approval
- [ ] 1.1 Review and approve this OpenSpec proposal before implementation starts.
- [ ] 1.2 Confirm the initial dashboard route and whether it becomes the authenticated landing page.

## 2. Sidebar Shell
- [ ] 2.1 Audit current web-ng layouts, route navigation, and existing sidebar/header components.
- [ ] 2.2 Implement a reusable authenticated sidebar shell with active route state, collapse behavior, account controls, and responsive mobile behavior.
- [ ] 2.3 Migrate the new dashboard route into the shell without disrupting existing route entry points.
- [ ] 2.4 Add component/layout tests for active navigation state and responsive shell rendering.

## 3. Dashboard Surface
- [ ] 3.1 Build the dashboard LiveView route and layout with top KPI cards, map region, security event trend chart, FieldSurvey/Wi-Fi heatmap region, camera operations panel, observability metrics, vulnerable asset cards, and SIEM alert feed placeholders.
- [ ] 3.2 Wire KPI and posture cards to existing health, inventory, and NetFlow summary data where already available.
- [ ] 3.3 Render vulnerable asset and SIEM cards as explicit unconnected/empty states until follow-up proposals define real feeds.
- [ ] 3.4 Add LiveView tests for default loading, authorization, and missing-feed states.
- [ ] 3.5 Add read-only camera fleet and Wi-Fi/FieldSurvey summary panels using existing data where available and explicit empty states otherwise.

## 4. Network Traffic Map
- [ ] 4.1 Identify reusable deck.gl/luma hooks, layer helpers, and visual conventions from the existing topology view.
- [ ] 4.2 Add bounded NetFlow summary query/service support for map links/arcs over the selected time window.
- [ ] 4.3 Implement the dashboard map with observed-flow animation, empty states, and no synthetic traffic fallback.
- [ ] 4.4 Add read-only MTR overlay animation driven by existing diagnostic summaries.
- [ ] 4.5 Add browser/screenshot checks for desktop and mobile viewports, including nonblank canvas verification.

## 5. Validation
- [ ] 5.1 Run `openspec validate add-dashboard-sidebar-shell --strict`.
- [ ] 5.2 Run the applicable web-ng quality command: `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix`.
- [ ] 5.3 Document follow-up OpenSpec proposals for vulnerable asset tracking and SIEM alert feed ingestion.
