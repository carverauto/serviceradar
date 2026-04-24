# Change: Dashboard and Sidebar Shell

## Why
Operators need a first-screen dashboard that summarizes network health, traffic posture, vulnerable assets, and security activity without forcing pivots across multiple pages. The current web-ng navigation also needs a reusable sidebar shell so new dashboard and existing app surfaces can share one consistent application frame.

## What Changes
- Add a new web-ng dashboard surface tied to issue #3183 with top KPI cards, a deck.gl/luma topology and traffic map, security event trend chart, FieldSurvey/Wi-Fi heatmap region, camera operations panel, observability metrics, vulnerable asset placeholders, and SIEM alert placeholders.
- Base the dashboard traffic map on observed NetFlow/IPFIX flow summaries and animate MTR-derived diagnostic overlays using the existing topology deck.gl/luma rendering patterns where practical.
- Introduce a reusable authenticated sidebar shell for web-ng routes, including persistent navigation, active state, collapse behavior, and responsive layout behavior.
- Keep vulnerable asset and SIEM alert cards as explicitly bounded UI placeholders in this proposal; real vulnerability tracking and SIEM ingestion/feed behavior will be proposed separately.

## Impact
- Affected specs: `build-web-ui`, `observability-netflow`, `mtr-diagnostics`
- Reference specs: `topology-god-view`, `topology-causal-overlays`, `camera-streaming`, `network-discovery`
- Affected code (expected):
  - `elixir/web-ng/` dashboard LiveView, shared layout/components, route/navigation definitions, deck.gl/luma hooks, tests
  - Existing NetFlow query/service modules used by web-ng for bounded map summaries
  - Existing MTR diagnostic query/service modules used by web-ng for overlay summaries
- Breaking changes: None intended. Existing routes should remain available unless a follow-up proposal explicitly changes route ownership.
