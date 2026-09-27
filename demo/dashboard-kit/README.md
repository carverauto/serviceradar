# Demo dashboard kit

Shared frame + presenter strip for showcase demo dashboards
(`openspec/changes/add-showcase-demo-portfolio`, design D13/D14).

- `presenter.js` — framework-free state: countdown from the simulator's
  `demo.fault.next_at` / `demo.fault.active` metrics (hidden without them, so
  a real `Source` needs no dashboard change), open incidents folded from
  `demo.fault` OCSF events, one trigger per fault kind the plugin's action
  declares (hidden without invoke permission). Nothing here changes
  dashboard state directly: every button invokes the plugin's fault action
  and the banner follows the resulting events.
- `kit.js` — `createDemoKit({React, sdk})` factory: `DemoFrame` (incident
  banner, chip/KPI header, 7/12 visual + 5/12 detail split, active SRQL
  chips), `PresenterStrip`, `useFaultIncidents` (subscribes with
  `useDashboardEvents`, refreshes frames on every fault event). Pass the
  dashboard's own React and `@carverauto/serviceradar-dashboard-sdk/live`.
- `fixtures/` — harness object-form fixtures (`frames`, `actions`,
  `events`): `presenter-steady.json` and `presenter-fault.json`, plus the
  `resolve.js` fixture resolver that maps scenario chips to fixtures.
- `dashboard.config.mjs` + `src/main.jsx` + `package.json` — runnable
  offline example: `npm install` then `npm run dev`, no live ServiceRadar.
  Two prerequisites, both temporary while the branch stack lands:
  `serviceradar-cli` on `PATH` must be built from this branch (only it
  accepts `fixtureResolver`), and the SDK must export the `live` subpath
  (`useDashboardActions`, `useDashboardEvents`, `useFrameRefresh`) — until
  that is released, `npm install <path-to-serviceradar-sdk-dashboard>`
  from the `feat/plan-view` checkout.

## Tests

- `bazel test //demo/dashboard-kit:kit_tests` (local: shells to host npm
  for `react`/`react-dom`, like `//js/cli:ci`) — presenter unit tests,
  fixture round-trip (steady stays quiet, mid-fault shows the incident,
  resolving clears it, invocation emits reopen it), and component renders
  (countdown hidden without metrics, buttons hidden without permission).
  Plain `node --test presenter.test.mjs fixtures.test.mjs kit.test.mjs`
  after `npm install` runs the same suites.
- `cd js/cli && npm run build && node --test tests/cli.test.mjs` — covers
  the `fixtureResolver` schema acceptance `validate` enforces.
- `cd demo/pluginkit && go test ./...` — covers the metadata mirroring the
  strip reads (live event summaries carry metadata, not unmapped fields).
