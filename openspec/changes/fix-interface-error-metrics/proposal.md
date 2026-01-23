# Change: Fix configured interface error metrics collections

## Why
Configured SNMP interface error counters (inbound/outbound errors) are not appearing in SRQL results or UI charts even after collection is enabled. This blocks operators from validating interface health and creates uncertainty about whether collection is working.

## What Changes
- Ensure configured interface error counters are collected, mapped, and persisted alongside other interface metrics.
- Guarantee SRQL `in:interfaces` queries surface the configured error metrics fields (latest and time series).
- Update the interface metrics UI to render error counters when present and show a clear empty-state when they are not yet available.

## Impact
- Affected specs: `snmp-checker`, `srql`, `build-web-ui`.
- Affected code: SNMP collector/config compilation, ingestion mapping to interface metrics storage, SRQL interface query projection, and interface detail charts in `web-ng`.
