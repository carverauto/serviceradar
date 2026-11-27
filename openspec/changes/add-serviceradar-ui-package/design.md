# Design: `serviceradar_ui`

## Context

- **web-ng stack.** Phoenix 1.8.15 and LiveView 1.2.12. Tailwind v4 is built through `@tailwindcss/cli`, and esbuild runs through bun scripts. Under Bazel, assets are built by `//elixir/web-ng/assets` (`aspect_rules_js` with a pnpm lockfile). Heroicons are vendored. daisyUI is removed.
- **Reusable code in web-ng today:**
  - `ui_components.ex` (854 lines). It is coupled only through `CoreComponents.icon/1` and long app-specific `phx-value-*` include lists.
  - The token block in `assets/css/app.css` (about lines 30-150 and 440-540).
  - About 127 `.sr-ui-*` rules.
  - The generic chart hooks `FlowSparkline.js`, `TimeseriesChart.js` and `utils/chart_axis_grid.js` / `utils/chart_hover_geometry.js`. `TimeseriesChart.js` depends on the `user_time` helpers.
  - `OperationsTrafficMap.js`, which uses d3-geo with `world-atlas/countries-110m.json` and no tiles, but is shaped around NetFlow and MTR links.
- **Other consumers.** Other Carver Phoenix applications, outside this repository, run LiveView 1.1 and apply a strict `style-src 'self'` policy. The package has to serve both.
- **Elixir builds.** Elixir projects build with Bazel `mix_app` and `HEX_OFFLINE=1`. Path dependencies inside the repository are the norm (`serviceradar_core`, `serviceradar_srql`).

## Decisions

### D1. One package, with CSS and JavaScript shipped in `priv`

- Consumers import the CSS with:
  - `@import "../../deps/serviceradar_ui/priv/css/tokens.css";`
  - `@import "../../deps/serviceradar_ui/priv/css/components.css";`
- They let Tailwind scan the component classes with `@source "../../deps/serviceradar_ui/lib";`.
- Consumers import JavaScript from the prebuilt `priv/static/serviceradar_ui.js` (ESM) and register its hooks.
- Consumers do not need npm installs for the package's JavaScript dependencies. This mirrors how `phoenix_live_view` ships its client.

A separate npm package was rejected: it would add a second registry and a second release flow, and Phoenix apps already resolve `deps/` paths.

### D2. Prebuilt hooks bundle

- `assets/` inside the package holds the hook sources.
- Package CI runs esbuild and bun to produce `priv/static/serviceradar_ui.js` and its source map. A CI check fails when the committed bundle differs from a fresh build.
- Bundled dependencies, with licenses recorded in `NOTICE`:
  - `d3-geo`, `d3-scale`, `d3-shape`, `d3-array` (ISC)
  - `topojson-client` (ISC)
  - `world-atlas` 110m (ISC; Natural Earth, public domain)
- Bundle size is reported in CI. The world topology is lazy-loaded from `priv/static/world-110m.json` and is not inlined.

### D3. Components

- Attribute and slot APIs follow Phoenix 1.8 generator conventions. Classes merge through a `class` attribute, and `rest` is `:global` with no app-specific `phx-value-*` lists.
- `icon/1` renders Heroicons through the `hero-*` class convention. Consumers keep the Heroicons Tailwind plugin, and the README documents it.
- Error translation goes through a configurable `{module, function}`. With no translator configured, messages are interpolated without Gettext.
- LiveView 1.1 and 1.2 are both supported. Features newer than 1.1, such as colocated hooks, are not used. CI runs the test matrix on both versions.

### D4. CSP-safe output

- No component renders `style=`, inline `<script>` or `on*=` attributes.
- Charts size themselves through SVG `viewBox`, `width` and `height` attributes, and are styled with classes.
- Hooks set layout through attributes or CSSOM on elements they own. CSSOM changes are not restricted by `style-src`.
- A test renders every component and chart with representative assigns and fails if prohibited output appears.

### D5. Theming

- `tokens.css` is the single source for `sr-*` values.
- Light and dark values use `light-dark()`, with explicit `[data-theme="light"|"dark"]` overrides and a `prefers-color-scheme` fallback.
- `theme_init.js` reads the theme preference from `localStorage` under one documented key, `sr:theme`. Consumers that use a legacy key can pass a `data-sr-theme-key` attribute.

### D6. Adoption in web-ng

1. Add the path dependency, then import the CSS and hooks.
2. Replace `ui_components.ex` call sites module by module. Delegating wrappers are allowed only for one release, and are then removed.
3. Replace the four sparkline copies with `ServiceRadarUI.Charts.sparkline/1`.
4. Remove the duplicated token CSS from `app.css`.

Each step keeps the existing layout tests green.

### D7. Release

- `serviceradar-ui-publish.yml` is triggered by `serviceradar_ui-v*` tags. It runs format, credo, the LiveView 1.1 and 1.2 test matrix, and the bundle-drift check, then runs `mix hex.publish --yes` with the `HEX_API_KEY` secret.
- Versions follow 0.x semantic versioning, with a CHANGELOG.
- The first publish needs maintainer approval, because hex package names are permanent.

## Risks

- **Divergence during migration.** web-ng carries both old and new primitives for a while. This is mitigated by the one-release limit on wrappers.
- **Bundle size.** The world map adds d3-geo and the topology. This is mitigated by lazy-loading the topology and keeping the map hook in its own chunk.
- **Unexpected consumer CSS.** Mitigated by documented import order and a small example app in `example/` that CI builds.

## Open questions

- Should the package also ship a self-hosted, read-only OpenAPI document renderer? Several consumers render OpenAPI documents, and web-ng loads Swagger UI and ReDoc from CDNs today.
