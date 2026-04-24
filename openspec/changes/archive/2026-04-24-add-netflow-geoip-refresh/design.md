## Context
NetFlow visualizations rely on geo aggregation fields (for example `src_country_iso2`/`dst_country_iso2`). Those fields MUST be computed from cached enrichment data (database cache tables) and MUST NOT trigger external network requests during SRQL query execution.

GeoIP datasets (MMDB) change over time and must be refreshed automatically. Operators also want the option to use a hosted provider (`ipinfo.io/lite`) when they prefer not to manage MMDB files, but that requires secure credential storage and an admin UX.

## Goals
- Provide a reliable background refresh pipeline for GeoIP datasets and cache population.
- Keep SRQL query-time behavior stable: join to cache tables only, no external calls.
- Provide an admin-only settings UI to manage provider configuration and see status.

## Non-Goals
- "Learned"/inferred local CIDRs or automatic subnet classification.
- Persisting flow direction at ingestion time (may be revisited separately for performance).

## Provider Options
### Option A: Local MMDB (default)
- Daily download of GeoLite-derived `.mmdb` files.
- Store on disk in a path appropriate for the runtime environment:
  - Docker Compose: container filesystem + bind/volume
  - Kubernetes: persistent volume mount (preferred) or emptyDir with daily refresh (acceptable if cache is also persisted in DB)
- Use atomic swap semantics:
  - download to a temp file
  - verify the file is non-empty and looks like MMDB
  - move/rename into place

### Option B: ipinfo.io lite (optional)
- Requires an API token per deployment.
- Token MUST be stored encrypted at rest using AshCloak.
- Background job performs lookups for IPs not yet in cache (or for periodic refresh).
- The system MUST enforce rate limiting and batching to avoid provider bans and runaway costs.

## Cache Population Strategy
- Source of IPs: distinct `src_endpoint_ip`/`dst_endpoint_ip` observed within a bounded time window (for example the last 24h, configurable).
- Enrichment pipeline:
  - Determine the candidate IPs missing from `platform.ip_geo_enrichment_cache` (and optionally stale rows past TTL).
  - Enrich in batches.
  - Upsert into the cache table with a `refreshed_at` timestamp.

## Scheduling
- Use AshOban triggers for scheduled refresh.
- Default schedules:
  - MMDB download: daily
  - Cache refresh: every N minutes (bounded), or on-demand + periodic

## Security / RBAC
- Admin-only access to provider settings and manual refresh.
- Ensure the settings routes/controllers are protected via existing RBAC patterns.

## References (Provider Data Sources)
The GeoLite-derived MMDB download sources are documented in `P3TERX/GeoLite.mmdb` (GitHub). For implementation, follow that README’s latest download link set and mirror behavior.

