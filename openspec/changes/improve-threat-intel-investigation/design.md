## Context

The current implementation has useful pieces but no coherent investigation
workflow:

- `DashboardLive.Index.ThreatPanel` wraps the threat summary in a link to
  `/settings/networks/threat-intel`.
- Dashboard `Matched IPs` is the count of live `ip_threat_intel_cache` rows with
  `matched = true`. The displayed `IOC Hits` is the sum of each cache row's
  `match_count`, which is the number of indicator CIDRs containing that endpoint,
  not the number of matching flows.
- The settings LiveView shows at most eight current cache rows, twelve retrohunt
  findings, and twenty-five indicators. Those rows are not investigation links,
  and the route requires the administrative `plugins.assign` permission.
- `ThreatIntelIndicator` stores the indicator CIDR, source, label, severity,
  confidence, and validity timestamps. `ThreatIntelSourceObject` preserves
  provider context when the importer supplies it. `OTXRetrohuntFinding` stores
  historical direction, time range, evidence count, bytes, and packets.
- SRQL supports `in:flows` and `in:attributed_flows`, but no threat-match entity or
  threat filter exists.
- The OTX plugin and settings expose independent indicator-count limits even
  though page size and page-count limits already bound one invocation. The stored
  inventory is cumulative, so a dashboard corpus of about 25,100 IOCs is not
  inconsistent with a smaller old per-run setting.

## Goals / Non-Goals

### Goals

- Let an operator move from dashboard count to matched endpoint, matched
  indicator, provider context, and flow evidence without visiting settings.
- Make the same evidence addressable through stable SRQL contracts and shareable
  URLs.
- Preserve honest distinctions among imported inventory, current cache matches,
  retrohunt evidence, and canonical findings.
- Keep interactive queries bounded and index-backed at large-enterprise flow and
  indicator volumes.
- Remove a redundant count control without allowing unbounded Wasm memory,
  unbounded HTTP retries, or incomplete walks that restart from page one.

### Non-Goals

- Generalize the CTI schema beyond existing IP/CIDR data in this increment.
- Introduce another durable sighting/finding table before
  `add-cti-signal-coverage` defines the cross-signal model.
- Join the full indicator corpus to the full retained flow hypertable during a
  LiveView render.

## Decisions

### Decision 1: Separate investigation from administration

`/security/threat-intel` is the operator investigation route. It lives in the
existing authenticated LiveView session and requires
`observability.netflow.view`. `/settings/networks/threat-intel` remains the
administrative route and continues to require `plugins.assign`.

The dashboard summary body navigates to investigation. A separate `Manage`
command navigates to settings. The settings page may retain operational sync and
assignment status, but evidence samples link to the investigation route rather
than becoming a second full results browser.

Alternatives considered:

- Expand the settings page into the investigation UI. Rejected because it couples
  read-only security triage to an administrative permission and mixes evidence
  with credential/configuration controls.
- Send the dashboard directly to a generic flow query. Rejected because the
  operator first needs to see which endpoint and indicator produced the summary.

### Decision 2: Use existing read models for the first increment

The first increment does not add a canonical threat finding table.
`in:threat_intel_matches` is an index-backed read contract over current live cache
rows joined to active indicator rows:

- exact endpoint state and freshness come from `ip_threat_intel_cache`;
- individual indicator identity and attributes come from
  `threat_intel_indicators` using indexed CIDR containment;
- provider/pulse metadata is attached only when an unambiguous source-object
  relationship exists;
- historical evidence remains in `otx_retrohunt_findings` and is presented as a
  distinct evidence kind.

This avoids inventing a schema that would conflict with the planned canonical
CTI sighting/finding model. The query boundary must be project-owned so the later
change can replace the backing read model without changing route or SRQL
semantics.

The UI must label cache evaluation time as `evaluated_at`, not `observed_at`.
Current cache `match_count` is `indicator_match_count`, not flow evidence. A
retrohunt row may expose `first_seen_at`, `last_seen_at`, `evidence_count`, bytes,
and packets because those values are actually persisted.

### Decision 3: Define a narrow stable SRQL contract

Add `in:threat_intel_matches` with these first-increment fields:

- `match_id` (deterministic read identity)
- `match_kind` (`current` in the initial entity; historical evidence is displayed
  separately until the canonical finding model lands)
- `observed_ip`
- `indicator_id`, `indicator`, and `indicator_type`
- `source`, `label`, `severity`, and `confidence`
- `evaluated_at`, `cache_expires_at`, `indicator_first_seen_at`,
  `indicator_last_seen_at`, and `indicator_expires_at`
- optional `source_object_id` and `source_context` only when resolvable

Support filtering/sorting on the documented fields and keyset pagination ordered
by `evaluated_at DESC, observed_ip, indicator_id`.

Add these filters to both `in:flows` and `in:attributed_flows`:

- `threat_matched:true|false`
- `threat_source:<source>`
- `threat_indicator:<ip-or-cidr>`
- `threat_observed_ip:<ip>`
- `threat_severity:<comparison>`

Threat-aware flow results expose bounded source/destination summaries such as
`src_threat_matched`, `dst_threat_matched`, source lists, maximum severity, and
indicator-match counts. They do not duplicate one flow row per matching
indicator. Individual indicators remain a detail query.

Example pivots:

```text
in:threat_intel_matches source:alienvault_otx sort:evaluated_at:desc limit:100
in:flows threat_indicator:"198.51.100.0/24" time:last_24h sort:time:desc limit:100
in:attributed_flows threat_source:alienvault_otx time:last_24h sort:time:desc limit:100
```

### Decision 4: Resolve candidate endpoints before indicator detail

`threat_matched:true` and dashboard match lists use exact primary-key lookups in
`ip_threat_intel_cache`; they do not join every flow row to every indicator.
Individual match detail then resolves the selected endpoint against the GIST CIDR
index on `threat_intel_indicators.indicator`. Source, severity, or indicator
filters are applied inside an `EXISTS`/bounded lateral plan so flow rows are not
multiplied.

Interactive flow pivots default to `last_24h`, require a bounded time predicate,
and retain the normal SRQL limit ceiling. Longer searches use the retrohunt job
path and its resumable progress rather than a synchronous browser request.

The implementation must inspect `EXPLAIN (ANALYZE, BUFFERS)` against a production-
sized fixture before adding an index. If needed, add a forward-only concurrent
index for live cache ordering/filtering. Do not add overlapping speculative
indexes.

### Decision 5: Make failure and stale state explicit

A timed-out or failed SRQL/detail query renders an error state with retry and the
failed query context. It must not render `No matches`. Expired cache rows are
excluded by default; an explicitly requested stale/debug view must label them as
stale. A missing source-object relationship displays `Provider context not
available` rather than guessing from a similarly named pulse.

### Decision 6: Remove the independent IOC cap, not safety bounds

Remove both operator-facing `Max IOCs` fields and stop applying
`max_indicators` as an independent per-invocation truncation rule in the edge OTX
plugin and core OTX provider. Valid normalized indicators must not be counted as
skipped merely because a run crossed that old value.

Safety remains layered:

- OTX/API page size is bounded.
- Maximum pages per invocation is bounded.
- Each request has a timeout and retry-attempt budget.
- The invocation has a wall-time budget.
- The emitted plugin payload has a hard protocol admission size derived from the
  bounded page contract; oversized payloads are rejected explicitly, never
  silently truncated.
- Persistence is chunked, transactional per accepted page/result, and reports
  partial failure.
- An incomplete walk persists its next-page/high-water cursor and resumes on the
  next scheduled invocation.

The page-count and page-size product therefore bounds maximum in-memory
indicators in Wasm without a second user-tunable count. Completeness progresses
over invocations until the provider cursor reports completion.

`otx_max_indicators` must also stop doubling as a retrohunt work limit. Retrohunt
uses an internal, observable keyset batch size and persisted cursor. Operators
control the time window, not a silent subset of the IOC corpus.

### Decision 7: Use a two-phase compatibility migration

For at least one release:

1. Readers accept `max_iocs`, `max_indicators`, and `otx_max_indicators` in stored
   assignments/job args/settings but ignore their values.
2. New forms and package schemas no longer display or emit the keys.
3. The next successful assignment/settings edit strips obsolete keys.
4. The existing database column may remain inert during the compatibility window
   to permit rollback; a later cleanup migration can remove it after no supported
   release reads it.

Unknown/deprecated values must not cause package import, assignment validation,
agent config delivery, or plugin startup failure. Compatibility tests cover old
configs at the minimum and maximum formerly accepted values.

### Decision 8: Apply read authorization and redaction at every entry point

The route, LiveView events, SRQL entity, and any JSON/API endpoint must require
`observability.netflow.view` through the current scope. Mutation and provider
configuration remain under `plugins.assign`. Results never include API keys,
secret references, raw archived payloads, or unredacted provider errors.

All SRQL values are parser-bound/parameterized. User-controlled indicator,
endpoint, source, cursor, and sort values are never interpolated into SQL.

## Risks / Trade-offs

- **Cache state is not a canonical finding.** Mitigation: label it as a current
  match and keep historical evidence separate until the canonical sighting model
  lands.
- **Current source-object linkage is incomplete.** Mitigation: show context only
  when unambiguous and leave many-to-many indicator/source-object modeling to the
  broader CTI change.
- **Threat filters can force expensive joins.** Mitigation: resolve cached
  endpoints first, require time bounds, use `EXISTS` rather than row-multiplying
  joins, enforce result limits, and add plan regression tests.
- **Removing a cap can expose payload-size bugs.** Mitigation: retain protocol
  admission bounds, page/request/wall-time limits, resumable cursors, and chunked
  persistence; reject rather than truncate.
- **Keeping a deprecated DB column temporarily adds clutter.** Mitigation: it is
  inert, documented, rollback-friendly, and removed in a later cleanup migration.

## Migration Plan

1. Add compatibility readers/tests for legacy IOC-cap keys and stop using the
   values.
2. Add SRQL entity and flow filters behind focused tests and query-plan fixtures.
3. Add the authenticated investigation route and dashboard link; retain the old
   settings route and all existing bookmarks.
4. Remove `Max IOCs` controls and strip obsolete keys on successful edits.
5. Roll out with query/error telemetry, compare dashboard counts with the new
   entity, and verify cursor progress across an intentionally partial OTX walk.
6. After the compatibility window, remove inert settings/schema fields in a
   separate cleanup change.

Rollback keeps the old database column and stored assignment keys, so the prior
release can resume reading them. No indicator, cache, source-object, flow, or
retrohunt data is deleted by this change.

## Performance Acceptance

- Benchmark `in:threat_intel_matches limit:100` with at least 100,000 active
  indicators and 10,000 live cached endpoints.
- Benchmark threat-filtered `in:flows` and `in:attributed_flows` over a 24-hour,
  production-sized retained-flow fixture.
- Assert query plans use the cache primary key/live-cache ordering path, the
  indicator GIST containment index, and flow time/endpoint indexes as applicable.
- Assert the LiveView loads only one bounded page and performs no per-row database
  query.
- Record query duration, timeout, returned-row count, and entity/filter names
  without logging raw credentials or full sensitive query payloads.

## Open Questions

- Should a later change rename `ip_threat_intel_cache` to a provider-neutral match
  cache after non-IP signal coverage lands? This proposal keeps the current name.
- What compatibility duration is required before removing the inert
  `otx_max_indicators` database column? The recommendation is one normal release
  window plus confirmation that no supported agent package reads the key.
