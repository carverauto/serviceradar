# Change: Dashboard and Sidebar Shell

## Why
Operators need a first-screen dashboard that summarizes network health, traffic posture, vulnerable assets, and security activity without forcing pivots across multiple pages. The current web-ng navigation also needs a reusable sidebar shell so new dashboard and existing app surfaces can share one consistent application frame.

## What Changes
- Add a new web-ng dashboard surface tied to issue #3183 with top KPI cards, a deck.gl/luma topology and traffic map, security event trend chart, FieldSurvey/Wi-Fi heatmap region, camera operations panel, observability metrics, vulnerable asset placeholders, and SIEM alert placeholders.
- Base the dashboard traffic map on observed NetFlow/IPFIX flow summaries and animate MTR-derived diagnostic overlays using the existing topology deck.gl/luma rendering patterns where practical.
- Compose dashboard panels from collector/package, database, service-check, and plugin signals so optional capabilities render as active, configured-without-data, or not-configured instead of broken blank widgets.
- Define the collector liveness direction: edge agents check reachable collectors over mTLS-capable paths and publish bounded heartbeat/status events through NATS JetStream/KV for core/web-ng to materialize, avoiding direct core polling of edge-local collector endpoints.
- Introduce a reusable authenticated sidebar shell for web-ng routes, including persistent navigation, active state, collapse behavior, and responsive layout behavior.
- Promote the shared sidebar shell across primary authenticated app routes and route the Cameras navigation item to a camera-first multiview surface instead of relay diagnostics.
- Start relay-backed camera previews from available camera inventory on dashboard and camera multiview load, while preserving explicit unavailable states when no relay-capable source is available.
- Keep vulnerable asset and SIEM alert cards as explicitly bounded UI placeholders in this proposal; real vulnerability tracking and SIEM ingestion/feed behavior will be proposed separately.

## Impact
- Affected specs: `build-web-ui`, `observability-netflow`, `mtr-diagnostics`, `agent-connectivity`
- Reference specs: `topology-god-view`, `topology-causal-overlays`, `camera-streaming`, `network-discovery`
- Affected code (expected):
  - `elixir/web-ng/` dashboard LiveView, shared layout/components, route/navigation definitions, deck.gl/luma hooks, tests
  - Existing NetFlow query/service modules used by web-ng for bounded map summaries
  - Existing MTR diagnostic query/service modules used by web-ng for overlay summaries
  - Collector package/service status signals used by web-ng for adaptive dashboard composition
  - Follow-on agent/NATS collector liveness plumbing for collector heartbeat materialization
- Breaking changes: None intended. Existing routes should remain available unless a follow-up proposal explicitly changes route ownership.
