## 0. Dependency

- [x] 0.1 Declare that this change lands after
      `add-distro-aware-vulnerability-matching`, which owns the normalized
      assertion and endpoint assessment schema consumed here.

## 1. Indexes

- [x] 1.1 Add named Elixir indexes for assessment lookup by
      `(cve_id, device_uid)`, actionable package pivots by
      `(endpoint_package_ref, cve_id)`, plus assessment recency by
      `last_seen_at`. Keep the CVE/device index available to the default
      all-lifecycle-state query, use the exact actionable partial predicate on
      the package pivot index, build/drop all three indexes concurrently outside
      the DDL transaction and migration lock, and mirror the indexes in the Ash
      resource. Document invalid-index recovery after an interrupted build.
- [x] 1.2 Confirm existing advisory/coordinate indexes named in `design.md`
      are sufficient for the planned filters; do not add redundant GIN on
      `affected_coordinates`.

## 2. SRQL parser and dispatch

- [x] 2.1 Add `Entity::VulnerabilityAdvisories`, `Entity::AdvisoryCoordinates`,
      and `Entity::EndpointVulnerabilityAssessments` to `parser/ast.rs`.
- [x] 2.2 Register canonical names and aliases in `parser/entity.rs`:
      `vulnerability_advisories|advisories|cves|vulnerability_advisory`,
      `advisory_coordinates|advisory_cpes|cpe_coordinates`,
      `endpoint_vulnerability_assessments|endpoint_vulnerability_assessment|package_vulnerabilities|endpoint_vulnerability_matches|vulnerability_matches|cve_matches|advisory_matches`.
      Do **not** alias `cpes` or `security_findings`.
- [x] 2.3 Extend `supports_implicit_like` for `cve`, `cve_id`, `advisory_id`,
      `cpe_vendor`, `cpe_product`, `cpe_part`, `cpe_version`, `coordinate_value`,
      `title` (already present), `description`.
- [x] 2.4 Dispatch the new entities in `query/engine.rs` and
      `query/translate.rs`.
- [x] 2.5 Parser tests for every alias and for unknown-entity errors.

## 3. Advisory catalog entity

- [x] 3.1 Implement `query/vulnerability_advisories.rs` (`execute` +
      `to_sql_and_params`) against `platform.vulnerability_advisories`.
- [x] 3.2 Default `current = true`. Map `time:` to `published_at`. Default
      sort `published_at desc, cve_id asc`.
- [x] 3.3 Filters: `cve`/`cve_id` (uppercase equality / IN / ILIKE),
      `advisory_id`, `provider`, `feed_key`, `severity`, `title`,
      `kev`, `exploit_available`, `current`, numeric `cvss_score`,
      EXISTS `cpe`/`cpe_vendor`/`cpe_product`/`cpe_part` against
      `advisory_coordinates`.
- [x] 3.4 Projection omits `raw` and `affected_coordinates`. Parameterize
      every predicate.
- [x] 3.5 `stats:count()` by `severity`, `kev`, `exploit_available`,
      `provider`, `feed_key`, `cve_id`. Reject `downsample` and
      `rollup_stats`.

## 4. CPE coordinate entity

- [x] 4.1 Implement `query/advisory_coordinates.rs` joining current
      advisories by default.
- [x] 4.2 Filters: `coordinate_type`, `value`/`cpe` (eq / IN / ILIKE),
      `cpe_part`, `cpe_vendor`, `cpe_product`, `cpe_version`, `advisory_ref`,
      joined `cve`/`cve_id`, `provider`, `feed_key`, `kev`.
- [x] 4.3 Project coordinate columns plus joined `cve_id, title, severity,
      cvss_score, kev, current`. Include version-bound columns; do not
      evaluate whether an installed version is in range.
- [x] 4.4 Reject `stats:count()` unless the query has a selective filter
      (`cve`/`cve_id`, `advisory_ref`, `cpe_vendor`+`cpe_product`, exact
      `value`/`cpe`, or a prefix/LIKE on `value`). Unfiltered row queries
      with LIMIT remain allowed.

## 5. Vulnerability assessment entity

- [x] 5.1 Implement the assessment query against
      `endpoint_vulnerability_assessments`, preserving exactly one result per
      persisted assessment and exposing package aliases from the assessment
      row itself.
- [x] 5.2 Return all lifecycle states by default. Map `time:` to
      `last_seen_at`. Default sort puts exact actionable assessments first,
      then KEV, exploit, CVSS, and last seen.
- [x] 5.3 Filters: `device_uid`/`device_id`, `agent_id`, `cve`/`cve_id`,
      `advisory_id`, `provider`, `feed_key`, `status`, `assessment`,
      `disposition`, `authority`, `applicability_reason`, `freshness`, package
      identity/release fields, `severity`, `kev`, `exploit_available`, numeric
      `cvss_score`, typed `authority_generation` / `authority_as_of`,
      package/scan refs, and lifted priority metadata. Keep
      coordinate/CPE compatibility filters as correlated supporting-match
      EXISTS clauses without joining or multiplying assessment rows. Search
      `advisory_ref` through both supporting match and package assertion IDs,
      group positive raw-child predicates into one EXISTS, and keep negative
      predicates as NOT EXISTS.
- [x] 5.4 `stats:count()` by `severity`, `kev`, `exploit_available`,
      `provider`, `feed_key`, `cve_id`, `device_uid`, `status`, `assessment`,
      `disposition`, `freshness`, `authority`, `source_scope`, and release.
- [x] 5.5 Lift `epss_score`, `due_date`, `ransomware_use` from `metadata`
      from assessment metadata into the JSON projection as first-class fields.

## 6. Pivot filters on existing entities

- [x] 6.1 `in:endpoint_packages` accepts `cve`/`cve_id` and `kev` as EXISTS
      against assessments using exactly active + confirmed + affected,
      correlated by both package reference and device.
- [x] 6.2 `in:devices` accepts `cve`/`cve_id` and `kev` with that same exact
      actionable predicate. Device grain is unchanged.
- [x] 6.3 Unsupported operators on those new fields return a typed
      invalid-request error.

## 7. Viz, catalog, RBAC, cookbook

- [x] 7.1 Add viz column metadata for the three entities (table suggestion).
- [x] 7.2 Register the three catalog ids, labels, default sort/filter
      fields, boolean fields (`kev`, `exploit_available`, `current`),
      numeric fields (`cvss_score`, `epss_score`), and filter field lists
      in `catalog.ex`; expose authority generation and as-of as numeric and
      timestamp filters.
- [x] 7.3 Map every canonical name and alias to `devices.view` in
      `entity_access.ex`. Add a unit test that each alias is gated (not
      passthrough).
- [x] 7.4 Add MCP cookbook recipes: lookup CVE, list CPEs for a CVE, list
      actionable KEV assessments, candidates, resolved history, devices with
      a CVE, and packages with KEV. State clearly
      that `in:security_findings cve:` is OCSF occurrences, not the
      catalog, and that installed CPEs stay on `in:endpoint_packages`.

## 8. Tests

- [x] 8.1 Rust unit tests: SQL contains the intended tables/indexes
      predicates, omits `raw`/`affected_coordinates`, binds CVE/CPE
      values, applies defaults, rejects unbounded coordinate stats,
      uppercases CVE equality.
- [x] 8.2 Pivot-filter SQL tests on packages and devices (EXISTS, no
      grain change).
- [x] 8.3 SRQL integration fixtures for one advisory, two coordinates,
      correlated raw/assertion evidence, a two-child same-row regression, and
      actionable/candidate/resolved assessments;
      queries covering each entity plus `in:endpoint_packages cve:` and
      `in:devices kev:true`.
- [x] 8.4 Catalog/RBAC tests for the new ids and aliases.

## 9. Spec gate

- [x] 9.1 Do not start implementation until this proposal is approved.
- [x] 9.2 `openspec validate add-srql-advisory-cpe-entities --strict`
      stays green as the spec is edited.
