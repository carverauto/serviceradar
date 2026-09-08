# Change: Add Interface Utilization Metrics

## Why
Interface traffic metrics (ifInOctets, ifOutOctets) currently display as raw bytes/second values, but operators think in terms of utilization percentage (e.g., "this link is at 80% capacity"). Without interface speed context, thresholds must be set as absolute values that vary per interface speed, making configuration error-prone. Additionally, showing inbound and outbound traffic as separate graphs wastes screen space and makes it harder to compare the two directions.

## What Changes
- **Percentage-based utilization thresholds**: Store and evaluate thresholds as percentages of interface capacity using `ifSpeed` as the baseline. Support both absolute (bytes/sec) and percentage (%) threshold types.
- **Combined traffic graphs**: Allow inbound and outbound traffic metrics to be rendered on the same chart with proper Y-axis scaling to interface speed.
- **Interface speed storage**: Ensure `ifSpeed` is captured and stored with interface discovery data for utilization calculations.
- **Event/alert creation**: Generate events when utilization exceeds percentage thresholds (e.g., "Inbound > 50% for 5 minutes") and promote to alerts based on duration.

## Impact
- Affected specs: `device-inventory`, `build-web-ui`
- Affected code:
  - `InterfaceSettings` - add threshold_type (absolute/percentage) field
  - `InterfaceThresholdWorker` - add percentage-based evaluation using ifSpeed
  - `timeseries.ex` plugin - add combined multi-series chart support
  - Interface details UI - add combined graph option and percentage threshold config
  - SRQL interfaces query - ensure ifSpeed is returned
