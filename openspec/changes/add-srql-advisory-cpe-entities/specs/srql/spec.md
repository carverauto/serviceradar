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

### Requirement: SRQL Endpoint Vulnerability Matches Entity
SRQL SHALL provide `in:endpoint_vulnerability_matches` as a queryable device-scoped match entity backed by `platform.endpoint_vulnerability_matches`. Parser aliases SHALL include `vulnerability_matches`, `cve_matches`, and `advisory_matches`. Results SHALL expose device, agent, package identity, advisory identity, `cve_id`, coordinate type/value, severity, CVSS, KEV, exploit available, confidence, status, first/last seen, evidence, plus joined `package_name`, `package_version`, `purl_canonical`, and first-class `epss_score`, `due_date`, and `ransomware_use` lifted from match metadata. Queries SHALL default to `status = 'active'` unless the caller sets `status` explicitly. The `time:` predicate SHALL filter `last_seen_at`.

#### Scenario: Devices affected by a CVE
- **GIVEN** an active match for `CVE-2024-1234` on device `sr:abc` against package nginx
- **WHEN** a client queries `in:cve_matches cve:CVE-2024-1234 sort:cvss_score:desc`
- **THEN** SRQL SHALL return that match
- **AND** the row SHALL identify the device, package name/version, CPE evidence, CVSS, and KEV flags

#### Scenario: Fleet KEV view
- **GIVEN** active KEV and non-KEV matches
- **WHEN** a client queries `in:vulnerability_matches kev:true`
- **THEN** SRQL SHALL return only KEV matches
- **AND** resolved matches SHALL be omitted

#### Scenario: Resolved history is explicit
- **GIVEN** a match with `status = resolved`
- **WHEN** a client queries `in:endpoint_vulnerability_matches cve:CVE-2024-1234 status:resolved`
- **THEN** SRQL SHALL return the resolved row
- **AND** the default query without `status` SHALL omit it

#### Scenario: Priority fields from metadata
- **GIVEN** a match whose metadata contains `epss_score`, `due_date`, and `ransomware_use`
- **WHEN** a client queries that match
- **THEN** the result SHALL expose those three values as first-class fields
- **AND** it SHALL still include `kev` and `exploit_available` columns

### Requirement: SRQL Advisory Query Bounds And Index Use
Interactive advisory, coordinate, and match queries SHALL use parameterized SQL, the documented default filters, LIMIT/offset pagination, and index-backed predicates. `stats:count()` on `in:advisory_coordinates` without a selective filter SHALL be rejected. `downsample` and `rollup_stats` SHALL be unsupported on all three entities. Match queries by CVE SHALL be able to use a `cve_id` index; match time filters SHALL be able to use a `last_seen_at` index.

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
SRQL SHALL support `stats:count()` group-by on `in:vulnerability_advisories` and `in:endpoint_vulnerability_matches`. Advisory group fields SHALL include `severity`, `kev`, `exploit_available`, `provider`, `feed_key`, and `cve_id`. Match group fields SHALL include those plus `device_uid`, `status`, and `confidence`.

#### Scenario: Count KEV matches by severity
- **GIVEN** active matches across severities
- **WHEN** a client queries `in:vulnerability_matches kev:true stats:count() as n by severity`
- **THEN** SRQL SHALL return one row per severity with integer counts
- **AND** resolved matches SHALL not be counted

#### Scenario: Count current advisories by provider
- **GIVEN** current nist-nvd2 and CISA KEV advisories
- **WHEN** a client queries `in:advisories stats:count() as n by provider`
- **THEN** SRQL SHALL return per-provider counts of current rows only

### Requirement: SRQL Package And Device Advisory Pivots
`in:endpoint_packages` SHALL accept `cve` / `cve_id` and `kev` filters implemented as EXISTS subqueries against active `endpoint_vulnerability_matches`. `in:devices` SHALL accept the same filters as EXISTS subqueries against active matches. Result grain SHALL remain packages or devices. Installed-CPE overlap filters and CPE host-count rollups on `in:endpoint_packages` SHALL keep their existing semantics.

#### Scenario: Packages for a CVE
- **GIVEN** an active match linking device package nginx to `CVE-2024-1234`
- **WHEN** a client queries `in:endpoint_packages cve:CVE-2024-1234 current:true`
- **THEN** SRQL SHALL return that package row
- **AND** it SHALL NOT return a match-shaped row

#### Scenario: Devices with KEV
- **GIVEN** one device with an active KEV match and one device with only non-KEV matches
- **WHEN** a client queries `in:devices kev:true`
- **THEN** SRQL SHALL return only the KEV-bearing device
- **AND** each device SHALL appear once

#### Scenario: Installed CPE query is unchanged
- **GIVEN** current package rows with CPE arrays
- **WHEN** a client queries `in:endpoint_packages cpe:cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*`
- **THEN** SRQL SHALL continue to use CPE array overlap on the package table
- **AND** it SHALL NOT require a row in `advisory_coordinates`

### Requirement: SRQL Advisory Read Authorization
SRQL advisory, coordinate, and match entities, including every parser alias, SHALL require `devices.view`. Callers lacking that permission SHALL receive a forbidden error and no advisory, coordinate, or match data.

#### Scenario: Viewer with devices.view
- **GIVEN** a user holds `devices.view`
- **WHEN** the user queries `in:cves`, `in:advisory_cpes`, or `in:cve_matches`
- **THEN** SRQL SHALL authorize the query

#### Scenario: User lacks devices.view
- **GIVEN** a user lacks `devices.view`
- **WHEN** the user queries `in:vulnerability_matches kev:true`
- **THEN** SRQL SHALL deny the query
- **AND** it SHALL return no CVE, CPE, or device match data

#### Scenario: Aliases are gated
- **GIVEN** the parser accepts `in:advisories` and `in:cves` as aliases
- **WHEN** `EntityAccess` resolves the query
- **THEN** both aliases SHALL map to `devices.view`
- **AND** neither SHALL passthrough as an unknown entity

### Requirement: SRQL Advisory Catalog And Cookbook
The SRQL query catalog SHALL list `vulnerability_advisories`, `advisory_coordinates`, and `endpoint_vulnerability_matches` with filter fields, boolean fields, numeric fields, and default sort. The MCP cookbook SHALL include copy-paste recipes for CVE lookup, CPE listing, KEV matches, and device/package pivots, and SHALL state that `in:security_findings cve:` is the OCSF occurrence stream rather than the advisory catalog.

#### Scenario: Catalog lists the new entities
- **GIVEN** an authenticated catalog request
- **WHEN** the client loads SRQL entities
- **THEN** the three new ids are present with `kev`, `cve_id`, and `cvss_score` among the documented fields

#### Scenario: Cookbook distinguishes catalog from findings
- **GIVEN** an MCP agent reads `serviceradar://srql/cookbook`
- **WHEN** it looks up CVE recipes
- **THEN** the cookbook SHALL show `in:cves` / `in:cve_matches` for catalog and exposure
- **AND** it SHALL warn that `in:security_findings cve:` is occurrence-shaped
