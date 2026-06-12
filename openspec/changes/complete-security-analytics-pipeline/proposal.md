# Change: Complete the Security Analytics Pipeline

## Why

ServiceRadar built the scaffolding for security analytics — OCSF persistence, a generic advisory-feed contract, producer scheduling, and a security dashboard — but four load-bearing pieces were never connected, and each maps directly to a user-reported defect. Every claim below is verified against code.

1. **Falco findings are normalized but most are dropped from analytics.** `event_writer/processors/falco_events.ex` already decomposes Falco JSON into an OCSF Detection Finding (class 2004) with rich diagnostics, but `promote_to_event?/1` (line 55) only writes a finding when `severity_id >= severity_medium`, so `notice`/`info`/`debug` events live only in `logs` and never appear in `in:security_findings`. The class is hardcoded to 2004 for every rule, and finding identity has no dedup/grouping contract.
2. **`/security` and `/dashboards/security-findings` are duplicates.** `SecurityLive.Index` (router.ex:716) and the `security-findings` dashboard package (router.ex:715 + `priv/dashboard-packages/security-findings/manifest.json`) run the same SRQL queries against the same entities with no documented division.
3. **The security dashboard is slow because frames run serially.** `FrameRunner.run/3` (`frame_runner.ex:19-26`) maps over frames sequentially; the manifest declares 11 frames all marked `required: true`, all run before first paint and re-run every 15s.
4. **NVD/CISA-KEV/VulnCheck feeds were never built.** The contract (`go/pkg/addon/advisory_contract.go`, `producer_schedule_contract.go`), ingestor (`VulnerabilityAdvisoryIngestor`), schedule catalog (`ProducerScheduleCatalog`), and settings UI (`Settings.SecurityLive.VulnerabilityFeeds`) all exist, but no package declaring `advisory-feed:v1` exists anywhere in the repo. The two empty-state strings the user quoted are `vulnerability_feeds.ex:186` and `:375`.

## What Changes

### A. Falco → structured OCSF findings (decomposition completeness)
- **Promote a structured finding for every Falco event, regardless of severity.** Decouple "write a finding" from "raise an alert": keep the existing `promote_to_alert?` gate (line 59) for stateful alerting, but make `promote_to_event?` always true so low/informational Falco events become `ocsf_events` rows visible in `in:security_findings source:falco`. (Severity stays as a *filter*, not a *gate*.) — `event_writer/processors/falco_events.ex`
- **Add a Falco-rule → OCSF class/type map** so rules can resolve to Detection (2004), Vulnerability (2002), Compliance, or other Findings classes instead of a single hardcoded `class_detection_finding()` (lines 285-289). Default remains 2004 when unmapped. — `falco_events.ex`, `event_writer/ocsf.ex`
- **Add a stable finding-identity / grouping contract** (`finding_info` with rule + key dimensions) so re-fired rules update or correlate to one logical finding rather than minting a new UUID per occurrence (current behavior at lines 754-766). **[BREAKING]** changes the `ocsf_events.metadata`/observable shape consumers rely on; SRQL catalog + dashboard frames updated in lockstep.
- Add tests/fixtures for low-severity promotion, class mapping, and finding grouping.

### B. Clear `/security` vs security-dashboard division
- **Make `/dashboards/security-findings` the single data surface** (declarative SRQL frames in the manifest) and **redefine `/security` as a navigation/triage shell** that links into the dashboard and into Observability drill-downs, removing its duplicated inline SRQL probes (`security_live/index.ex:15-58`, 96-117). **[BREAKING]** for any bookmark/links assuming `/security` renders the full data grid.
- Document the division in the spec: dashboard = "what is happening" (data frames, refreshable, exportable); `/security` = "triage entry point" (curated links, selected-finding/detection detail panels that already exist in `index.ex`).
- Remove the now-redundant per-source `limit:1` probe list from `SecurityLive.Index`.

### C. Fix slow security dashboard
- **Run dashboard frames concurrently.** Replace the sequential `Enum.map` in `FrameRunner.run/3` (`frame_runner.ex:23-25`) with a bounded `Task.async_stream` (per-frame timeout, capped concurrency `@max_frames`), preserving order and existing error-frame semantics. — `frame_runner.ex`
- **Collapse the 8 `limit:1` "latest per source" probe frames** in `security-findings/manifest.json` into one grouped/faceted query (or mark them `required: false` so they lazy-load after first paint via the existing `initial_data_frames/1` non-required path at show.ex:243-247). — `priv/dashboard-packages/security-findings/manifest.json`
- **Stop re-running the full serial batch every 15s**: in `dashboard_frame_channel.ex`, run the refreshed frames concurrently (inherits the FrameRunner fix) and skip frames whose `last_frames` hash is unchanged.
- Add an SRQL/index review for `in:security_findings`, `in:scan_activity`, `in:dns_activity` time-desc queries to confirm a supporting index exists on `(source, time desc)` / `(class_uid, time desc)`.

### D. Ship working NVD / CISA-KEV / VulnCheck advisory producers
- **Author one advisory-feed producer package per source** (NVD, CISA KEV, VulnCheck) that declares `capabilities: ["advisory-feed:v1", "producer-schedule:v1"]` and a `producer_schedules` block in its manifest (validated by `manifest.ex:75-102`). Each producer downloads, validates, normalizes, stages the snapshot via the agent-gateway object-store path, and submits a `serviceradar.advisory_feed.contract.v1` batch consumed by `VulnerabilityAdvisoryIngestor`.
  - NVD: CVE 2.0 API → `AdvisoryRecord` with CPE `AffectedCoordinate`s; credentialed API key via `credential_requirements`.
  - CISA KEV: known-exploited catalog → sets `kev: true` / `exploit_available: true`, vendor_product coordinates.
  - VulnCheck: KEV+NVD-enriched feed → CVE/CVSS/KEV + PURL/CPE coordinates; API token credential.
- **Wire package install → schedule materialization**: confirm `ProducerScheduleCatalog.sync_package/2` runs on import for these packages so rows appear in `ProducerSchedule` and the schedules table at `vulnerability_feeds.ex:374-376` is no longer empty.
- **Decide producer execution model** (design.md): native add-on (Go, reusing `go/pkg/addon`) vs Wasm plugin. Recommend native add-on for NVD/VulnCheck (large feeds, credentialed) consistent with the `native-addon-delivery-models` line of work; CISA KEV can be either.
- Default cadences from `NewProducerScheduleContract` (daily, 300s–30d bounds); CISA KEV more frequent.

## Impact

### Affected specs
- `observability-signals` (Falco finding completeness, OCSF class mapping, finding identity)
- `vulnerability-feed-management` (already drafted under `fix-endpoint-inventory-profile-operations`; extend with concrete producer requirements) **or** a new `advisory-feed-producers` capability
- `build-web-ui` (security page vs dashboard division, dashboard concurrency)
- `wasm-plugin-system` / native add-on specs (producer packaging) depending on execution-model decision

### Affected code
- `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/falco_events.ex` (promotion gate, class map, finding identity)
- `elixir/serviceradar_core/lib/serviceradar/event_writer/ocsf.ex` (class/type helpers)
- `elixir/web-ng/lib/serviceradar_web_ng/dashboards/frame_runner.ex` (concurrent frames)
- `elixir/web-ng/lib/serviceradar_web_ng_web/channels/dashboard_frame_channel.ex` (concurrent + hash-skip refresh)
- `elixir/web-ng/priv/dashboard-packages/security-findings/manifest.json` (collapse `limit:1` probes / mark non-required)
- `elixir/web-ng/lib/serviceradar_web_ng_web/live/security_live/index.ex` (strip duplicated probes; reframe as triage shell)
- `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_package_live/show.ex` (initial-frame strategy)
- New producer packages (Go add-ons or Wasm plugins) for NVD / CISA-KEV / VulnCheck, packaged + signed via existing native-addon/Wasm delivery pipeline
- `go/pkg/addon/*` only if helper builders are needed; contracts themselves are complete
- BUILD.bazel updates for any new Go packages/tests (bazel deps must track new imports)

### Non-Goals / dedup with existing work
- Not CTI/threat-intel: `add-alienvault-otx-integration` and `add-cti-signal-coverage` own STIX/TAXII IOC matching against NetFlow/DNS. This change is the *vulnerability advisory* path (CVE↔package matching), which is a distinct, already-specced contract.
- Not Falco alert-diagnostics enrichment: `update-falco-alert-diagnostics` already enriched promoted-event metadata; this change fixes *which* events become findings, the *class*, and finding *identity* — it builds on that work, it does not redo it.
- Does not change Falco detection rules or default alert thresholds.