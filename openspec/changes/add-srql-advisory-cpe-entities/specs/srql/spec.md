## ADDED Requirements

### Requirement: SRQL Vulnerability Advisories Entity
SRQL SHALL provide `in:vulnerability_advisories` as a queryable current advisory catalog entity backed by `platform.vulnerability_advisories`. Parser aliases SHALL include `advisories`, `cves`, and `vulnerability_advisory`. Results SHALL expose `id`, `provider`, `feed_key`, `advisory_id`, `cve_id`, `title`, `description`, `severity`, `cvss_score`, `cvss_vector`, `published_at`, `modified_at`, `kev`, `exploit_available`, `current`, `generation`, `references`, and `metadata`. Results SHALL NOT include `raw` or `affected_coordinates`. Queries SHALL default to `current = true` unless the caller sets `current` explicitly. The `time:` predicate SHALL filter `published_at`. CVE equality and membership filters SHALL compare the uppercased identifier.

#### Scenario: Lookup one CVE
- **GIVEN** a current nist-nvd2 advisory for `CVE-2024-1234` exists
- **WHEN** a client queries `in:cves cve:CVE-2024-1234`
- **THEN** SRQL SHALL return that advisory row
- **AND** the row SHALL include title, severity, CVSS, and KEV flags
- **AND** the row SHALL omit `raw` and `affected_coordinates`

#### Scenario: Default hides stale generations
- **GIVEN** an advisory row with `current = false` for the same CVE
- **WHEN** a client queries `in:vulnerability_advisories cve:CVE-2024-1234`
- **THEN** SRQL SHALL return only the current row

#### Scenario: KEV catalog filter
- **GIVEN** current CISA KEV and nist-nvd2 rows
- **WHEN** a client queries `in:advisories kev:true cvss_score:>=9.0 sort:cvss_score:desc`
- **THEN** SRQL SHALL return current KEV advisories whose CVSS is at least 9.0
- **AND** every predicate SHALL be parameterized

#### Scenario: Case-insensitive CVE id
- **GIVEN** a stored advisory with `cve_id = CVE-2024-1234`
- **WHEN** a client queries `in:cves cve:cve-2024-1234`
- **THEN** SRQL SHALL match the same row

#### Scenario: CPE component filter on the catalog
- **GIVEN** a current advisory with an `advisory_coordinates` row `cpe_vendor=nginx` and `cpe_product=nginx`
- **WHEN** a client queries `in:vulnerability_advisories cpe_vendor:nginx cpe_product:nginx`
- **THEN** SRQL SHALL return that advisory via an EXISTS against `advisory_coordinates`
- **AND** it SHALL NOT scan `affected_coordinates` JSON

#### Scenario: Negated CPE component excludes the parent advisory
- **GIVEN** a current advisory has one nginx coordinate and one apache coordinate
- **WHEN** a client queries `in:vulnerability_advisories !cpe_vendor:apache`
- **THEN** SRQL SHALL omit that advisory using a correlated `NOT EXISTS`
- **AND** the nginx child row SHALL NOT make the negative predicate pass

### Requirement: SRQL Advisory Coordinate Entity
SRQL SHALL provide `in:advisory_coordinates` as a queryable CPE / PURL / vendor_product coordinate entity backed by `platform.advisory_coordinates`. Parser aliases SHALL include `advisory_cpes` and `cpe_coordinates` and SHALL NOT include `cpes`. Results SHALL expose coordinate identity, `coordinate_type`, `value`, CPE 2.3 components (`cpe_part`, `cpe_vendor`, `cpe_product`, `cpe_version`), version-bound columns, and joined current-advisory fields `cve_id`, `title`, `severity`, `cvss_score`, and `kev`. Queries SHALL default to coordinates whose advisory is `current = true`. SRQL SHALL NOT evaluate whether an installed package version falls inside those bounds.

#### Scenario: List CPEs for a CVE
- **GIVEN** CVE-2024-1234 has two current CPE coordinates with different version bounds
- **WHEN** a client queries `in:advisory_coordinates cve:CVE-2024-1234 coordinate_type:cpe`
- **THEN** SRQL SHALL return both coordinate rows
- **AND** each row SHALL include `value`, `cpe_vendor`, `cpe_product`, and version-bound columns
- **AND** each row SHALL include the joined `cve_id` and title

#### Scenario: Vendor and product component filter
- **GIVEN** current coordinates for nginx and apache
- **WHEN** a client queries `in:advisory_cpes cpe_vendor:nginx cpe_product:nginx`
- **THEN** SRQL SHALL return only nginx coordinates
- **AND** the plan SHALL be able to use `(cpe_vendor, cpe_product)`

#### Scenario: Wildcard CPE value
- **GIVEN** current coordinates whose `value` starts with `cpe:2.3:a:nginx:nginx:`
- **WHEN** a client queries `in:advisory_coordinates cpe:cpe:2.3:a:nginx:nginx:%`
- **THEN** SRQL SHALL match those rows with a parameterized `ILIKE`
- **AND** it SHALL NOT interpolate the pattern into SQL

#### Scenario: Stale generation excluded
- **GIVEN** a coordinate whose advisory `current = false`
- **WHEN** a client queries `in:advisory_coordinates cve:CVE-2024-1234`
- **THEN** SRQL SHALL omit that coordinate

#### Scenario: Version matching stays in the matcher
- **GIVEN** a coordinate with `version_end = 1.25.0` exclusive
- **WHEN** a client queries `in:advisory_coordinates` for that CVE
- **THEN** SRQL SHALL return the coordinate as catalog evidence
- **AND** it SHALL NOT decide whether any installed package version is affected

### Requirement: SRQL Endpoint Vulnerability Assessments Entity
SRQL SHALL provide `in:endpoint_vulnerability_assessments` as a queryable
device/package/CVE assessment entity backed by
`platform.endpoint_vulnerability_assessments`. Parser aliases SHALL include
`endpoint_vulnerability_assessment`, `package_vulnerabilities`,
`endpoint_vulnerability_matches`, `vulnerability_matches`, `cve_matches`, and
`advisory_matches`. Results SHALL expose device and agent identity, stable and
current package identity, CVE/advisory identity, status, assessment,
disposition, authority, applicability reason, freshness, provider/release
scope, authority generation/as-of audit markers, fixed version, severity,
CVSS, KEV, exploit availability, supporting
match/assertion IDs, evidence, lifecycle timestamps, and first-class
`epss_score`, `due_date`, and `ransomware_use` lifted from assessment metadata.
Queries SHALL include candidate, confirmed, and resolved assessments unless the
caller filters those fields. The `time:` predicate SHALL filter `last_seen_at`.
Row browsing SHALL NOT add an implicit lifecycle or actionability filter.

#### Scenario: Devices affected by a CVE
- **GIVEN** an active confirmed affected assessment for `CVE-2024-1234` on device `sr:abc` against package nginx
- **WHEN** a client queries `in:cve_matches cve:CVE-2024-1234 sort:cvss_score:desc`
- **THEN** SRQL SHALL return that assessment
- **AND** the row SHALL identify the device, package name/version, authority, decision, CVSS, and KEV flags

#### Scenario: Fleet KEV view
- **GIVEN** actionable, candidate, and resolved KEV assessments
- **WHEN** a client queries `in:vulnerability_matches status:active assessment:confirmed disposition:affected kev:true`
- **THEN** SRQL SHALL return only actionable KEV assessments
- **AND** candidates and resolved history SHALL be omitted

#### Scenario: All lifecycle states are queryable by default
- **GIVEN** candidate, confirmed, and resolved assessments
- **WHEN** a client queries `in:endpoint_vulnerability_assessments cve:CVE-2024-1234`
- **THEN** SRQL SHALL return all matching lifecycle states
- **AND** every row SHALL remain one persisted assessment without supporting-evidence row multiplication

#### Scenario: Priority fields from metadata
- **GIVEN** an assessment whose metadata contains `epss_score`, `due_date`, and `ransomware_use`
- **WHEN** a client queries that assessment
- **THEN** the result SHALL expose those three values as first-class fields
- **AND** it SHALL still include `kev` and `exploit_available` columns

#### Scenario: Legacy advisory reference filters supporting evidence
- **GIVEN** assessments record either a raw match ID or a normalized package assertion ID whose `advisory_ref` is a known UUID
- **WHEN** a client queries the legacy alias `in:endpoint_vulnerability_matches advisory_ref:<uuid>`
- **THEN** SRQL SHALL return assessments through correlated EXISTS predicates over both authoritative evidence paths
- **AND** it SHALL NOT join raw matches into or multiply assessment rows

#### Scenario: Negated advisory reference excludes either evidence path
- **GIVEN** one assessment references the advisory through a raw match and another references it through a normalized package assertion
- **WHEN** a client queries `in:endpoint_vulnerability_matches !advisory_ref:<uuid>`
- **THEN** SRQL SHALL exclude both assessments with `NOT EXISTS` semantics

#### Scenario: Positive raw evidence predicates match one child row
- **GIVEN** an assessment has one supporting CPE row for openssl and another supporting PURL row containing curl
- **WHEN** a client queries `coordinate_type:cpe coordinate_value:%curl%`
- **THEN** SRQL SHALL NOT return that assessment
- **AND** a positive `advisory_ref` combined with coordinate predicates SHALL match the same raw evidence row rather than an assertion-only path

#### Scenario: Filter by authority audit markers
- **GIVEN** assessments from multiple authority generations and timestamps
- **WHEN** a client filters `authority_generation:>=7 authority_as_of:<2026-09-02T12:30:00Z`
- **THEN** SRQL SHALL apply typed integer and timestamp comparisons

### Requirement: SRQL Advisory Query Bounds And Index Use
Interactive advisory, coordinate, and assessment queries SHALL use parameterized SQL, the documented default filters, LIMIT/offset pagination, and index-backed predicates. `stats:count()` on `in:advisory_coordinates` without a selective filter SHALL be rejected. `downsample` and `rollup_stats` SHALL be unsupported on all three entities. Default all-state CVE assessment lookups and actionable device pivots SHALL be able to use the full CVE/device index; actionable package pivots SHALL be able to use the partial package/CVE index; assessment time filters SHALL be able to use a `last_seen_at` index.

#### Scenario: Unbounded coordinate aggregate is rejected
- **GIVEN** a client runs `in:advisory_coordinates stats:count() as n by cpe_vendor`
- **WHEN** SRQL plans the query
- **THEN** it SHALL return a typed invalid-request error
- **AND** it SHALL NOT aggregate the full coordinate table

#### Scenario: Selective coordinate aggregate is allowed
- **GIVEN** current nginx coordinates exist
- **WHEN** a client queries `in:advisory_coordinates cpe_vendor:nginx cpe_product:nginx stats:count() as n by cve_id`
- **THEN** SRQL SHALL return per-CVE counts for those coordinates

#### Scenario: Unfiltered coordinate browse stays limited
- **GIVEN** millions of current coordinate rows
- **WHEN** a client queries `in:advisory_coordinates limit:100`
- **THEN** SRQL SHALL return at most 100 current-generation rows
- **AND** the SQL SHALL include LIMIT and the current-advisory join

#### Scenario: Pagination order is deterministic
- **GIVEN** multiple rows have equal values for the selected sort fields
- **WHEN** a client requests adjacent LIMIT/offset pages for any advisory entity
- **THEN** row ordering SHALL append that entity's UUID as a final tie-breaker
- **AND** grouped counts SHALL append every group key after the count

#### Scenario: Downsample is rejected
- **GIVEN** a client runs `in:cves downsample bucket:1h`
- **WHEN** SRQL plans the query
- **THEN** it SHALL return a typed invalid-request error

#### Scenario: CVE strings are bound
- **GIVEN** a client queries `in:cve_matches cve:CVE-2024-1234`
- **WHEN** SRQL translates the query
- **THEN** the CVE value SHALL appear as a bind parameter
- **AND** it SHALL NOT be interpolated into the SQL text

### Requirement: SRQL Advisory Stats
SRQL SHALL support `stats:count()` group-by on `in:vulnerability_advisories` and `in:endpoint_vulnerability_assessments`. Advisory group fields SHALL include `severity`, `kev`, `exploit_available`, `provider`, `feed_key`, and `cve_id`. Assessment group fields SHALL include those plus `device_uid`, `status`, `assessment`, `disposition`, `freshness`, `authority`, `source_scope`, and package release. An unqualified assessment count SHALL count persisted audit/state rows across every lifecycle state. Exposure counts SHALL require exactly `status:active assessment:confirmed disposition:affected`.

#### Scenario: Unqualified assessment count is an audit-row count
- **GIVEN** actionable, candidate, and resolved assessment rows
- **WHEN** a client queries `in:cve_matches stats:count() as n`
- **THEN** the count SHALL include all three persisted rows
- **AND** it SHALL NOT be described as a current exposure count

#### Scenario: Count KEV matches by severity
- **GIVEN** actionable assessments across severities
- **WHEN** a client queries `in:vulnerability_matches status:active assessment:confirmed disposition:affected kev:true stats:count() as n by severity`
- **THEN** SRQL SHALL return one row per severity with integer counts
- **AND** candidate and resolved assessments SHALL not be counted

#### Scenario: Count current advisories by provider
- **GIVEN** current nist-nvd2 and CISA KEV advisories
- **WHEN** a client queries `in:advisories stats:count() as n by provider`
- **THEN** SRQL SHALL return per-provider counts of current rows only

### Requirement: SRQL Package And Device Advisory Pivots
`in:endpoint_packages` SHALL accept `cve` / `cve_id` and `kev` filters implemented as EXISTS subqueries against `endpoint_vulnerability_assessments` using exactly `status = active`, `assessment = confirmed`, and `disposition = affected`. The package subquery SHALL correlate both `endpoint_package_ref` and `device_uid`. `in:devices` SHALL accept the same filters with the same exact predicate. Result grain SHALL remain packages or devices. Installed-CPE overlap filters and CPE host-count rollups on `in:endpoint_packages` SHALL keep their existing semantics.

#### Scenario: Packages for a CVE
- **GIVEN** an actionable assessment linking device package nginx to `CVE-2024-1234`
- **WHEN** a client queries `in:endpoint_packages cve:CVE-2024-1234 current:true`
- **THEN** SRQL SHALL return that package row
- **AND** it SHALL NOT return an assessment-shaped row
- **AND** it SHALL NOT return the same fleet-shared package coordinate from a different device without its own actionable assessment

#### Scenario: Devices with KEV
- **GIVEN** one device with an actionable KEV assessment and one device with only candidate or resolved KEV assessments
- **WHEN** a client queries `in:devices kev:true`
- **THEN** SRQL SHALL return only the KEV-bearing device
- **AND** each device SHALL appear once

#### Scenario: Installed CPE query is unchanged
- **GIVEN** current package rows with CPE arrays
- **WHEN** a client queries `in:endpoint_packages cpe:cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*`
- **THEN** SRQL SHALL continue to use CPE array overlap on the package table
- **AND** it SHALL NOT require a row in `advisory_coordinates`

### Requirement: SRQL Advisory Read Authorization
SRQL advisory, coordinate, and assessment entities, including every parser alias, SHALL require `devices.view`. Callers lacking that permission SHALL receive a forbidden error and no advisory, coordinate, or assessment data.

#### Scenario: Viewer with devices.view
- **GIVEN** a user holds `devices.view`
- **WHEN** the user queries `in:cves`, `in:advisory_cpes`, or `in:cve_matches`
- **THEN** SRQL SHALL authorize the query

#### Scenario: User lacks devices.view
- **GIVEN** a user lacks `devices.view`
- **WHEN** the user queries `in:vulnerability_matches kev:true`
- **THEN** SRQL SHALL deny the query
- **AND** it SHALL return no CVE, CPE, or device assessment data

#### Scenario: Aliases are gated
- **GIVEN** the parser accepts `in:advisories` and `in:cves` as aliases
- **WHEN** `EntityAccess` resolves the query
- **THEN** both aliases SHALL map to `devices.view`
- **AND** neither SHALL passthrough as an unknown entity

### Requirement: SRQL Advisory Catalog And Cookbook
The SRQL query catalog SHALL list `vulnerability_advisories`, `advisory_coordinates`, and `endpoint_vulnerability_assessments` with filter fields, boolean fields, numeric fields, timestamp fields, and default sort. Assessment filters SHALL include `authority_generation` and `authority_as_of`. The MCP cookbook SHALL include copy-paste recipes for CVE lookup, CPE listing, actionable KEV assessments, candidates, resolved history, audit-row counts, actionable exposure counts, and device/package pivots, and SHALL state that `in:security_findings cve:` is the OCSF occurrence stream rather than the advisory catalog.

#### Scenario: Catalog lists the new entities
- **GIVEN** an authenticated catalog request
- **WHEN** the client loads SRQL entities
- **THEN** the three new ids are present with `kev`, `cve_id`, and `cvss_score` among the documented fields

#### Scenario: Cookbook distinguishes catalog from findings
- **GIVEN** an MCP agent reads `serviceradar://srql/cookbook`
- **WHEN** it looks up CVE recipes
- **THEN** the cookbook SHALL show `in:cves` for catalog and assessment-state-aware `in:cve_matches` recipes
- **AND** it SHALL warn that `in:security_findings cve:` is occurrence-shaped
