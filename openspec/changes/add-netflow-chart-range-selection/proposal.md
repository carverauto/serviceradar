# Change: Add NetFlow Chart Range Selection

## Why
The NetFlow analytics page can show an operator exactly when traffic, protocol mix, or application activity changed, but it cannot select that interval directly. Traffic Over Time only supports one-bucket clicks in two rendering modes, while the protocol and application charts reserve clicks for series filters. Operators must currently estimate the interval in the global time controls and can lose the investigation state already encoded in the URL.

## What Changes
- Adopt the reusable chart range-selection contract on `/observability/netflows` for Traffic Over Time in Lines, Grid, Stacked, and 100% modes, plus Activity by Protocol and Activity by Application.
- Map selections through each renderer's actual x geometry to exact server-supplied bucket intervals, including an inclusive end one microsecond before the next bucket boundary.
- Validate submitted bounds against the currently rendered NetFlow buckets, replace only the SRQL `time:` clause, preserve the remaining non-view query and investigation options, and patch the same `/observability/netflows` route with `view=explorer` so Flow Explorer opens for the selected interval.
- Preserve existing plain-click behavior: Traffic Over Time keeps its one-bucket drill-down and the protocol/application areas keep their series filters. Only a completed drag suppresses its follow-up click.
- Reuse the shared pointer, touch, keyboard, accessibility, and LiveView lifecycle behavior rather than enabling the renderer-specific D3 brush.

## Impact
- Affected specs: `observability-netflow`
- Affected code: `LogLive.Index` NetFlow interval construction, validation, URL patching, and chart markup; reusable chart range-selection controller/hook code; `NetflowTrafficTooltip`; `NetflowStackedAreaChart`; chart styling; and focused JavaScript/Elixir tests under `elixir/web-ng/`
- Prerequisite change: `add-chart-region-selection` defines the reusable `build-web-ui` contract and remains the source of truth for input and accessibility behavior. Its first-drag lifecycle correction must land and that completed change must be archived before this proposal is implemented. This proposal adds a NetFlow consumer and does not change or duplicate the generic contract; factoring the existing hook into a controller is an internal, behavior-preserving refactor.
- No database migration, ingestion change, SRQL grammar change, or new external dependency is required.
