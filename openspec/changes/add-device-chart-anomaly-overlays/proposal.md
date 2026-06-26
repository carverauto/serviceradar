# Change: Add device chart anomaly and capacity overlays

## Why

Device detail already loads anomaly findings and capacity forecasts, and timeseries charts can render timestamp annotations. Operators still have to mentally connect the finding list to the CPU/memory/disk graphs; the graph should show where the finding occurred and, for capacity forecasts, where the current runway is headed.

## What Changes

- Add first-class device metric chart overlays for anomaly findings: matched series/time markers, spike windows when available, peak/current value labels, and disposition-aware severity.
- Add device metric chart overlays for capacity forecasts: projected exhaustion markers, threshold/reference lines, projected value/runway context, and confidence bounds when present.
- Keep overlays read-only and query-driven from existing `in:events` anomaly rows and `in:capacity_forecasts` rows; no detector changes and no new metric ingestion path.
- Degrade gracefully when finding metadata is incomplete: keep list/detail panels accurate, but only draw chart overlays when time and metric/series context can be matched without inventing data.

## Impact

- Affected specs: `build-web-ui`
- Affected code: `elixir/web-ng` device detail anomaly/capacity data projection, sysmon metric section annotation mapping, timeseries chart rendering components/hooks/tests.
- Depends on: existing `add-anomaly-finding-disposition` for disposition-aware effective severity and, later, peak/window fields on edge anomaly findings. The UI must support those fields when present but not require them for current rows.
- Non-goal: implementing anomaly detection, seasonal disposition, or capacity forecasting logic. This change only visualizes persisted findings/forecasts on existing metric charts.
