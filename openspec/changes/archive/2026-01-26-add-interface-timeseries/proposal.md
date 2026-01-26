# Change: Add interface time-series inventory with short retention

## Why
Interface data is currently handled as a device-level JSON array, which makes it hard to filter, query, and show accurate interface history. We need a single interface time-series table that works for both network gear and servers, and a short TTL so interface noise does not bloat CNPG.

## What Changes
- Define a canonical interface observation schema (single table for routers + servers).
- Store interface observations in a TimescaleDB hypertable with a 3-day retention policy.
- Update mapper ingestion to publish the new interface fields and store interface observations.
- Update SRQL `in:interfaces` to query the interface time-series and support richer filters.
- Update the device details UI to fetch interfaces via SRQL (not device inventory JSON).
- Document OCSF version alignment for device inventory and clarify that interface schema is custom.

## Impact
- Affected specs: `device-inventory`, `srql`, `cnpg`, `build-web-ui`.
- Affected code: `elixir/serviceradar_core` (schema + ingestion), `rust/srql` (interfaces query + filters), `web-ng` (device details UI), `pkg/agent`/`pkg/mapper` (payload fields).

## Notes
- Device inventory remains aligned to OCSF v1.7.0.
- Interface schema is custom (not OCSF-aligned) and optimized for discovery + querying.
