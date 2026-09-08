# Change: Correct sysmon device detail graphs

## Why
Sysmon graphs on the device detail page currently display incorrect values (issue #2444), which misleads operators and obscures actual CPU, memory, and disk utilization.

## What Changes
- Normalize sysmon CPU charts to show utilization as a 0–100% value and surface the current utilization in the card header.
- Update sysmon memory charts to show used versus available memory.
- Update sysmon disk charts to show per-disk/partition utilization instead of per-file metrics.
- Adjust SRQL queries or data transforms feeding the device detail graphs as needed.
- Add/update UI tests or query fixtures covering the corrected semantics.

## Impact
- Affected specs: build-web-ui
- Affected code: `web-ng` device detail views, sysmon chart queries, SRQL query builders or data transforms feeding sysmon charts.
