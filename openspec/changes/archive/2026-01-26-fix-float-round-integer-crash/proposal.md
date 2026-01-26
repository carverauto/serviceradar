# Change: Fix Float.round integer crash in Active Scans UI

## Why
The Active Scans settings tab crashes with `FunctionClauseError` because `Float.round/2` receives an integer `0` instead of a float `0.0`. This occurs when scanner metrics contain integer values that need percentage formatting.

## What Changes
- Add defensive float conversion in `scanner_metrics_grid` component before calling `Float.round/2`
- Ensure all numeric values from external data sources are converted to floats before rounding
- Follow existing pattern in codebase: `* 1.0` to coerce integers to floats

## Impact
- Affected specs: `build-web-ui`
- Affected code: `web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index.ex`
- Risk: Low - purely defensive fix, no behavior change for valid float inputs

## Root Cause Analysis
The bug occurs at `index.ex:1907`:
```elixir
{Float.round(@rx_drop_rate_percent || 0.0, 2)}%
```

When `@rx_drop_rate_percent` is integer `0` (from backend data), the `||` operator returns `0` because `0` is truthy in Elixir. `Float.round(0, 2)` then throws `FunctionClauseError` because it only accepts floats.

## Fix Strategy
Convert values to float using `* 1.0` multiplication before rounding:
```elixir
{Float.round((@rx_drop_rate_percent || 0.0) * 1.0, 2)}%
```

Or better, ensure float type at the assignment point in `scanner_metrics_grid/1`.
