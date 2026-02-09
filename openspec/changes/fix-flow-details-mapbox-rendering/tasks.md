## 1. Diagnose Root Cause
- [x] 1.1 Inspect browser DevTools console and network tab to confirm whether Mapbox tile requests are made and whether they return errors (401, 403, CORS, etc.).
- [x] 1.2 Verify MapboxSettings in database — confirm `enabled` is true and `access_token` is present and decryptable.
- [x] 1.3 Confirm the style URLs (`data-style-light`, `data-style-dark`) resolve correctly with the configured token.

## 2. Hook Error Handling
- [x] 2.1 Add a `map.on("error", ...)` handler that logs the error and renders a user-visible fallback inside the container.
- [x] 2.2 Guard `_initOrUpdate()` — if token is empty or `enabled` is false, render a "Map not configured" placeholder instead of silently returning.
- [x] 2.3 Add `console.warn` breadcrumbs at key points (token read, style selection, map creation) to aid future debugging.

## 3. Container & CSS Fixes
- [x] 3.1 Verify the map container has computed width > 0 and height > 0 at mount time; add explicit `min-height` / `min-width` styles if Tailwind classes are not sufficient.
- [x] 3.2 Confirm `mapbox-gl.css` import order does not conflict with daisyUI/Tailwind resets; isolate with scoped styles if necessary.
- [x] 3.3 Call `map.resize()` after the container becomes visible (LiveView may mount the element before it is in the DOM flow).

## 4. Validation
- [ ] 4.1 Manually verify basemap renders in both light and dark themes with a valid token.
- [ ] 4.2 Verify fallback message appears when token is missing or invalid.
- [x] 4.3 Run `openspec validate fix-flow-details-mapbox-rendering --strict`.
