# Changelog

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
