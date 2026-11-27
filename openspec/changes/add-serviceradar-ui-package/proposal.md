# Change: Add the `serviceradar_ui` package: shared Phoenix design system, components, charts and maps

## Why

ServiceRadar's Phoenix web surfaces share one visual language: the `sr-*` semantic tokens, brand green, Avenir Next, and `light-dark()` theming (see `align-web-ng-with-marketing-design-system`). It is shared by copying. Each application:

- carries its own copy of the token CSS
- has its own diverged `core_components.ex`
- re-implements the same primitives (buttons, surfaces, badges) under different names

`web-ng` alone has four separate server-side SVG sparkline implementations:

- `live/dashboard_live/index/common.ex`
- `live/device_live/index_view/sparkline.ex`
- `components/flow_stat_components.ex`
- `components/srql_components.ex`

Every new Phoenix site starts by copying again, and the copies drift.

`palisade` (`elixir/palisade`, Apache-2.0, published on hex.pm) already shows how to publish shared Elixir building blocks from this repository. This change adds a second public package for the UI layer.

## What Changes

- Add `elixir/serviceradar_ui`, an Apache-2.0 hex package with namespace `ServiceRadarUI`:
  - **Design tokens and theming.**
    - `priv/css/tokens.css`: the `sr-*` color, radius, shadow, z-index and font tokens in a Tailwind v4 `@theme` block, with light and dark values through `light-dark()` and `[data-theme]`.
    - `priv/css/components.css`: `sr-ui-*` component rules.
    - `priv/static/theme_init.js`: an external theme bootstrap, so no inline script is needed.
  - **Function components** (`ServiceRadarUI.Components`):
    - button and icon button
    - badge
    - panel and surface
    - alert and flash
    - modal
    - tabs
    - dropdown
    - table
    - pagination
    - spinner
    - form field and input
    - icon

    These are derived from `web-ng`'s `ui_components.ex` and its generic `core_components.ex` parts. App-specific `phx-value-*` lists become `:global` attribute defaults, and the Gettext coupling becomes an optional error-translator callback.
  - **Shell pieces** (`ServiceRadarUI.Shell`):
    - skip link
    - sticky top bar
    - footer
    - theme toggle
    - flash group

    Branding and navigation are passed in as slots.
  - **Server-rendered SVG charts** (`ServiceRadarUI.Charts`): sparkline, area, bar, donut and gauge. They are pure HEEx with no JavaScript, and they are styled with classes and SVG attributes only, so they work under a `style-src 'self'` policy.
  - **LiveView hooks** (`priv/static/serviceradar_ui.js`, a prebuilt ES module with a source map):
    - `SrSparkline` and `SrTimeseries`, generalized from `FlowSparkline.js`, `TimeseriesChart.js` and `utils/chart_*`.
    - `SrWorldMap`: an offline world map with points, regions and arcs, generalized from the projection layer of `OperationsTrafficMap.js` (d3-geo plus bundled world-atlas topology). It uses no tile servers and no tokens.
- **Compatibility.** Phoenix `~> 1.8` and LiveView `~> 1.1` (1.1 and 1.2 both pass in CI), Elixir `~> 1.15`.
- **CSP safety.** No component or hook emits inline `style` attributes or inline scripts, and the package needs no third-party origins. Tests enforce this.
- **web-ng adopts the package** by path dependency under Bazel. Its duplicated tokens, primitives and sparklines are removed. This sequences with the remaining phases of `align-web-ng-with-marketing-design-system`.
- **Publishing.** A `serviceradar_ui-vX.Y.Z` tag workflow, cloned from `palisade-publish.yml`, publishes to hex.pm after the quality gate. Releases follow semantic versioning from `0.1.0`.

## Non-goals

- Product-specific visuals: God View, NetFlow sankey, stacked and grid charts, BGP views, and dashboard WASM hosting stay in `web-ng`.
- Tile-based maps (Mapbox, CARTO) in the shared package.
- React or recharts components.
- Moving code from repositories outside this one into the package. Consumers elsewhere contribute generic needs upstream as new code here.

## Impact

- Affected specs: `shared-web-ui-package` (new capability).
- Affected code:
  - new `elixir/serviceradar_ui/` (Mix project, `BUILD.bazel`, LICENSE, NOTICE for bundled ISC-licensed d3 and topojson modules and public-domain Natural Earth data)
  - `elixir/web-ng` (dependency, CSS imports, hook registration, removal of duplicates)
  - new `.github/workflows/serviceradar-ui-publish.yml`
  - `elixir/README.md` (first-party package list)
- Related: `align-web-ng-with-marketing-design-system`, `extend-palisade-web-plugs`.
