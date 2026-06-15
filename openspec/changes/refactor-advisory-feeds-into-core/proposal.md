# Change: Move Advisory Feed Ingestion Into Core (Disk-Staged, AshOban-Scheduled)

## Why

The advisory-feed producers were designed in `complete-security-analytics-pipeline` (section D) as Go **native add-ons that run on an agent** and ship a normalized batch up through the agent → agent-gateway → core pipeline. That works for a small feed (CISA KEV is ~5k entries) but fails for the data that actually matters for endpoint vulnerability matching — the full NVD CVE 2.0 CPE dataset. Every claim below is verified against code and against the live VulnCheck endpoints.

1. **The volume cannot pass through the agent pipeline.** The operationally useful CPE source is VulnCheck's `nist-nvd2` backup: a single index call returns a presigned S3 **355 MB zip of ~181 gzipped NVD-2.0 shards (~250k CVEs, millions of CPE match rows)**. The producer marshals the *entire* batch into one in-memory `CommandResult.PayloadJSON` (`go/cmd/serviceradar-advisory-producer/main.go:150-158`); core ingests one decoded map (`vulnerability_advisory_ingestor.ex:32`). There is **no chunking and no artifact staging** for advisory batches. A multi-GB feed cannot be shipped as one payload through NATS/gRPC, and pushing it through an edge agent is wasteful — the feed is global, not per-agent.

2. **Dispatch is fragile and agent-coupled.** "Run now" dispatches to a specific `assignment.agent_uid` through the command bus (`producer_schedule_dispatcher.ex:193`); when that agent is offline (or the gateway is flapping) the run fails `{:agent_offline, ...}`. A global feed should not depend on any agent being online.

3. **Storage does not scale.** Coordinates are stored as one embedded JSON array per CVE (`vulnerability_advisory.ex:102`) with only a whole-array GIN index — no per-CPE row, no indexed CPE lookup. Ingestion does **one Ash `create` per advisory inside a single transaction** (`vulnerability_advisory_ingestor.ex:221-235`); 250k sequential upserts in one txn is unviable.

4. **Matching is capped and version-blind.** `EndpointVulnerabilityMatcher` loads advisories **capped at 5,000** (`endpoint_vulnerability_matcher.ex:45-69`), matches CPE by **literal full-string equality** (`:140-161`), and reads version bounds from the **plural** `version_ranges` key while the NVD producer writes the **singular** `version_range` with `versionStartIncluding`/`EndExcluding` (`main.go:610-615`) — so NVD version semantics are silently dropped and every install of a matching product is flagged for every historical CVE.

The fix is architectural: stop pushing bulk feeds through agents. Core-elx should own feed acquisition, parse it **off disk** (never the whole file in memory), and batch-load it into CNPG.

## What Changes

- **Remove the advisory-feed responsibility from the agent add-on.** Deprecate and retire `serviceradar-advisory-producer` and the agent-dispatched "Run now" producer-schedule path. **[BREAKING]** The Vulnerability Intelligence UI's per-agent "Assignment" model is removed; feeds run in core, not on an agent.
- **Add core-elx feed workers scheduled by AshOban**, one per feed, default ~6h cadence (CISA KEV more frequent). Each worker: acquires the feed, stages it on disk, extracts, stream-parses, and batch-loads CNPG.
- **Disk-first pipeline (never in-memory):** download the archive to a persistent staging directory → extract (`unzip`/`gunzip`) → **stream-parse** shard-by-shard → **batch-load into CNPG via `COPY`/`insert_all` in bounded chunks**. Working set stays bounded regardless of dump size.
- **Storage redesign:** add a normalized, indexed `advisory_coordinate` table (cpe / purl / vendor_product, with discrete version-bound columns) so CPE lookups are set-based and indexed; bulk-upsert advisories instead of row-by-row.
- **Matcher redesign:** invert to a **package → advisory** set-based join on indexed CPEs; implement **CPE 2.3 component matching + version-range evaluation** (`versionStartIncluding/Excluding`, `versionEndIncluding/Excluding`); remove the 5,000 cap.
- **Infra:** add a **Kubernetes PVC** (helm chart) and a **Docker volume** (compose stack) for the on-disk feed staging directory, with retention/cleanup; add egress allowlist entries for the feed endpoints.
- **Feeds covered:** CISA KEV (enrichment), VulnCheck KEV (enrichment, CISA-KEV-shaped, `cve` as list, no CPEs), **VulnCheck `nist-nvd2`** (full NVD 2.0 CPE dataset — the primary CPE source), and NVD CVE 2.0 API (fallback). VulnCheck feeds use the verified **two-step backup flow**: `GET /v3/backup/<index>` + Bearer token → `data[].url` presigned S3 zip → extract.

## Impact

- **Affected specs:** `advisory-feed-producers` (MODIFIED — execution model add-on → core, disk staging, storage/matcher requirements), `device-inventory` (endpoint CPE/version-range matching).
- **Affected code:**
  - `elixir/serviceradar_core/lib/serviceradar/inventory/**` (new AshOban feed workers, ingestor rewrite, matcher rewrite)
  - `elixir/serviceradar_core/priv/repo/migrations/**` (advisory_coordinate table + indexes)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/security_live/vulnerability_feeds.ex` (drop per-agent assignment; core-run status)
  - `helm/serviceradar/**` (PVC + volume mount + egress)
  - `docker-compose*.yml` / packaging (named volume)
  - **Remove** `go/cmd/serviceradar-advisory-producer/**` and its addon package seeder
- **Breaking:** removes the producer add-on package and the agent "Run now" dispatch; changes the producer-schedule model from agent-assigned to core-scheduled.

## Non-Goals

- Real CPE extraction for endpoint inventory packages. osv-scalibr supplies **PURLs only** (`scalibrinventory/adapter.go:357-364`); endpoint CPEs are synthesized for ~13 hardcoded products today (`endpoint_inventory_package_set.ex:27-41`). Full-NVD CPE matching is only as good as endpoint CPE coverage; broadening that (NVD CPE-dictionary mapping or scalibr CPE extraction) is tracked separately.
- Replacing the OCSF finding / device-risk emission path (kept as-is, fed by the new matcher).
- A general object-store/artifact-staging redesign; this change uses a local PVC staging dir, not the agent object store.
