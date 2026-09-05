## Context

The advisory catalog and raw matcher evidence already exist in CNPG. The
assessment and normalized assertion rows below are supplied by the approved
`add-distro-aware-vulnerability-matching` dependency:

| Table | Role | Scale |
|---|---|---|
| `platform.vulnerability_advisories` | One row per feed object (CVE / KEV entry) | ~250k current nist-nvd2 + ~5k KEV |
| `platform.advisory_coordinates` | One row per CPE / PURL / vendor_product, with CPE 2.3 components and discrete version bounds | millions |
| `platform.endpoint_vulnerability_matches` | Coordinate-level supporting evidence produced by `EndpointVulnerabilityMatcher` | fleet × packages × matching coordinates |
| `platform.advisory_package_assertions` | Normalized distro/package applicability evidence supplied by the dependency | advisories × package assertions |
| `platform.endpoint_vulnerability_assessments` | Stable device × logical package × CVE applicability decision supplied by the dependency | fleet × packages × assessed CVEs |

SRQL today can filter *installed* CPEs on `endpoint_packages` (`cpes && ARRAY[...]`) and can filter OCSF finding *events* by JSON `cve`/`cpe` keys. It cannot query the catalog or the authoritative assessment table.

Existing indexes, including the base assessment indexes supplied by the
dependency, that this change must use:

- `vulnerability_advisories_cve_idx` on `(cve_id)` where not null
- `vulnerability_advisories_generation_idx` on `(provider, feed_key, generation, current)`
- `advisory_coordinates_type_value_idx` on `(coordinate_type, value)`
- `advisory_coordinates_value_trgm_idx` GIN trgm on `value`
- `advisory_coordinates_vendor_product_idx` on `(cpe_vendor, cpe_product)` where vendor not null
- `endpoint_vulnerability_assessments_actionable_idx` on `(device_uid, last_seen_at)` for the exact actionable predicate
- `endpoint_vulnerability_assessments_endpoint_package_ref_idx` on `(endpoint_package_ref)`

Missing for the planned queries:

- actionable assessments by `cve_id` and device/package pivot
- assessments by `last_seen_at` (`time:` / sort)

## Goals / Non-Goals

- Goals:
  - Three SRQL entities for catalog, coordinate, and assessment grains, with assessment rows from the dependency carrying their package identity.
  - Index-backed plans; parameterized SQL; no interpolation of CVE/CPE strings.
  - Default to *current* advisories while keeping every assessment lifecycle state queryable by default.
  - Keep version-range evaluation in the matcher. SRQL reads the result.
- Non-goals: IOC/CTI entities, ingest/matcher rewrites, projecting NVD `raw`, downsample/CAGG, a new dashboard package.

## Decisions

### Decision: Three entities, not one joined "vulnerabilities" view

Operator questions fall into three grains:

1. Catalog: "what does NVD/KEV say about CVE-2024-1234?"
2. Coordinate: "which CPE rows does that advisory apply to, including version bounds?"
3. Assessment: "what applicability decision exists for each of *our* device packages?"

A single wide view would either explode (one row per coordinate × device) or hide coordinates. Follow the package pattern (`endpoint_package_catalog` vs `endpoint_packages`) instead.

**Aliases** (parser, catalog, RBAC must list all of them):

| Canonical `in:` | Aliases | Not an alias |
|---|---|---|
| `vulnerability_advisories` | `advisories`, `cves`, `vulnerability_advisory` | — |
| `advisory_coordinates` | `advisory_cpes`, `cpe_coordinates` | `cpes` — too easy to confuse with installed-package CPE rollups |
| `endpoint_vulnerability_assessments` | `endpoint_vulnerability_assessment`, `package_vulnerabilities`, `endpoint_vulnerability_matches`, `vulnerability_matches`, `cve_matches`, `advisory_matches` | `security_findings` — that remains OCSF findings/events |

### Decision: SQL builder style is `sql_query` + `to_jsonb`, like `public_endpoints`

Diesel `table!` DSL is a poor fit for the coordinate → advisory joins, correlated raw-evidence filters, and dropping `raw` / `affected_coordinates` from the projection. Build explicit SQL with `?` binds and JSONB projection, the way `public_endpoints` does.

### Decision: Defaults and time columns

| Entity | Implicit filter unless overridden | `time:` maps to | Default sort |
|---|---|---|---|
| `vulnerability_advisories` | `current = true` | `published_at` | `published_at desc`, then `cve_id` |
| `advisory_coordinates` | join `vulnerability_advisories.current = true` | coordinate `inserted_at` | `cpe_vendor, cpe_product, value` |
| `endpoint_vulnerability_assessments` | none | `last_seen_at` | actionable predicate desc, then `kev`, exploit, CVSS, and last seen desc |

Assessment queries deliberately include candidates and resolved history. Clients
must apply `status = active AND assessment = confirmed AND disposition = affected`
when they need only actionable exposure; no looser subset is equivalent.
This applies to row browsing and aggregates alike: no implicit lifecycle filter
is added to an unqualified assessment query.

### Decision: SRQL does not evaluate CPE version ranges

`in:advisory_coordinates cpe_vendor:nginx cpe_product:nginx` returns catalog applicability rows, including `version_start` / `version_end`. It does **not** decide whether `nginx 1.24.0-2ubuntu7` is in range. Generic and distro-native adjudication is materialized as `endpoint_vulnerability_assessments` by the `add-distro-aware-vulnerability-matching` dependency. Document this in cookbook recipes so agents do not try to re-implement matching in a query.

### Decision: Pivot filters on packages and devices use EXISTS

`in:endpoint_packages cve:CVE-2024-1234` and `in:devices kev:true` are EXISTS subqueries against `endpoint_vulnerability_assessments` using the exact actionable predicate. Candidates, fixed/not-affected decisions, and resolved history cannot make those pivots positive. The subqueries do not change result grain.
Package pivots correlate both `endpoint_package_ref` and `device_uid`; a
fleet-shared package coordinate on one affected device must not make the same
coordinate appear vulnerable on another device.

`in:vulnerability_advisories cpe_vendor:nginx` is EXISTS against `advisory_coordinates`.
Positive coordinate components share one correlated EXISTS so vendor and product
must occur on the same coordinate row. Negated components use correlated
`NOT EXISTS`; a different child row cannot make an advisory pass a negative
coordinate predicate.

### Decision: CVE identifiers are folded to uppercase

Equality and IN lists for `cve` / `cve_id` normalize with `upper(trim(...))`. Storage is already `CVE-...`. LIKE patterns are not folded beyond ILIKE.

### Decision: Default projection omits bulky columns

Advisories: `id, provider, feed_key, advisory_id, cve_id, title, description, severity, cvss_score, cvss_vector, published_at, modified_at, kev, exploit_available, current, generation, references, metadata`.

Not projected: `raw`, `affected_coordinates`.

Coordinates additionally project joined `cve_id, title, severity, cvss_score, kev` from the advisory.

Assessments project their persisted decision, authority, freshness, package,
release, support IDs, and lifecycle columns. Compatibility fields
`package_version` and `purl_canonical` alias `installed_version` and
`package_purl`; `epss_score`, `due_date`, and `ransomware_use` are lifted from
assessment metadata. A correlated EXISTS may filter raw coordinate evidence by
supporting match ID, but raw rows are never joined into and cannot multiply the
result. Legacy `advisory_ref` filters search both supporting raw-match IDs and
normalized assertion IDs. Positive coordinate/confidence predicates share one
raw-match EXISTS; when combined with `advisory_ref`, that advisory UUID must be
on the same raw row. Each negative predicate uses `NOT EXISTS`, and a negated
advisory UUID excludes either evidence path.

### Decision: RBAC is `devices.view`

Assessments are device-scoped inventory, same as `endpoint_packages`. The catalog is the same dataset the Software tab already shows to viewer-plus. Do not invent a new permission. Do not put these entities under `observability.events.view` (that is the OCSF event/finding stream) or `observability.netflow.view` (that is the IOC-match change).

Unknown-entity passthrough in `EntityAccess` is a footgun: once the parser accepts the new `in:` names, the RBAC map **must** list every alias or the HTTP/MCP path will skip the gate.

### Decision: Query bounds for the coordinate table

`advisory_coordinates` can be millions of rows. Plans:

1. Default `current = true` join so stale generations are out.
2. Always apply `LIMIT` / offset pagination (existing SRQL cursor cap).
   Row ordering appends the entity UUID as a final tie-breaker, and grouped
   counts append every group key after the count, so equal-valued pages do not
   drift between requests.
3. Prefer component filters (`cpe_vendor` + `cpe_product`) which hit
   `advisory_coordinates_vendor_product_idx`.
4. Exact `value` / `cpe` hits `(coordinate_type, value)`.
5. `%` wildcards use the trgm GIN index via `ILIKE`.
6. Do **not** reject an unfiltered `in:advisory_coordinates limit:100`. It is a
   valid browse. It **must** still go through the current-generation join and
   LIMIT, never `SELECT * FROM advisory_coordinates`.
7. `stats:count()` on coordinates without a selective filter (cve, vendor+product,
   value, or coordinate_type+prefix) SHALL return a typed invalid-request error
   rather than aggregate the whole table.

### Decision: Indexes this change adds

Elixir migration, paired with matching Ash custom-index declarations:

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS endpoint_vuln_assessments_cve_device_idx
  ON platform.endpoint_vulnerability_assessments (cve_id, device_uid);

CREATE INDEX CONCURRENTLY IF NOT EXISTS endpoint_vuln_assessments_package_cve_actionable_idx
  ON platform.endpoint_vulnerability_assessments (endpoint_package_ref, cve_id)
  WHERE status = 'active' AND assessment = 'confirmed' AND disposition = 'affected';

CREATE INDEX CONCURRENTLY IF NOT EXISTS endpoint_vuln_assessments_last_seen_idx
  ON platform.endpoint_vulnerability_assessments (last_seen_at);
```

The migration disables both the DDL transaction and Ecto migration lock so the
three indexes can be built without blocking assessment writes. This is a
non-atomic availability tradeoff: an interrupted concurrent build can leave an
invalid index that `IF NOT EXISTS` skips. Operators must explicitly drop an
invalid same-name index and rerun the migration; a redeploy alone cannot repair
it.

Do not add a generated-column EPSS index in this change; `epss_score:>=0.9`
filters `metadata->>'epss_score'` and is acceptable for KEV-sized subsets. If
that path is hot after ship, follow up with a stored column.

### Decision: Stats, not rollups or downsample

`stats:count() as n by <field>` on advisories and assessments. Supported group
fields: `severity`, `kev`, `exploit_available`, `provider`, `feed_key`,
`cve_id`, and on assessments also `device_uid`, `status`, `assessment`,
`disposition`, `freshness`, `authority`, `source_scope`, and package release.
`rollup_stats:` and `downsample` are unsupported (typed error). No new CAGG.

An assessment `stats:count()` counts persisted assessment audit/state rows that
match the caller's filters. With no lifecycle filters, candidate and resolved
rows are included just as they are in row browsing. An exposure count must use
all three exact filters: `status:active assessment:confirmed
disposition:affected`.

### Alternatives considered

- **One `in:vulnerabilities` view.** Hides coordinate grain or explodes it.
  Rejected.
- **Diesel `table!` + query DSL.** Rejected because of joins and omitted
  columns; `public_endpoints` is the closer template.
- **Alias `in:cpes`.** Rejected; collisions with package CPE rollups
  (`rollup_stats:current_cpe_counts`) and cookbook confusion.
- **Re-run version matching in SQL.** Duplicates `EndpointVulnerabilityMatcher`
  and will drift (this is how the old 5k-cap matcher went wrong). Rejected.
- **New `security.advisories.view` permission.** The Software tab already uses
  viewer-plus / `devices.view`. Split later if a customer needs it; do not
  block the query surface.

## Risks / Trade-offs

- **Million-row coordinate scans.** Mitigate with default current-generation
  join, LIMIT, trgm/component indexes, and a stats-without-filter reject.
- **CVE/CPE string injection.** All values are binds. CVE equality is
  uppercased in the planner, not concatenated.
- **Overlap with `in:security_findings cve:`.** Cookbook must say findings are
  occurrence-shaped OCSF rows; assessments are stateful matcher output. Same CVE
  can appear in both for different reasons.
- **Misreading candidates as findings.** The canonical entity returns all
  lifecycle states for auditability. Cookbook pivot recipes use the exact
  actionable triple, and direct callers must do the same when they want only
  current exposure.
- **EPSS/due date only in JSONB.** Acceptable for v1; document that
  `metadata.epss_score` and the lifted `epss_score` field are the same value.

## Migration Plan

1. Land `add-distro-aware-vulnerability-matching`, including the assertion and
   assessment schema.
2. Add assessment indexes owned by this change (expand-only).
3. Land SRQL parser/planner/execute/translate + unit tests.
4. Land catalog, RBAC aliases, cookbook, viz metadata.
5. Add integration-test fixtures and queries.
6. Rollback is removing the entity handlers; indexes can stay.

## Open Questions

- None that block the proposal. If a later dashboard package wants
  `rollup_stats` for KEV host counts, that is a follow-up CAGG, not this
  change.
