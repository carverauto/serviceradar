# Change: Add Device Environmental SNMP Metrics

## Why
Operators need to collect device-level environmental metrics (CPU, memory, temperature, power, fan, etc.) that are not interface metrics. Today the system only discovers interface metrics, so there is no device capability flag or UI path to configure environmental SNMP polling.

## What Changes
- Mapper discovery SHALL infer SNMP capability for each device and probe for available environmental OIDs during discovery.
- Device inventory SHALL persist SNMP capability flags and the list of available environmental metrics per device.
- The device details editor SHALL allow users to enable polling of discovered environmental metrics for SNMP-capable devices.
- Selected environmental metrics SHALL be polled via the existing SNMP collector and emitted into the `timeseries_metrics` pipeline.

## Impact
- Affected specs: `network-discovery`, `device-inventory`, `snmp-checker`, `build-web-ui`.
- Affected code: Go mapper discovery (`pkg/mapper`), mapper result publishing (`pkg/agent`), Elixir ingestion (`elixir/serviceradar_core`), SRQL device query surface (`rust/srql`), and web-ng device details UI.
