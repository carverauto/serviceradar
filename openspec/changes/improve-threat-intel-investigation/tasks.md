## 1. Proposal And Approval

- [ ] 1.1 Review this change with the owners of `add-alienvault-otx-integration`,
  `add-cti-signal-coverage`, `improve-attributed-flow-investigation`, and SRQL.
- [ ] 1.2 Confirm the documented match-count semantics against representative
  production data and the current dashboard queries.
- [x] 1.3 Approve the proposal before implementation begins.

## 2. Query Boundary And Current-Match Read Model

- [x] 2.1 Add a project-owned threat-intel investigation query module that pages
  live `IpThreatIntelCache` endpoint matches and resolves individual active
  `ThreatIntelIndicator` rows without per-row queries.
- [ ] 2.2 Return explicit fields for cache evaluation/expiry and indicator
  identity/source/label/severity/confidence/validity; attach source-object context
  only when the relationship is unambiguous.
- [x] 2.3 Keep current cache matches and `OTXRetrohuntFinding` evidence as distinct
  result kinds and labels.
- [ ] 2.4 Add deterministic keyset pagination and bounded source, indicator,
  observed-IP, severity, freshness, and status filters.
- [ ] 2.5 Run `EXPLAIN (ANALYZE, BUFFERS)` on production-sized fixtures and add only
  the supporting live-cache/index migration proven necessary by the plan.
- [x] 2.6 Fix match metric naming so distinct endpoints and
  endpoint-to-indicator memberships are never reported as flow occurrence counts.
- [x] 2.7 Return explicit timeout/query errors instead of converting errors into
  empty result sets.

## 3. SRQL Threat Intel Surface

- [x] 3.1 Add `ThreatIntelMatches` to the SRQL entity parser, plan/query dispatch,
  schema/model projection, visualization metadata, and web-ng catalog.
- [x] 3.2 Implement `in:threat_intel_matches` filters, sorts, limits, and keyset
  pagination for the documented first-increment fields.
- [x] 3.3 Add `threat_matched`, `threat_source`, `threat_indicator`,
  `threat_observed_ip`, and `threat_severity` filters to both `in:flows` and
  `in:attributed_flows`.
- [ ] 3.4 Project bounded source/destination threat summaries without multiplying
  one flow into multiple result rows.
- [x] 3.5 Require/default a bounded time range for interactive threat-aware flow
  queries and route longer searches through retrohunt.
- [x] 3.6 Parameterize every threat filter and reject unsupported operators, sort
  fields, cursors, or unbounded requests with a typed SRQL error.
- [x] 3.7 Add catalog autocomplete/examples for threat matches, normal flows, and
  attributed flows.

## 4. Threat Intel Investigation UI

- [x] 4.1 Add `/security/threat-intel` inside the existing authenticated
  `live_session :require_authenticated_user` and authorize mount and all events
  with `observability.netflow.view` because the route exposes NetFlow evidence.
- [x] 4.2 Build a paginated current-match list with explicit loading, empty, stale,
  timeout, and retry states.
- [x] 4.3 Add a selectable detail view for endpoint, indicator, provider context,
  severity/confidence, validity, cache freshness, and available historical
  evidence.
- [x] 4.4 Add URL-backed filters and `View flows` / `View attributed flows` pivots
  that preserve endpoint, indicator/source, and time state.
- [ ] 4.5 Add separate inventory and retrohunt evidence views without presenting
  imported-only IOCs as local sightings.
- [x] 4.6 Change the dashboard Threat Intel summary body to open the investigation
  route; retain a separate `Manage` command to settings and preserve accessible
  keyboard/focus behavior.
- [x] 4.7 Replace settings-page evidence samples with concise operational summaries
  and links to investigation, while leaving sync, assignment, credentials, and
  manual administrative actions in settings.
- [ ] 4.8 Keep all list/detail dimensions stable across loading and dynamic content,
  and verify no text or controls overlap at desktop and mobile widths.

## 5. Remove The Independent OTX IOC Cap

- [x] 5.1 Remove `Max IOCs` from both deployment OTX settings and edge assignment
  forms, defaults, serializers, and validation messages.
- [x] 5.2 Stop passing or applying `otx_max_indicators` / `max_indicators` in the
  core OTX provider and edge OTX plugin; remove `max_indicators` skip accounting.
- [x] 5.3 Keep page size, maximum pages, request timeout, retry-attempt budget,
  wall-time budget, payload admission, and resumable cursor enforcement.
- [x] 5.4 Ensure accepted pages/results are persisted in chunks without silently
  truncating valid indicators at the old count.
- [x] 5.5 Decouple retrohunt from `otx_max_indicators`; use an internal observable
  keyset batch and persisted continuation cursor over the requested time window.
- [x] 5.6 Accept and ignore legacy `max_iocs`, `max_indicators`, and
  `otx_max_indicators` keys in stored assignments, delivered config, settings,
  and queued jobs; strip them on the next successful edit.
- [x] 5.7 Keep the old database column inert for the compatibility window and
  document the later cleanup migration rather than dropping it in the first
  rollout.
- [x] 5.8 Bump the AlienVault OTX Wasm package version and satisfy the first-party
  Wasm manifest/build/publish gates required by the repository.

## 6. Security, Performance, And Observability

- [x] 6.1 Enforce `observability.netflow.view` on the LiveView, SRQL entity, and any
  API/query endpoint; keep all mutations behind `plugins.assign`.
- [ ] 6.2 Verify that API keys, secret references, raw payloads, and unredacted
  provider errors never enter results, URLs, logs, telemetry, or rendered HTML.
- [ ] 6.3 Add query telemetry for duration, timeout, result count, and safe
  entity/filter metadata.
- [ ] 6.4 Add a regression that fails if the match list or detail view performs one
  query per row.
- [ ] 6.5 Exercise the performance acceptance fixtures and record the final query
  plans in test/runbook evidence.

## 7. Tests And Verification

- [x] 7.1 Add SRQL parser/planner/model tests for `in:threat_intel_matches` and every
  supported filter/operator/sort/error path.
- [x] 7.2 Add flow and attributed-flow tests proving identical threat filter
  semantics and no duplicate flow rows when multiple indicators match one endpoint.
- [ ] 7.3 Add Elixir data-layer tests for live/expired cache rows, overlapping CIDRs,
  missing source-object context, retrohunt separation, pagination, and timeout
  propagation.
- [ ] 7.4 Add LiveView tests for RBAC, dashboard/settings links, filters,
  pagination, match detail, both flow pivots, stale state, and query failure state.
- [x] 7.5 Add Go/plugin tests proving old cap keys are ignored, page/page-count and
  time/attempt limits remain enforced, partial cursors resume, and valid rows are
  not counted as `max_indicators` skips.
- [ ] 7.6 Add migration/rollback tests for any supporting index and the inert legacy
  settings column strategy.
- [ ] 7.7 Run `cargo fmt`, scoped SRQL Rust tests/clippy, `gofmt`, OTX Go/Bazel
  tests, focused Elixir tests, `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix`,
  and repository Wasm build gates.
- [ ] 7.8 Validate desktop and mobile behavior with Playwright screenshots and
  verify that dashboard, investigation, flow, attributed-flow, and settings links
  all preserve their intended state.
- [x] 7.9 Validate with `openspec validate improve-threat-intel-investigation --strict`.

## 8. Documentation And Rollout

- [x] 8.1 Document imported inventory vs current match vs retrohunt evidence vs
  canonical finding semantics and the exact dashboard metric definitions.
- [x] 8.2 Document SRQL threat-intel examples and the interactive time-window limits.
- [x] 8.3 Document OTX continuation behavior and clarify that the removed `Max IOCs`
  setting was never a retained-corpus cap.
- [ ] 8.4 Canary the change with an intentionally partial OTX walk, confirm cursor
  progress to completion, and compare dashboard, SRQL, and investigation counts.
- [ ] 8.5 Monitor query timeouts, OTX memory, payload rejection, cursor stalls, and
  match freshness through one normal sync interval before broader rollout.
