# Change: Add NetFlow D3 Chart Suite (Visualize Parity)

## Why

The new `/netflow` Visualize page needs a consistent, reusable D3 chart toolkit to reach Akvorado-style parity: stacked area, 100% stacked, lines, grid, and sankey, with shared interaction patterns (tooltips, legends, responsive sizing).

We already have some NetFlow chart hooks in `elixir/web-ng/assets/js/app.js`, but they are ad-hoc and not wired into a dedicated chart suite with a coherent API.

## What Changes

- Introduce a small shared D3 chart utility layer for NetFlow charts (palette/theme awareness, sizing, axes helpers).
- Implement/standardize the 5 chart types as Phoenix LiveView hooks:
  - stacked area
  - 100% stacked area
  - line series
  - grid (small multiples)
  - sankey (upgrade existing)
- Wire the `/netflow` Visualize page to render the selected chart type using SRQL-driven datasets.

## Constraints

- Charts MUST be driven by SRQL query results (no Ecto chart queries).
- Keep D3 as the charting library (avoid introducing ECharts/Chart.js).

## Impact

- Affected specs: `build-web-ui`
- Affected code:
  - `elixir/web-ng/assets/js/app.js` (hooks)
  - `elixir/web-ng/lib/**/netflow_live/visualize.ex` (chart selection + dataset loads)

## Non-Goals

- Dimension selector UI (drag/drop, limitType, IP truncation) is handled in a separate change.
- Bidirectional axes, previous-period overlays, and brush-to-zoom can be stubbed (follow-up) if they risk scope creep.
