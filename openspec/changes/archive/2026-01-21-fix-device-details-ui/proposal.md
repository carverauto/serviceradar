# Change: Fix device details sysmon visualizations

## Why
Device detail pages are showing sysmon metrics for devices that do not report them, and sysmon CPU/memory/disk metrics render as tables that are hard to read. Auto-generated visualizations for "Categories: type_id by modified" add noise without value.

## What Changes
- Gate sysmon metric panels so they only appear for devices with sysmon metrics data or agent-backed sysmon status
- Render sysmon CPU, memory, and disk metrics as graphs instead of tables
- Remove the default/auto visualization for "Categories: type_id by modified"

## Impact
- Affected specs: build-web-ui
- Affected code: web-ng device detail UI, metrics/visualization components, device detail data fetch
