# Threat Intel Investigation Query Plans

Evidence for `openspec/changes/improve-threat-intel-investigation` tasks 2.5
and 6.5: every interactive threat-intel read was planned with
`EXPLAIN (ANALYZE, BUFFERS)` against a production-sized synthetic fixture, and
none needed a new index.

## Fixture

A scratch database on the `srql-fixtures` CNPG, holding only the five
threat-intel tables with their DDL and indexes copied from
`elixir/serviceradar_core/priv/repo/baseline/platform_schema.sql`:

| Table | Rows |
|-------|------|
| `threat_intel_indicators` | 100,000 (98k random /32, 2k /24; 5% expired) |
| `ip_threat_intel_cache` | 110,000 (10,000 live matched; the rest unmatched or expired) |
| `threat_intel_source_objects` | 30,000 |
| `otx_retrohunt_findings` | 50,000 |

All addresses are synthetic. Matched endpoints sit in `198.18.0.0/15`
(RFC 2544 benchmarking space). `ANALYZE` was run before planning.

## Results

| Read | Plan | Time |
|------|------|------|
| Current matches, first page (`list_current_matches`, recent order) | bitmap scan of `ip_threat_intel_cache_matched_index`, top-N sort of the live matched rows | 12.4 ms |
| Current matches, keyset page 2 | same plan, keyset predicate as a filter | 6.8 ms |
| Current matches by severity | same plan, top-N sort on `max_severity DESC NULLS LAST, ip` | 5.8 ms |
| Flow page endpoint lookup, 400 addresses (`endpoint_summaries`) | `ip_threat_intel_cache_pkey` index scan | 0.9 ms |
| Indicators containing one endpoint (`indicators_for_ip`) | `threat_intel_indicators_indicator_gist_idx` | 1.0 ms |
| Provider context for the detail list | GiST lookup, then one hash join over `threat_intel_source_objects` | 39.5 ms |
| Imported indicators page, one source | parallel seq scan, top-N sort | 35.6 ms |
| Provider objects page | seq scan, top-N sort | 12.9 ms |
| Retrohunt findings page | `otx_retrohunt_findings_last_seen_at_index` backward scan | 0.4 ms |
| SRQL `in:threat_intel_matches` default page | matched-cache bitmap scan, GiST probe per candidate endpoint | 30.1 ms |

## Decision

No supporting index was added. The current-match reads sort only live matched
cache rows, which the existing `matched` index isolates; at 10,000 live
matches the top-N sort is a few milliseconds. The two sequential scans
(imported indicators and provider objects) stay under 40 ms at 100,000 and
30,000 rows and run only when an operator opens those views.

Revisit if either changes:

- live matched endpoints grow past roughly 100,000, or
- the imported-indicator or provider-object views become a polling surface.

The candidate indexes are `threat_intel_indicators (source, last_seen_at DESC,
id DESC)` and `threat_intel_source_objects (source, updated_at DESC, id DESC)`.
Add one only with a new plan showing it is needed.

## Regression guards

- `ThreatIntelInvestigationDBTest` asserts the match list and the match detail
  issue the same number of queries whatever the row count, so a per-row query
  fails the test.
- Every investigation read emits
  `[:serviceradar, :threat_intel, :investigation, :query, :stop]` with the
  entity, the filter names in use, the result count, and on failure
  `error: :timeout | :invalid_input | :query_failed`. Filter values, cursors
  and raw errors are not included.

## Reproducing

1. Create a `codex_*` scratch database as described in the
   `srql-fixtures-db-tests` skill.
2. Load the five tables' `CREATE TABLE`, primary key and `CREATE INDEX`
   statements from the baseline schema.
3. Seed synthetic rows at the volumes above with `generate_series`, then run
   `ANALYZE`.
4. Run each read with `EXPLAIN (ANALYZE, BUFFERS)`, then drop the database.
