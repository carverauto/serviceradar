# Change: Add SRQL entities for advisories, CPE coordinates, and vulnerability assessments

## Why

Core already ingests CISA KEV, VulnCheck KEV, and VulnCheck nist-nvd2 into
`platform.vulnerability_advisories` / `platform.advisory_coordinates`. The
matcher retains raw coordinate evidence in
`platform.endpoint_vulnerability_matches`. The approved
`add-distro-aware-vulnerability-matching` change adds normalized package
assertions and the authoritative
`platform.endpoint_vulnerability_assessments` applicability state consumed by
this change. Operators can see vulnerability data on a device Software tab,
but SRQL cannot answer fleet questions such as "which hosts have this CVE",
"which advisories cover this CPE", or "list current actionable KEV assessments
with CVSS >= 9".

What SRQL *does* already cover is narrower:

- `in:endpoint_packages` / `in:endpoint_package_catalog` filter installed
  software by exact CPE array overlap and expose CPE host-count rollups.
- `in:security_findings` / `in:events` can filter occurrence-shaped OCSF
  payloads by `cve` / `cpe` JSON keys. That is not the advisory catalog.
- `improve-threat-intel-investigation` (pending) adds IP/CIDR IOC matches as
  `in:threat_intel_matches`. It does not cover CPEs, CVEs, or KEV.

The catalog, coordinates, and assessment table need first-class SRQL entities so
dashboards, MCP, and the query builder can query them the same way they query
packages and devices.

## What Changes

- Add `in:vulnerability_advisories` (aliases `advisories`, `cves`) over current
  advisory catalog rows: CVE id, provider/feed, severity, CVSS, KEV, exploit
  available, title, published/modified time. Default `current:true`. Do not
  project `raw` or the embedded `affected_coordinates` array.
- Add `in:advisory_coordinates` (aliases `advisory_cpes`, `cpe_coordinates`)
  over normalized CPE / PURL / vendor_product rows with parsed CPE 2.3
  components and NVD version bounds. Default join is current-generation
  advisories. Support exact `cpe`/`value`, component filters
  (`cpe_vendor`, `cpe_product`, `cpe_part`, `cpe_version`), and `%` wildcards
  on `value`.
- Add `in:endpoint_vulnerability_assessments` (aliases
  `endpoint_vulnerability_assessment`, `package_vulnerabilities`, and the
  legacy match names) over stable device/package/CVE decisions. Expose
  assessment, disposition, authority, applicability reason, freshness,
  package/release identity, supporting evidence IDs, priority, and lifecycle
  timestamps. Return candidate, confirmed, and resolved rows unless callers
  filter them. Project `epss_score`, `due_date`, and `ransomware_use` from
  assessment metadata as first-class fields.
- Add pivot filters so existing entities can reach actionable assessments:
  `in:endpoint_packages cve:` / `kev:`, and `in:devices cve:` / `kev:`.
- Add `cve:` (EXISTS coordinate/advisory) as a catalog filter on
  `in:vulnerability_advisories` via the coordinate table, and `cpe:` /
  `cpe_vendor:` / `cpe_product:` likewise.
- Support `stats:count()` group-by on advisories and assessments (severity,
  KEV, CVE, provider, device, lifecycle decision, authority, and freshness).
  Assessment counts are persisted audit/state-row counts by default; exposure
  counts require the exact active + confirmed + affected filter. No downsample;
  these are not hypertables.
- Register the entities in the SRQL parser, query engine, viz metadata, web-ng
  catalog, RBAC entity map, MCP cookbook, and SRQL integration fixtures.
- Add supporting CNPG indexes for assessment CVE pivots and recency. Do not
  reimplement generic or distro-native version matching in SRQL; that stays in
  `EndpointVulnerabilityMatcher`.

## Non-Goals

- IP/CIDR IOC inventory, `in:threat_intel_matches`, or threat-aware `in:flows`
  filters. Those belong to `improve-threat-intel-investigation`.
- Domain / URL / hash / TLS CTI matching. That belongs to
  `add-cti-signal-coverage`.
- Additional changes to advisory ingest, matcher adjudication, KEV overlay, or the Software tab
  (`refactor-advisory-feeds-into-core`, `add-cve-priority-context`).
- Re-evaluating NVD `versionStartIncluding` / `versionEndExcluding` inside SRQL.
  "Is this installed version affected?" is an assessment question.
- Projecting full NVD `raw` objects or the legacy `affected_coordinates` JSON
  array through SRQL.
- A new first-party dashboard package in this change. Catalog + cookbook +
  query builder are the UI surface; dashboard frames can follow.
- Broadening endpoint CPE synthesis (still a documented matcher limitation).

## Impact

- Affected specs: `srql`
- Affected code:
  - `rust/srql/src/parser/ast.rs`, `parser/entity.rs`, `parser/filters.rs`
  - `rust/srql/src/query/engine.rs`, `query/translate.rs`, `query/mod.rs`,
    `query/viz/**`
  - new `rust/srql/src/query/{vulnerability_advisories,advisory_coordinates,endpoint_vulnerability_matches}.rs`
  - `rust/srql/src/query/endpoint_packages.rs`, `query/devices/**` (pivot filters)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/srql/entity_access.ex`
  - `elixir/web-ng/priv/mcp/srql-cookbook.md`
  - `elixir/serviceradar_core/priv/repo/migrations/**` (assessment indexes)
  - `integration_tests/srql/tests/comprehensive_queries.rs` and fixtures
- Related (do not reopen): `add-endpoint-sbom-inventory` (package CPE),
  `refactor-advisory-feeds-into-core` (tables), `add-cve-priority-context`
  (KEV/EPSS priority context), `improve-threat-intel-investigation` (IOC matches).
- Dependency: `add-distro-aware-vulnerability-matching` supplies
  `advisory_package_assertions`, `endpoint_vulnerability_assessments`, and their
  evidence/authority columns. This change must land after that schema contract.
