# Design: Advisory Feed Ingestion in Core (Disk-Staged)

## Context

Verified end-to-end pipeline today (from code trace):

```
producer add-on (agent) → addon manager → NATS/gRPC → PluginResultIngestor
  → VulnerabilityAdvisoryIngestor.ingest (1 txn, row-by-row Ash create)
  → platform.vulnerability_advisories  (coordinates = 1 JSONB array per CVE)
  → Oban EndpointVulnerabilityMatchWorker (hourly, cap 5000)
  → EndpointVulnerabilityMatcher (per-coordinate SQL, exact CPE string, version-blind)
  → platform.endpoint_vulnerability_matches → OCSF finding + device risk → UI
```

Feeds and shapes (verified live against VulnCheck with the provided token):
- **CISA KEV** — `https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json` — `{vulnerabilities:[…]}`, ~1.4k, vendor/product only.
- **VulnCheck KEV** — `GET https://api.vulncheck.com/v3/backup/vulncheck-kev` (Bearer) → `data[0].url` presigned zip → single `vulncheck_known_exploited_vulnerabilities.json` (top-level **array**, 4,957 entries, `cve` is a **list**, CISA-KEV-shaped, **no CPEs**). Enrichment only.
- **VulnCheck nist-nvd2** — `GET https://api.vulncheck.com/v3/backup/nist-nvd2` (Bearer) → `data[0].url` presigned **355 MB zip of ~181 `nvdcve-2.0-NNN.json.gz` shards**; each gunzips to standard NVD 2.0 `{vulnerabilities:[{cve:{… configurations … cpeMatch …}}]}`. **Primary CPE source.**
- **NVD CVE 2.0 API** — `https://services.nvd.nist.gov/rest/json/cves/2.0` — paginated, rate-limited. Fallback when VulnCheck is unavailable.

Presigned URLs carry their own credentials and **expire in 15 min** — download must follow promptly after the index call, with no auth header on the S3 GET.

## Goals / Non-Goals

Goals: bounded memory regardless of dump size; indexed CPE matching with version-range semantics; no agent involvement; idempotent 6-hour refresh; survivable restarts (resume/cleanup of partial downloads).

Non-Goals: broadening endpoint CPE coverage (separate); object-store staging (use a local PVC); changing the OCSF/device-risk emit path.

## Decisions

### D1. Execution: core-elx AshOban workers, one per feed
Each feed is an `AshOban`-triggered worker (queue `:integrations` or a new `:advisory_feeds`) with a cron-style schedule (CISA KEV hourly-ish; VulnCheck/NVD every 6h). The worker owns the whole lifecycle (acquire → stage → parse → load) and uses `SystemActor` (no `authorize?: false`). A single-flight lock (advisory_feed row `status`/`locked_at`, or an Oban `unique` window) prevents overlapping runs.

Rejected: keeping the Go add-on (the whole point is to stop pushing bulk data through agents). Rejected: a separate sidecar service (core already has DB access, scheduling, and the matcher; a new service adds ops surface for no gain).

### D2. Disk staging on a PVC (never whole-file-in-memory)
Staging root `${SERVICERADAR_ADVISORY_STAGING_DIR:-/var/lib/serviceradar/advisory-feeds}` on a dedicated volume. Per-run layout:
```
<root>/<feed_key>/<run_id>/
  download.zip            # streamed from the presigned URL to disk
  extracted/              # unzip output (json, or *.json.gz shards)
```
Pipeline per run:
1. **Acquire** — for VulnCheck: `GET /v3/backup/<index>` (Bearer) → first `data[]` entry → stream the presigned `url` to `download.zip` (io.copy to file, not memory). For CISA/NVD-API: stream JSON to disk.
2. **Extract** — `unzip` to `extracted/`. For nist-nvd2, members are `*.json.gz` (left gzipped; decompressed shard-by-shard during parse).
3. **Verify** — compare against the index `sha256` when present.
4. **Parse + Load** (D3/D4).
5. **Cleanup** — delete `<run_id>/` on success; keep last N failed runs for debugging; reap orphaned dirs older than T on startup.

Sizing: nist-nvd2 zip ~355 MB + extracted gz ~360 MB ⇒ PVC **≥ 5 Gi** (headroom for two runs + future growth). Helm `persistence.advisoryFeeds.size` default `5Gi`; compose named volume `serviceradar-advisory-feeds`.

### D3. Streaming parse
- **nist-nvd2:** iterate shards; for each `*.json.gz`, wrap a file reader in a gzip stream and decode incrementally. Decode the top-level object, then stream the `vulnerabilities` array element-by-element (do not hold the whole shard). One shard (~25 MB max gz) is the memory bound. Elixir: `File.stream!` → `:zlib` gunzip stream → a streaming JSON decoder (e.g. `Jaxon`/`jiffy` streaming) emitting one `cve` object at a time.
- **VulnCheck KEV / CISA:** array of objects; stream elements.
- Map each record to advisory + coordinate rows in memory **per batch only** (D4), then flush.

### D4. Batch-load into CNPG — hybrid JSONB record + normalized coordinate table
Two complementary representations (a raw JSONB record for flexibility/provenance, plus extracted normalized rows for indexed matching). Never one-Ash-create-per-row — accumulate chunks of **~1–5k** and flush with `Repo.insert_all` / `COPY` via `Postgrex` using `on_conflict` upserts.

**(a) Full record as JSONB** — `vulnerability_advisories` keeps the structured CVE columns (cve_id / severity / cvss / kev / exploit / dates) and adds a `raw jsonb` column holding the **complete upstream CVE object** (flexible schema, fast ad-hoc extraction, future-proof against feed shape drift). Indexing on `raw`:
- `GIN` on `raw` (jsonb_path_ops) for path / containment queries.
- optional FTS / `GIN(to_tsvector(...))` on description for keyword search.
- Bulk upsert by `(provider, feed_key, source_object_id)`.

**(b) Normalized match table** — `platform.advisory_coordinates`, one row per coordinate, extracted from `raw` at load time so the matcher never parses JSONB at query time:
- `advisory_ref` (FK), `provider`, `feed_key`, `coordinate_type` (`cpe`|`purl`|`vendor_product`)
- parsed CPE-2.3 components `cpe_part`,`cpe_vendor`,`cpe_product`, plus `value` (full CPE/PURL string)
- normalized version bounds `version_start`,`version_start_inclusive`,`version_end`,`version_end_inclusive`
- indexes: btree `(cpe_vendor, cpe_product)` for the component join; **`gin_trgm_ops` (pg_trgm) on `value`** for wildcard/partial CPE string matching; btree `(coordinate_type, value)` for PURL exact; covering index for the match join.

**CPE normalization** happens at extraction (Elixir or a Postgres SQL function): split the CPE-2.3 URI into components, lower-case, map `*`/`-`/NA per the CPE spec, and stash both the components and the literal string. The matcher then matches on components (indexed) and only falls back to trigram/string ops for wildcard tails — keeping it indexable instead of full-string-equality (the current bug, `endpoint_vulnerability_matcher.ex:140-161`).

**Generations:** a run writes to a staging set then atomically marks `current` (or swaps a `feed_snapshot_id`) so matching always sees one consistent generation; the previous generation is reaped after. Joins against the existing `endpoint_inventory_packages` (PURL-canonical + `cpes` GIN, already present) drive real-time risk scoring / dashboards / alerts.

### D5. Matcher redesign (set-based, version-aware)
Replace per-advisory iteration with a **package → advisory join**:
```
endpoint_inventory_packages (current=true)  ⋈  advisory_coordinates
  on cpe component match (vendor/product, part) with wildcard handling
  filtered by version-range predicate (semver/CPE version compare)
```
- CPE 2.3 matching: compare `part/vendor/product`; treat `*`/`-` wildcards; do not require full-string equality.
- Version evaluation: implement `versionStartIncluding/Excluding` + `versionEndIncluding/Excluding` against the installed package version (CPE-version / semver compare). PURL exact + vendor_product fallback remain.
- Remove the 5,000 cap; the join is bounded by endpoint package count (small) × indexed advisory coordinates, not by total CVEs.
- Output unchanged: upsert `endpoint_vulnerability_matches`, emit OCSF finding, update device risk.

### D6. UI / schedule model
The "Scheduled Producers" panel loses the per-agent **Assignment** dropdown and the "Run now → agent" path. Each feed shows: enabled toggle, cadence, URL/credential, last/next run, last status, counts — all driven by the core worker. "Run now" enqueues the Oban job in core. Credentials (VulnCheck token, NVD key) stay encrypted at rest.

### D7. Retire the add-on
Remove `go/cmd/serviceradar-advisory-producer`, its `BUILD.bazel`, the addon-package seeder, and the `producer-schedule:v1` agent-dispatch path for advisories. Keep the `advisory_feed` contract types only insofar as the core parser reuses field semantics. Migration: on deploy, the new core schedules supersede any existing producer schedules; old `addon_assignments` for the producer are removed by a data migration.

### D8. Rollout / safety
- Ship behind a feature flag (`advisory_feeds_core_enabled`) defaulting on in demo, off until PVC exists elsewhere.
- The matcher rewrite is backward-compatible with existing `endpoint_vulnerability_matches` identity (`device_uid, endpoint_package_ref, advisory_ref, coordinate_type, coordinate_value`).
- First nist-nvd2 load is large; gate it so CISA/VulnCheck-KEV enrichment works even if the NVD load is disabled.

## Risks

- **Streaming JSON in Elixir** — pick a decoder that supports incremental array parsing; if none fits, shell to a small streaming pre-splitter (jq `-c`) writing NDJSON, then `COPY`. Decide in task 3.
- **PVC availability** — if the volume is missing, the worker must fail closed (skip nist-nvd2) and log, not OOM by falling back to memory.
- **Endpoint CPE coverage** — matching value is limited until endpoint packages carry real CPEs (non-goal here; surfaced as a dependency).
- **Match explosion** — with broad CPEs + no version filter the join could explode; version-range filtering (D5) is required before enabling nist-nvd2 in production.
