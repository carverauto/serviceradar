# Change: Fix NetFlow LiveView route canonicalization

## Why
Issue #2906 shows NetFlow LiveView sessions crashing with `cannot push_patch/2` because internal patch URLs target `/netflow` while the LiveView root is mounted at `/flows`. This breaks navigation and query updates on the NetFlow visualize page.

## What Changes
- Define `/flows` as the only NetFlow LiveView route.
- Require all NetFlow LiveView-generated URLs (`push_patch`, pagination links, table links, SRQL fallback paths) to stay on `/flows`.
- Remove `/netflow` and `/netflows` routes instead of redirecting.
- Add regression tests covering `/flows` rendering and LiveView patch behavior.

## Impact
- Affected specs: `build-web-ui`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/page_controller.ex`
  - `elixir/web-ng/test/serviceradar_web_ng_web/live/netflow_live/*`
