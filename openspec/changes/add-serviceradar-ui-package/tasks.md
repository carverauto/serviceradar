## 1. Package skeleton

- [x] 1.1 Create `elixir/serviceradar_ui`:
  - Mix project, Apache-2.0 `LICENSE`, `NOTICE`, README and CHANGELOG
  - `package:` metadata with the GitHub source link
  - `BUILD.bazel` (`mix_app`, `HEX_OFFLINE=1`)
- [x] 1.2 Set up the quality gate: format, credo, compile with warnings as errors, and a test matrix covering LiveView 1.1 and 1.2.

## 2. Tokens and theming

- [x] 2.1 Extract the `sr-*` tokens into `priv/css/tokens.css`, using `light-dark()`, `[data-theme]` and a `prefers-color-scheme` fallback.
- [x] 2.2 Extract the generic `sr-ui-*` rules into `priv/css/components.css`.
- [x] 2.3 Add `priv/static/theme_init.js` with the `sr:theme` key and the `data-sr-theme-key` override.

## 3. Components and shell

- [x] 3.1 Add `ServiceRadarUI.Components`:
  - button, icon button
  - badge
  - panel, surface
  - alert, flash
  - modal
  - tabs, dropdown
  - table, pagination
  - spinner
  - field, input
  - icon

  Use `:global` rest attributes and an optional error translator.
- [x] 3.2 Add `ServiceRadarUI.Shell`: skip link, sticky top bar, footer, theme toggle and flash group. Branding and navigation come from slots.
- [x] 3.3 Add `ServiceRadarUI.Charts`: sparkline, area, bar, donut and gauge, as SVG only.
- [x] 3.4 Add a CSP-output test: render every component and chart and reject `style=`, inline `<script>` and `on*=`.

## 4. Hooks

- [x] 4.1 Add hook sources for `SrSparkline` and `SrTimeseries`. Remove the `user_time` coupling by accepting a time-zone and format option.
- [x] 4.2 Add the `SrWorldMap` hook:
  - offline topology, lazy-loaded
  - point, region and arc layers
  - data through `data-*` JSON plus `handleEvent` updates
  - no tile servers
- [x] 4.3 Build the prebuilt ESM bundle and source map. Add a CI drift check and a bundle-size report.
- [x] 4.4 Add a small `example/` Phoenix app, built in CI, that uses every component and hook under a strict CSP.

## 5. web-ng adoption

- [x] 5.1 Add the path dependency, then the CSS imports and hook registration.
- [x] 5.2 Replace the `ui_components.ex` call sites. Allow delegating wrappers for at most one release.
- [x] 5.3 Replace the four sparkline implementations with `ServiceRadarUI.Charts.sparkline/1`.
- [x] 5.4 Remove the duplicated token CSS. Layout tests stay green.

## 6. Release

- [x] 6.1 Add `.github/workflows/serviceradar-ui-publish.yml`, triggered by `serviceradar_ui-v*` tags, cloned from the palisade workflow.
- [ ] 6.2 Get maintainer approval, then publish `0.1.0`.
- [x] 6.3 Document the package in `elixir/README.md`.
