# Change: Add NetFlow GeoIP Refresh Pipeline And Provider Settings

## Why
GeoIP enrichment is required to make NetFlow traffic actionable (country flags/filters, geographic aggregation, and less "raw IP only" interpretation). The dashboard MUST NOT perform external lookups at query time, so GeoIP data needs a background refresh pipeline and admin-configurable provider settings.

## What Changes
- Add a scheduled background job to fetch and refresh GeoIP MMDB databases daily (GeoLite-derived), with atomic swap and basic integrity checks.
- Add a GeoIP enrichment worker that populates/refreshes `platform.ip_geo_enrichment_cache` for IPs observed in NetFlow flows.
- Add an admin settings UI (with RBAC) to:
  - Enable/disable GeoIP enrichment
  - Choose the enrichment provider (MMDB vs optional `ipinfo.io/lite`)
  - Configure provider credentials (stored encrypted via AshCloak)
  - Trigger a manual refresh and view last refresh status
- Preserve the constraint that SRQL queries only join against the cache tables; there are no external calls at query time.

## Non-Goals
- Inferred local CIDRs (directionality inference).
- rDNS enrichment.
- Threat-intel feed integrations.

## Impact
- Affected specs: `observability-netflow`
- Affected code:
  - Elixir (Ash/AshOban/AshCloak) background jobs and settings resources
  - `elixir/web-ng/` admin settings UI + RBAC gating
  - Existing SRQL NetFlow geo grouping continues to use `platform.ip_geo_enrichment_cache`
- Data model:
  - New provider/settings table(s) in the `platform` schema (via Elixir migrations only)
  - Existing `platform.ip_geo_enrichment_cache` continues to be the query-time source of truth

