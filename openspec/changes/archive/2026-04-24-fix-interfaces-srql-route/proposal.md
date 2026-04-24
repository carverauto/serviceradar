# Change: Add /interfaces route for SRQL interface searches

## Why
Users cannot search interfaces via SRQL (e.g., by MAC address) because the `/interfaces` route does not exist in Phoenix. The SRQL catalog defines `interfaces` entity with `route: "/interfaces"`, but the router only has individual interface routes under `/devices/:device_uid/interfaces/:interface_uid`. When users select "Interfaces" in the SRQL query builder and search (e.g., `mac:0c:ea:14:32:d2:80`), the UI navigates to `/interfaces?q=...` and receives a 404.

GitHub Issue: #2441

## What Changes
- Add `/interfaces` LiveView route to Phoenix router
- Create `InterfaceLive.Index` module to display interface search results
- Reuse existing SRQL infrastructure (query builder, pagination, table components)
- Support MAC address filtering via the existing Rust SRQL `mac` field

## Impact
- Affected specs: build-web-ui
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/interface_live/index.ex` (new file)
