# Change: Add NetFlow Visualize Page (SRQL-Driven)

## Why

NetFlow analytics is currently embedded inside the `/observability` LiveView as a tab and is hard to evolve into a full-featured analytics UI (left options panel, multiple chart types, dimensions, shareable state). Akvorado's "Visualize" page is the benchmark layout we want to reach.

We need an operator-friendly, dedicated NetFlow page that can iterate independently while keeping a single query language (SRQL) and our existing data model.

## What Changes

- Add a dedicated **`/netflow`** route in `web-ng` with a two-panel layout:
  - Left: visualize options (time range, dimensions, units, graph type, toggles)
  - Right: visualization surface + data table placeholder (SRQL-driven)
- Add **shareable URL state** for visualize options using a versioned, compressed payload.
- Add **legacy redirects** so bookmarks keep working:
  - `/observability?...tab=netflows...` redirects to `/netflow` and preserves SRQL query parameters
  - `/netflows` redirects to `/netflow` (or becomes an alias)

## Constraints

- All NetFlow charts/widgets MUST be driven by SRQL queries (no Ecto queries for chart data).
- Database schema changes are out of scope for this change (no new tables/migrations here).
- Do not introduce an Akvorado-like SQL filter language. SRQL remains the only query language.

## Impact

- Affected specs:
  - `build-web-ui`
  - `srql`
- Affected code:
  - `elixir/web-ng/` new LiveView route/module, URL state codec, and UI scaffolding

## Non-Goals

- Implementing the full D3 chart suite (stacked100/lines/grid/brush/bidirectional/previous-period).
- Interface/exporter enrichment, IP-range classification, dictionaries, OTX.
- Multi-resolution rollups and SRQL auto-resolution.
