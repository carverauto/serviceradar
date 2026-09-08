## Context
`platform.netflow_local_cidrs` already exists for directionality tagging. It is the right ownership boundary for deployer knowledge such as "farm01 networks are in Carver, MN" and "tonka01 networks are in Minnetonka, MN".

GeoIP enrichment remains the source for public IP locations. Private/local ranges are not GeoIP-resolvable and need explicit operator-provided anchors.

## Goals
- Reuse the existing NetFlow settings surface and RBAC.
- Prefer deterministic, operator-owned coordinates over generated positions.
- Preserve honest rendering: no geographic arc is drawn unless both endpoints have real coordinates from GeoIP or a configured anchor.

## Non-Goals
- Full topology site modeling.
- Automatic inference from SNMP `sysLocation`.
- Changing NetFlow ingest schemas or raw flow payloads.

## Data Model
Add nullable fields to `platform.netflow_local_cidrs`:
- `location_label text`
- `latitude double precision`
- `longitude double precision`

Validation:
- Latitude must be between `-90` and `90` when present.
- Longitude must be between `-180` and `180` when present.
- A row is considered mappable only when both latitude and longitude are present.

## Anchor Selection
For each flow endpoint:
1. Try `platform.ip_geo_enrichment_cache` for public/enriched IPs.
2. If no valid GeoIP coordinate exists, match enabled `netflow_local_cidrs` where `endpoint_ip::inet <<=` `cidr`.
3. Prefer the most-specific matching CIDR using `masklen(cidr)` descending.
4. Use the anchor coordinates and `location_label` for map labels.

Unmatched endpoints remain unmapped and are excluded from geographic arcs.
