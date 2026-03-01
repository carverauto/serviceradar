# Change: Add NetFlow Dimensions And Ranking (Akvorado-Like)

## Why

The `/netflow` Visualize page needs a first-class dimension system to be usable at scale: operators must be able to choose how traffic is grouped (dimensions), control top-N selection, and apply IP truncation so charts remain readable.

Akvorado’s Visualize page supports multi-dimension selection, IP truncation (/24 etc), and ranking modes (`avg|max|last`) when selecting the top-N series. We need the same capabilities while keeping SRQL as the only data source.

## What Changes

- Add Visualize controls for:
  - Dimensions (multi-select + ordering)
  - Top-N limit (1-50)
  - Ranking mode: `avg`, `max`, `last`
  - IP truncation for IP dimensions (v4/v6)
- Update chart dataset construction to:
  - Select top-N series based on ranking mode
  - Bucket remaining series into `Other`
- Extend Sankey query generation to use selected dimensions (best-effort, bounded)

## Constraints

- All datasets MUST be produced by SRQL queries (no Ecto queries for chart data).
- Do not introduce a second query language.

## Impact

- Affected specs: `build-web-ui`, `srql`
- Affected code:
  - `elixir/web-ng/lib/**/live/netflow_live/visualize.ex`
  - `elixir/web-ng/lib/**/netflow_visualize/state.ex`
  - `elixir/web-ng/lib/**/netflow_visualize/query.ex`

## Non-Goals

- Full multi-dimension cartesian product series (time-series with 2+ dimensions) in v1.
  - Initial implementation will use a single series dimension for time-series charts.
  - Sankey uses up to 3 dimensions (src/mid/dst) for readability.
