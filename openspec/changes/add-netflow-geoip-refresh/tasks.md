## 1. Spec And Design
- [x] 1.1 Draft `proposal.md`/`design.md`/`tasks.md` and delta specs for `observability-netflow`
- [x] 1.2 Validate change with `openspec validate add-netflow-geoip-refresh --strict`

## 2. Data Model (Elixir Migrations Only)
- [ ] 2.1 Add GeoIP provider/settings table(s) in `platform` schema via migrations in `elixir/serviceradar_core/priv/repo/migrations/`
- [ ] 2.2 Add encrypted field(s) for provider API tokens using AshCloak (no plaintext tokens at rest)

## 3. Background Jobs (AshOban)
- [ ] 3.1 Implement daily MMDB download/refresh job with atomic swap + basic integrity checks
- [ ] 3.2 Implement periodic cache population job that upserts `platform.ip_geo_enrichment_cache` for newly-seen IPs
- [ ] 3.3 Add rate limiting/backoff for hosted provider mode (ipinfo-lite)

## 4. Admin Settings UI (Web-NG)
- [ ] 4.1 Add admin settings UI to configure GeoIP provider and schedules
- [ ] 4.2 Add RBAC gating for settings pages/actions (admin-only)
- [ ] 4.3 Add "manual refresh" action + last-refresh status display

## 5. Validation
- [ ] 5.1 Add tests for settings resource authorization + encrypted token storage
- [ ] 5.2 Add tests for job enqueue/execute paths (happy path + failure handling)
- [ ] 5.3 Verify NetFlow geo heatmap works end-to-end with refreshed cache data (SRQL-driven)
