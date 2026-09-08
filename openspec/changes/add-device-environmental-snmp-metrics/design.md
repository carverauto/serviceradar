## Context
Interface metrics discovery is in place, but device-level environmental metrics (CPU, memory, temperature, power, fan, etc.) are not surfaced. Operators need to see and configure these metrics only after a device is confirmed SNMP-capable and discovery reveals which environmental OIDs exist.

## Goals / Non-Goals
- Goals:
  - Detect SNMP capability and environmental metrics during mapper discovery.
  - Persist discovered capabilities and available metrics on the device record.
  - Provide a device details UI to enable/disable environmental SNMP polling.
  - Emit environmental metrics to the existing `timeseries_metrics` pipeline.
- Non-Goals:
  - Interface-level metric discovery (already covered elsewhere).
  - Vendor-specific MIB extensions beyond the curated environmental OID catalog.
  - Automatic enabling of polling without operator confirmation.

## Decisions
- Discovery will probe a curated environmental OID catalog and attach an `available_environmental_metrics` list to each device discovery result.
- A `snmp_supported` capability flag will be set when discovery obtains valid SNMP responses for a device.
- Environmental metric polling configuration will be stored in a device-level settings resource and compiled into SNMP collector config.
- All emitted datapoints use the existing `timeseries_metrics` pipeline with device identifiers and metric metadata.

## Risks / Trade-offs
- Probing environmental OIDs may increase discovery time; mitigate with bounded catalog size and timeouts.
- Some devices expose partial data; UI should only show discovered metrics and allow users to opt in.

## Migration Plan
- Add nullable capability/metrics fields to device inventory; existing devices remain valid with null/false defaults.
- Deploy discovery updates first to populate capabilities; then enable UI configuration.

## Open Questions
- Should discovery re-probe environmental OIDs on every scan or only on first successful SNMP discovery?
- Which environmental OIDs are required for initial support vs. optional add-ons?
