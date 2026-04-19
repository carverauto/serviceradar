## Context
The current observability UI mixes two navigation models:
- `LogLive.Index` owns logs, traces, metrics, events, alerts, and a flows tab under `/observability?tab=...`
- BMP, BGP Routing, Camera Relays, and Camera Analysis Workers mount separate LiveViews under `/observability/*` and render their own top-level shells

That split creates visible shell changes when operators move across signal surfaces. Camera Analysis Workers is also conceptually a child of Camera Relays, but the current route layout makes it behave like a separate page.

## Goals / Non-Goals
- Goals:
- Keep one consistent top-level observability shell across all observability panes
- Preserve direct links into flows, BMP, BGP Routing, Camera Relays, and camera worker operations without dropping the shared shell
- Present Camera Analysis Workers as a subsection within Camera Relays
- Non-Goals:
- Redesign the underlying data views for flows, BMP, BGP Routing, or camera operations
- Change observability authorization semantics
- Merge all observability panes into one LiveView if that is not required for shell consistency

## Decisions
- Decision: standardize the shell at the UI-component level rather than forcing every pane into the same LiveView
- Alternatives considered: consolidating every pane into `LogLive.Index`; rejected because that is a larger refactor than the navigation problem requires

- Decision: flows remains a top-level observability pane but no longer hides the shared shell when active
- Alternatives considered: leaving flows visually distinct because it is more dashboard-like; rejected because the user expectation is consistent observability navigation

- Decision: Camera Analysis Workers becomes a Camera Relays subsection with direct-linkable subsection state
- Alternatives considered: keeping a separate `/observability/camera-analysis-workers` top-level destination; rejected because it creates a hidden extra tab and breaks the mental model of Camera Relays as one top-level pane

## Risks / Trade-offs
- Shared shell extraction can create duplicated active-tab state unless one source of truth is used consistently across route-backed and query-param-backed panes
- Camera worker route migration needs a compatibility path so old deep links do not fail abruptly

## Migration Plan
1. Introduce a shared observability shell wrapper/component with explicit active-pane and optional subsection state
2. Adopt that shell in flows, BMP, BGP Routing, and Camera Relays
3. Fold Camera Analysis Workers into Camera Relays subsection routing
4. Redirect or alias the legacy worker route to the Camera Relays subsection entry point

## Open Questions
- Whether the direct-link shape for camera worker management should be a query param on `/observability/camera-relays` or a nested sub-route under that path
