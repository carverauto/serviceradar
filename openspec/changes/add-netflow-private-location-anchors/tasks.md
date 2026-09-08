## 1. Implementation
- [x] 1.1 Add nullable location fields to `platform.netflow_local_cidrs` in an Elixir migration.
- [x] 1.2 Expose the location fields on `ServiceRadar.Observability.NetflowLocalCidr` with validation for latitude and longitude ranges.
- [x] 1.3 Update the NetFlow settings UI to create/edit labels, CIDRs, and optional physical anchors.
- [x] 1.4 Update dashboard traffic queries to resolve private endpoints through the most-specific enabled CIDR anchor before falling back to GeoIP cache.
- [x] 1.5 Keep geographic NetFlow rendering limited to endpoints with real GeoIP or configured anchor coordinates.
- [x] 1.6 Add focused tests for CIDR anchor persistence and dashboard map payload behavior.
- [x] 1.7 Run focused Elixir tests and rebuild web assets.
