## 1. Root Cause: CSP Blocking Mapbox Tiles
- [x] 1.1 Identify that `img-src 'self' data:` in `router.ex` CSP blocks Mapbox tile images from `api.mapbox.com` / `*.tiles.mapbox.com`.
- [x] 1.2 Add Mapbox domains to `img-src` and add `worker-src blob:` / `script-src blob:` for Mapbox GL v3 web workers.

## 2. Hook Error Handling
- [x] 2.1 Add a `map.on("error", ...)` handler that logs the error and renders a user-visible fallback inside the container.
- [x] 2.2 Guard `_initOrUpdate()` — if token is empty or `enabled` is false, render a "Map not configured" placeholder instead of silently returning.
- [x] 2.3 Add `console.warn` breadcrumbs for token/style errors to aid future debugging.

## 3. Container & CSS Fixes
- [x] 3.1 Add explicit `min-height` and `position: relative` to the map container so dimensions survive Tailwind processing.
- [x] 3.2 Call `map.resize()` on `"load"` event and after LiveView `updated()` callback.

## 4. Validation
- [ ] 4.1 Manually verify basemap renders in both light and dark themes with a valid token.
- [ ] 4.2 Verify fallback message appears when token is missing or invalid.
- [x] 4.3 Run `openspec validate fix-flow-details-mapbox-rendering --strict`.
