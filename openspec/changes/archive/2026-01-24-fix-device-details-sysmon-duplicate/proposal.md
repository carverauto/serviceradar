# Change: Remove duplicate sysmon processes rendering on device details page

## Why
The device details page currently renders sysmon processes twice - once without an icon (via the metric_sections loop) and once with an icon (via the dedicated `process_metrics_section` component). This creates confusion for operators and clutters the UI. See GitHub issue #2470.

## What Changes
- Remove the process section from the `metric_sections` array to eliminate the first (icon-less) rendering
- Keep the dedicated `process_metrics_section` component which includes the proper icon in the card header

## Impact
- Affected specs: build-web-ui
- Affected code: `web-ng/lib/serviceradar_web_ng_web/live/device_live/show.ex`
  - Remove or skip the `build_process_section/3` function call in `load_metric_sections/3`
  - Keep `process_metrics_section` component rendering at lines 1485-1488
