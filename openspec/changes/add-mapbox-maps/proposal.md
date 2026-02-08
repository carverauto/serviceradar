# Change: Add Mapbox Maps To Web-NG (Reusable LiveView Component + Settings)

## Why
NetFlow (and other parts of the UI) would benefit from a geographic visualization that is more intuitive than country buckets alone. A small embedded map in the flow details view provides immediate context (origin/destination, approximate location) without leaving the dashboard.

## What Changes
- Add a reusable Mapbox LiveView component (JS hook + HEEx component) that can render point markers given lat/lon.
- Add deployment-level settings to store a Mapbox access token (encrypted at rest) with admin UI + RBAC.
- Embed the Mapbox component in NetFlow flow details (below the Traffic section) when GeoIP coordinates are available.
- Ensure the map style follows light/dark mode.

## Non-Goals
- Full GIS features (routing, polygons, heatmaps) beyond simple point markers.
- Query-time external lookups; all coordinates come from existing GeoIP enrichment caches.

## Impact
- Affected specs: new `ui-maps` capability; existing `observability-netflow` UI.
- Affected code:
  - `web-ng/assets` JS bundle (Mapbox GL integration).
  - `web-ng/` LiveView components + settings UI.
  - `elixir/serviceradar_core` settings resource + migration for encrypted token.

## Risks / Considerations
- Token handling: Mapbox token must be encrypted at rest and never rendered back to the UI.
- CSP and asset size: Mapbox GL adds bundle weight; keep usage scoped and lazy-init via LiveView hook.
- Network policy: Mapbox tiles are fetched client-side by browsers (not pod egress), but deployments may have restrictive CSP; we should document required domains.
