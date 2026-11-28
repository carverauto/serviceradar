# Changelog

## 0.2.0

- Ship canonical `logo-animated.svg` and `favicon.ico` in `priv/static/` so
  every ServiceRadar property renders the same brand mark from one package.
- Add `ServiceRadarUI.Shell.brand_lockup/1` and `ServiceRadarUI.Shell.segmented_nav/1`.
- Upgrade `ServiceRadarUI.Shell.top_bar/1` and `footer/1` with standard `1280px`
  contained layout (`contained={true}` default), pill navigation targets, and an
  optional `:mobile_nav` slot on `top_bar/1`.
- Add atmospheric surface utilities `.sr-ui-hero-glow`, `.sr-ui-dot-grid`, and
  `.sr-ui-card-interactive` in `priv/css/components.css`.

## 0.1.0

Unreleased. This version is not published to hex.pm.

Initial package:

- `sr-*` design tokens with `light-dark()`, `[data-theme]` and a
  `prefers-color-scheme` fallback, plus generic `sr-ui-*` component CSS.
- `ServiceRadarUI.Components`, `ServiceRadarUI.Shell`,
  `ServiceRadarUI.Charts` and `ServiceRadarUI.Maps`.
- Prebuilt LiveView hooks `SrSparkline`, `SrTimeseries`, `SrWorldMap`
  and `SrDialog` in `priv/static/serviceradar_ui.js`.
- Offline Natural Earth topology at `priv/static/world-110m.json`.
- Theme bootstrap script `priv/static/theme_init.js` (`sr:theme`,
  overridable with `data-sr-theme-key`).
