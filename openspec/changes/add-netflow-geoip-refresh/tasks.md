## 1. Spec And Design
- [x] 1.1 Draft `proposal.md`/`design.md`/`tasks.md` and delta specs for `observability-netflow`
- [x] 1.2 Validate change with `openspec validate add-netflow-geoip-refresh --strict`

## 2. Existing Foundations (Already Implemented)
- [x] 2.1 `platform.ip_geo_enrichment_cache` exists and is used as the SRQL query-time source of truth
- [x] 2.2 MMDB download/refresh worker exists (`ServiceRadar.Observability.GeoLiteMmdbDownloadWorker`) and is scheduled via `GeoLiteMmdbScheduler`
- [x] 2.3 Enrichment refresh worker exists (`ServiceRadar.Observability.IpEnrichmentRefreshWorker`) and populates `platform.ip_geo_enrichment_cache` from SRQL-discovered IPs
- [x] 2.4 Optional hosted provider settings (ipinfo-lite) exist in `platform.netflow_settings` with AshCloak encrypted token storage
- [x] 2.5 Admin NetFlow settings UI exists with RBAC gating (`/settings/netflows`)

## 3. Status Persistence (This Change)
- [x] 3.1 Add persisted last-success/last-error fields for MMDB refresh and IP enrichment refresh (Elixir migration in `elixir/serviceradar_core/priv/repo/migrations/`)
- [x] 3.2 Update workers to record status on success/failure (system-only writes)
- [x] 3.3 Add a `geoip_enabled` toggle (default enabled) to allow disabling GeoIP cache population

## 4. Admin Controls (Web-NG)
- [x] 4.1 Display MMDB refresh + enrichment refresh status (timestamps + last error) in the NetFlow settings UI
- [x] 4.2 Add "Run now" controls to enqueue MMDB refresh and enrichment refresh jobs (admin-only)

## 5. Validation
- [ ] 5.1 Add/extend tests for status field updates and authorization boundaries (system write, admin read)
- [ ] 5.2 Smoke test end-to-end: refresh jobs run and NetFlow geo heatmap remains SRQL-driven
