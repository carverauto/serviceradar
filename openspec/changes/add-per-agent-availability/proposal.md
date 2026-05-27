# Change: Add per-agent device availability

## Why

ServiceRadar currently exposes a single canonical `is_available` value for a device. That is not enough when the same device is intentionally tested from multiple network vantage points, such as an OT-segment agent and an intranet agent, where different ICMP/TCP outcomes are expected and meaningful.

Operators need to compare availability by agent, choose which agent drives the primary device availability state, and choose which agent's availability is exported by northbound integrations such as Armis.

## What Changes

- Persist latest sweep availability per device and per agent, including protocol/check details, response time, ports, sweep group/profile context, and freshness metadata.
- Add configuration for choosing the primary availability source for a device or device selection, with a deterministic fallback when no explicit source is configured.
- Add availability source profiles that bind an SRQL device query to a canonical availability agent so operators can manage source-of-truth assignment by network segment or inventory slice.
- Keep canonical `ocsf_devices.is_available` as a derived compatibility field, sourced from the configured primary availability source rather than blindly collapsing every agent's results.
- Expose per-agent availability in device details so users can see how each vantage point sees the device without reading raw JSON.
- Extend SRQL so users can query devices by per-agent availability and primary availability source.
- Extend Armis northbound availability updates so operators can choose which availability source drives the outbound custom-property/tag value.
- Preserve the existing single-inventory model; do not require duplicating devices into separate partitions to represent different network perspectives.

## Impact

- Affected specs: `device-inventory`, `sweep-jobs`, `build-web-ui`, `srql`, `sync-service-integrations`
- Related active change: `add-armis-northbound-availability-updates` should consume the selected availability source defined here instead of assuming the global `is_available` field is always the desired northbound signal.
- Affected code:
  - sweep result ingestion and latest availability rollups in `elixir/serviceradar_core`
  - device inventory Ash resources, migrations, and SRQL projections
  - web-ng device list/detail and integration settings UI
  - Armis northbound payload construction and configuration
  - tests/faker fixtures for multi-agent sweep behavior
