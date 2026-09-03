## Context

Advisory data is already in CNPG:

| Table | Role | Scale |
|---|---|---|
| `platform.vulnerability_advisories` | One row per feed object (CVE / KEV entry) | ~250k current nist-nvd2 + ~5k KEV |
| `platform.advisory_coordinates` | One row per CPE / PURL / vendor_product, with CPE 2.3 components and discrete version bounds | millions |
| `platform.endpoint_vulnerability_matches` | Device × package × advisory match produced by `EndpointVulnerabilityMatcher` | fleet × packages × matching CVEs |

SRQL today can filter *installed* CPEs on `endpoint_packages` (`cpes && ARRAY[...]`) and can filter OCSF finding *events* by JSON `cve`/`cpe` keys. It cannot query the catalog or the match table.

Existing indexes that this change must use:

- `vulnerability_advisories_cve_idx` on `(cve_id)` where not null
- `vulnerability_advisories_generation_idx` on `(provider, feed_key, generation, current)`
- `advisory_coordinates_type_value_idx` on `(coordinate_type, value)`
- `advisory_coordinates_value_trgm_idx` GIN trgm on `value`
- `advisory_coordinates_vendor_product_idx` on `(cpe_vendor, cpe_product)` where vendor not null
- `endpoint_vulnerability_matches_device_status_idx` on `(device_uid, status, severity)`
- `endpoint_vulnerability_matches_priority_idx` on `(kev, exploit_available, status)`

Missing for the planned queries:

- matches by `cve_id`
- matches by `last_seen_at` (default `time:` / sort)

## Goals / Non-Goals

- Goals:
  - Three SRQL entities that map 1:1 onto the three tables, with denormalized joins so an operator does not have to issue two queries for "CPE + CVE title" or "match + package name".
  - Index-backed plans; parameterized SQL; no interpolation of CVE/CPE strings.
  - Default to *current* advisories and *active* matches so stale generations do not leak into interactive results.
  - Keep version-range evaluation in the matcher. SRQL reads the result.
- Non-goals: IOC/CTI entities, ingest/matcher rewrites, projecting NVD `raw`, downsample/CAGG, a new dashboard package.

## Decisions

### Decision: Three entities, not one joined "vulnerabilities" view

Operator questions fall into three grains:

1. Catalog: "what does NVD/KEV say about CVE-2024-1234?"
2. Coordinate: "which CPE rows does that advisory apply to, including version bounds?"
3. Exposure: "which of *our* devices currently match?"

A single wide view would either explode (one row per coordinate × device) or hide coordinates. Follow the package pattern (`endpoint_package_catalog` vs `endpoint_packages`) instead.

**Aliases** (parser, catalog, RBAC must list all of them):

| Canonical `in:` | Aliases | Not an alias |
|---|---|---|
| `vulnerability_advisories` | `advisories`, `cves`, `vulnerability_advisory` | — |
| `advisory_coordinates` | `advisory_cpes`, `cpe_coordinates` | `cpes` — too easy to confuse with installed-package CPE rollups |
| `endpoint_vulnerability_matches` | `vulnerability_matches`, `cve_matches`, `advisory_matches` | `security_findings` — that remains OCSF findings/events |

### Decision: SQL builder style is `sql_query` + `to_jsonb`, like `public_endpoints`

Diesel `table!` DSL is a poor fit for the joins (coordinates → advisories, matches → packages) and for dropping `raw` / `affected_coordinates` from the projection. Build explicit SQL with `?` binds, `SELECT to_jsonb(subq) AS payload`, the way `public_endpoints` does.

### Decision: Defaults and time columns

| Entity | Implicit filter unless overridden | `time:` maps to | Default sort |
|---|---|---|---|
| `vulnerability_advisories` | `current = true` | `published_at` | `published_at desc`, then `cve_id` |
| `advisory_coordinates` | join `vulnerability_advisories.current = true` | coordinate `inserted_at` | `cpe_vendor, cpe_product, value` |
| `endpoint_vulnerability_matches` | `status = 'active'` | `last_seen_at` | `kev desc, exploit_available desc, cvss_score desc, last_seen_at desc` |

`current:false` / `status:resolved` / `status:*` (or `include_resolved:true`) must be explicit. Do not invent a second "stale generation" mix-in.

### Decision: SRQL does not evaluate CPE version ranges

`in:advisory_coordinates cpe_vendor:nginx cpe_product:nginx` returns catalog applicability rows, including `version_start` / `version_end`. It does **not** decide whether `nginx 1.24.0-2ubuntu7` is in range. That join is already materialized as `endpoint_vulnerability_matches`. Document this in cookbook recipes so agents do not try to re-implement NVD matching in a query.

### Decision: Pivot filters on packages and devices use EXISTS

`in:endpoint_packages cve:CVE-2024-1234` and `in:devices kev:true` are EXISTS subqueries against `endpoint_vulnerability_matches` (active by default). They do not change the result grain: a package query still returns packages, a device query still returns devices.

`in:vulnerability_advisories cpe_vendor:nginx` is EXISTS against `advisory_coordinates`.

### Decision: CVE identifiers are folded to uppercase

Equality and IN lists for `cve` / `cve_id` normalize with `upper(trim(...))`. Storage is already `CVE-...`. LIKE patterns are not folded beyond ILIKE.

### Decision: Default projection omits bulky columns

Advisories: `id, provider, feed_key, advisory_id, cve_id, title, description, severity, cvss_score, cvss_vector, published_at, modified_at, kev, exploit_available, current, generation, references, metadata`.

Not projected: `raw`, `affected_coordinates`.

Coordinates additionally project joined `cve_id, title, severity, cvss_score, kev` from the advisory.

Matches project table columns plus `package_name, package_version, purl_canonical` from `endpoint_packages`, plus `epss_score`, `due_date`, `ransomware_use` lifted from `metadata` (written by `CvePriority.to_metadata/1`). Do not require a new column for those three.

### Decision: RBAC is `devices.view`

Matches are device-scoped inventory, same as `endpoint_packages`. The catalog is the same dataset the Software tab already shows to viewer-plus. Do not invent a new permission. Do not put these entities under `observability.events.view` (that is the OCSF event/finding stream) or `observability.netflow.view` (that is the IOC-match change).

Unknown-entity passthrough in `EntityAccess` is a footgun: once the parser accepts the new `in:` names, the RBAC map **must** list every alias or the HTTP/MCP path will skip the gate.

### Decision: Query bounds for the coordinate table

`advisory_coordinates` can be millions of rows. Plans:

1. Default `current = true` join so stale generations are out.
2. Always apply `LIMIT` / offset pagination (existing SRQL cursor cap).
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

Elixir migration (Ash resource `migrate? false`, so a named SQL migration):

```sql
CREATE INDEX endpoint_vulnerability_matches_cve_idx
  ON platform.endpoint_vulnerability_matches (cve_id)
  WHERE cve_id IS NOT NULL;

CREATE INDEX endpoint_vulnerability_matches_last_seen_idx
  ON platform.endpoint_vulnerability_matches (last_seen_at DESC);
```

Do not add a generated-column EPSS index in this change; `epss_score:>=0.9`
filters `metadata->>'epss_score'` and is acceptable for KEV-sized subsets. If
that path is hot after ship, follow up with a stored column.

### Decision: Stats, not rollups or downsample

`stats:count() as n by <field>` on advisories and matches. Supported group
fields: `severity`, `kev`, `exploit_available`, `provider`, `feed_key`,
`cve_id`, and on matches also `device_uid`, `status`, `confidence`.
`rollup_stats:` and `downsample` are unsupported (typed error). No new CAGG.

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
  occurrence-shaped OCSF rows; matches are stateful matcher output. Same CVE
  can appear in both for different reasons.
- **Stale matches after a package uninstall.** Matcher owns `status`; SRQL
  defaults to `active`. Operators who want history pass `status:resolved`.
- **EPSS/due date only in JSONB.** Acceptable for v1; document that
  `metadata.epss_score` and the lifted `epss_score` field are the same value.

## Migration Plan

1. Add match-table indexes (expand-only, concurrent-safe).
2. Land SRQL parser/planner/execute/translate + unit tests.
3. Land catalog, RBAC aliases, cookbook, viz metadata.
4. Add integration-test fixtures and queries.
5. Rollback is removing the entity handlers; indexes can stay.

## Open Questions

- None that block the proposal. If a later dashboard package wants
  `rollup_stats` for KEV host counts, that is a follow-up CAGG, not this
  change.
