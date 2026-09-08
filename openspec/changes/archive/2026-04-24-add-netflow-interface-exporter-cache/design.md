## Context

Flow records include:
- `sampler_address` (exporter identity as seen by the collector)
- `input_snmp` / `output_snmp` (SNMP ifIndex values) (availability depends on exporter)

ServiceRadar already has inventory data for interfaces (names, descriptions, speed) and device identity. We want SRQL to expose operator-friendly dimensions without doing ad-hoc application-side joins for charting.

## Goals

- Enable SRQL group-by and filters by exporter/interface metadata for `in:flows`.
- Provide the metadata required for percent-of-capacity units (handled in a separate change).
- Keep chart data strictly SRQL-driven.

## Non-Goals

- Real-time streaming updates of cache on every inventory change (we can start with periodic refresh).
- Backfilling flow rows with interface names (cache is a join-time projection only).

## Proposed Data Model

### `platform.netflow_exporter_cache`

Key:
- `sampler_address` (text, primary key)

Fields (initial):
- `exporter_name` (text, nullable)
- `device_uid` (text/uuid, nullable; depends on inventory)
- `updated_at` (timestamptz)

### `platform.netflow_interface_cache`

Key:
- `(sampler_address, if_index)` (primary key)

Fields (initial):
- `if_index` (int)
- `if_name` (text, nullable)
- `if_description` (text, nullable)
- `if_speed_bps` (bigint, nullable)
- `boundary` (text enum-ish: `internal|external|unknown`, nullable) (optional, if inventory classification exists)
- `updated_at` (timestamptz)

## Refresh Strategy

- Periodic Oban workers refresh caches from inventory on a schedule (default: hourly).
- Refresh is idempotent and bounded (upsert by primary key).

## SRQL Integration (Flows)

Add flow dimensions projected via LEFT JOIN against the cache tables:
- `exporter_name`
- `in_if_name`, `out_if_name`
- `in_if_speed_bps`, `out_if_speed_bps`
- (optional) `in_if_boundary`, `out_if_boundary`

Downsample `series:` SHOULD support these text dimensions for time-series charts.

## Performance Notes

- Cache tables are small (bounded by exporter count and interface count).
- Ensure supporting indexes exist for joins:
  - `netflow_exporter_cache(sampler_address)`
  - `netflow_interface_cache(sampler_address, if_index)`

