# Change: Add private network location anchors for NetFlow maps

## Why
Dashboard NetFlow maps can only place public IPs that have GeoIP enrichment. Private RFC1918 endpoints such as `10.0.0.0/8` and `192.168.0.0/16` currently have no deployer-controlled location, so the map either drops them or falls back to meaningless synthetic coordinates.

## What Changes
- Extend NetFlow local CIDR configuration with optional latitude, longitude, and display location metadata.
- Add settings UI controls for assigning a physical anchor to private/local CIDR ranges.
- Use the most-specific enabled CIDR anchor when enriching dashboard NetFlow endpoints that lack GeoIP coordinates.
- Keep unanchored, unenriched endpoints off geographic NetFlow maps instead of drawing fabricated arcs.

## Impact
- Affected specs: `observability-netflow`
- Affected code: `ServiceRadar.Observability.NetflowLocalCidr`, NetFlow settings LiveView, Elixir migration under `elixir/serviceradar_core/priv/repo/migrations`, dashboard traffic query/loading, `OperationsTrafficMap`
