## Context

Akvorado's Visualize page provides multiple chart types with consistent interactions. ServiceRadar uses LiveView and D3 hooks; we need a cohesive chart suite that can be reused and extended.

## Decisions

### Decision: Hook API Uses `data-*` Attributes

Each chart hook reads its dataset from `data-*` attributes on the root element:
- `data-keys` (JSON array)
- `data-points` (JSON array)
- Optional: `data-colors` (JSON map key -> color)

This matches existing NetFlow hooks and avoids a new client-side state system.

### Decision: Theme Awareness

Charts should look acceptable in light/dark themes. The first iteration uses deterministic color palettes and relies on `currentColor` for axes/labels. A follow-up can compute palette from CSS variables.

## Rollout

1. Implement missing chart hooks (stacked100/lines/grid) and refactor existing stacked/sankey to use shared helpers.
2. Wire `/netflow` to render the chart based on `nf` state.
3. Add minimal dataset loaders for charts (SRQL downsample for time-series, SRQL stats for sankey).
