# Tasks: Move Advisory Feed Ingestion Into Core

## 1. Schema + storage
- [x] 1.1 Migration: add `raw jsonb` to `vulnerability_advisories`; add `GIN(jsonb_path_ops)` on `raw` and optional FTS index on description. _(raw + GIN(jsonb_path_ops) + generation/current done; FTS-on-description deferred.)_
- [x] 1.2 Migration: create `platform.advisory_coordinates` (advisory_ref FK, provider, feed_key, coordinate_type, cpe_part/vendor/product, value, version bounds) with btree `(cpe_vendor,cpe_product)`, `gin_trgm_ops` on `value` (pg_trgm already bootstrapped), btree `(coordinate_type,value)`.
- [x] 1.3 Ash resource for `advisory_coordinates`; kept `VulnerabilityAdvisory` and added `raw`/`generation`/`current` + chunked `Repo.insert_all` bulk-upsert (`AdvisoryFeeds.Loader`).
- [x] 1.4 Generation/`current` swap (`Loader.finalize/4`) so matching reads one consistent generation; reaper for old generations (`reap_old_generations/3`).

## 2. Disk staging + PVC
- [x] 2.1 Staging dir config (`SERVICERADAR_ADVISORY_STAGING_DIR`, default `/var/lib/serviceradar/advisory-feeds`); per-run layout + startup orphan reaper (`AdvisoryFeeds.Staging`).
- [x] 2.2 Helm: `core.advisoryFeeds` PVC (default `5Gi`, `templates/advisory-feeds-pvc.yaml`), volume mount + env on core-elx; egress allowlist documented for cisa.gov / api.vulncheck.com / *.amazonaws.com / nvd.nist.gov (`networkPolicy.egress.advisoryFeedsFQDNs`). _(base NetworkPolicy is CIDR-only; FQDN egress documented for the FQDN-aware layer.)_
- [x] 2.3 Docker compose: named volume `serviceradar-advisory-feeds` mounted into core-elx + env.
- [x] 2.4 Fail-closed when the volume is absent (`Staging.volume_available?` → skip nist-nvd2, log) — never fall back to in-memory.

## 3. Acquire + extract + stream-parse
- [x] 3.1 VulnCheck two-step backup client: `GET /v3/backup/<index>` (Bearer) → first `data[]` → stream presigned `url` to `download.zip` (no auth header on S3 GET; 15-min TTL); verify `sha256` (`AdvisoryFeeds.Acquisition`).
- [x] 3.2 Extract: `:zip.unzip` to `extracted/`; detect single `.json` (KEV) vs `*.json.gz` shards (nist-nvd2).
- [x] 3.3 Streaming JSON decoder choice **recorded** (`AdvisoryFeeds.StreamReader` moduledoc): bound memory at the **shard** level (gunzip+`Jason` one ~25 MB shard at a time) rather than add a streaming-decoder dep; swap-in point documented for true incremental decode (Jaxon / `jq -c` NDJSON) if a single multi-GB JSON ever appears.
- [x] 3.4 Per-feed parsers: nist-nvd2 (`Parsers.Nvd` → CPE coordinates + version bounds), VulnCheck KEV + CISA KEV (`Parsers.Kev`, `cve` as list and `cveID` string). NVD CVE 2.0 REST API parser **stubbed** (`do_run("nvd-api")` returns `:nvd_api_not_implemented`).
- [x] 3.5 Batch loader: chunked `Repo.insert_all` upserts for advisories + coordinates (`Loader`, default 2k chunks). _(Bounded-memory verified by unit fixtures; real nist-nvd2 dump verification deferred — needs PVC + token.)_

## 4. AshOban scheduling
- [x] 4.1 Self-scheduling Oban worker per feed (`FeedWorker`, queue `:integrations`; CISA ~hourly; VulnCheck/nist-nvd2/NVD 6h), Oban `unique` single-flight keyed on `feed`; `SystemActor`; `FeedScheduler` wired into `CoordinatorChildren`. _(Used the existing self-scheduling Oban pattern rather than a declarative AshOban trigger — same outcome, mirrors the other core schedulers.)_
- [x] 4.2 Per-feed status: `FeedWorker.mark_status` updates `VulnerabilityFeedDefinition` (last/next, status, counts, error); `FeedWorker.enqueue/1` is the core "Run now".
- [x] 4.3 Feature flag `advisory_feeds_core_enabled` (`Config.enabled?`, on in demo) + nist-nvd2 sub-gate (`Config.nist_nvd2_enabled?`).

## 5. Matcher redesign
- [x] 5.1 Inverted to a package → advisory set-based join over `advisory_coordinates`; **5,000 cap removed**.
- [x] 5.2 CPE 2.3 component + wildcard matching (`AdvisoryFeeds.Cpe`, not full-string equality).
- [x] 5.3 Version-range evaluation (`AdvisoryFeeds.VersionRange`): `versionStartIncluding/Excluding` + `versionEndIncluding/Excluding` vs installed version — fixes the singular-`version_range` vs plural-`version_ranges` bug by storing discrete bound columns; PURL exact + vendor_product fallback kept.
- [x] 5.4 Preserved `endpoint_vulnerability_matches` identity + OCSF finding + device-risk emission (unchanged emit path).

## 6. Retire the add-on + UI
- [x] 6.1 Removed `go/cmd/serviceradar-advisory-producer/**`, `addons/advisory-producer/**`, the addon inventory/BUILD/version-bump-script entries, and `AdvisoryProducerAddonPackageSeeder` (+ its child wiring). The shared `ProducerScheduleDispatcher` is keyed on `producer_kind`, not "advisory", so only the advisory package/schedule rows are removed (6.2).
- [x] 6.2 Data migration `20260615120100_retire_advisory_producer_addon` removes advisory `producer_schedules` / `addon_assignments` / `addon_packages` (scoped to `addon_id = 'advisory-producer'`).
- [x] 6.3 `vulnerability_feeds.ex`: source table already shows core-run status driven by `VulnerabilityFeedDefinition`; copy updated to describe core-scheduled feeds; the generic per-agent Assignment dropdown stays for non-advisory producer schedules (advisory rows no longer appear there after 6.2).

## 7. Validation
- [x] 7.1 Unit tests (pure, DB-free): `Parsers.Nvd`/`Parsers.Kev` (incl. synthetic nist-nvd2 `.json.gz`-in-zip, VulnCheck KEV array, CISA), `Cpe` normalization, `VersionRange` (version-inside/outside scenarios), `Staging`, `Acquisition` (two-step Bearer + no-auth-on-S3). 36 tests passing.
- [ ] 7.2 Integration: full nist-nvd2 load on a PVC in demo — bounded memory, generation swap, match counts; CISA/VulnCheck-KEV enrichment. _(Deferred — needs a deployed PVC + VulnCheck token + stable gateway.)_
- [ ] 7.3 Verify endpoint Software tab + `endpoint_vulnerability_matches` populate with version-correct CVE matches. _(Deferred — needs the live load from 7.2.)_
