# Withdrawn analytics architecture: preservation and reusable fixes

## Decision and preserved source

The pg_duckdb architecture is withdrawn. Preserve PR
[#488](https://github.com/carverauto/serviceradar/pull/488) and branch
`feat/analytics-store-drivers` as a reference; do not merge this implementation.
The final implementation commit is `ea774b02b22d1819285b66df413fb9e9157ace21`.
No replacement database has been selected.

Start the next PR from current `staging` and port independent fixes with their
tests. Most commits combine reusable changes with archive infrastructure or
depend on earlier changes in this branch. Do not cherry-pick the entire series.
The compatibility audit used base `13d2a60f0969c11aabfd1999e8196a43e8620ce1`;
repeat it against the next PR's actual base.

## Fixes to carry forward

Paths below are relative to the repository root. For web modules, `web` means
`elixir/web-ng/lib/serviceradar_web_ng_web`.

| Bundle | Source commits | Port boundaries |
| --- | --- | --- |
| Pending interface chart tasks survive refreshes | `d7ca1a8b11` | Four web files; this commit applied cleanly to the audited base without analytics-store dependencies. Keep the lifecycle tests and rerun them. |
| ICMP sparklines and canonical availability | `9287cfd30e`, `1a603bba83`, `ea54c128c6`, `e0cfbc151b` | Port final `web/live/device_live/{icmp_data,availability_data,availability_components}.ex`, `index_data/telemetry.ex`, `IndexRefresh`, and relevant action, async-task and Show wiring. Carry the source-selection, stale-task and pagination tests. |
| Metric history selectors | `ea54c128c6`, `e0cfbc151b`, `9bc0e3f2a3` | `web/components/metric_window_components.ex`, SRQL builder/range helpers, sysmon/interface window state and NetFlow controls. Preserve 1h/6h/24h/7d/30d/90d/custom behavior, resolved bounds and request cancellation. Keep backend routing separate. |
| Dashboard windows and remembered selections | `9bc0e3f2a3`, `b5b708cb12` | `DashboardWindowSelect.js`, hook registration/build inputs, `web/live/dashboard_live/{window,event_window,index}.ex`, data loaders and panel components. Preserve independent cookies, selected bounds, Full Screen propagation and stale-response rejection. Include the subsequent authenticated-scope fix. |
| Correct chart ranges, labels and gaps | `ea54c128c6`, `9bc0e3f2a3`, `347dacdc48`, `b5b708cb12`, `9499e28575` | Timeseries plugin/card/path/point modules, chart hooks, `user_time.js`, NetFlow chart utilities and formatter inventory/tests. Preserve requested bounds separately from sample bounds, calendar-aware labels, readable numeric axes, UTC fallback and localization after DOM replacement. The final cadence fix connects regular polling samples while preserving real gaps. |
| Remove device-list Tags column | `ea54c128c6` | Narrow change in `web/live/device_live/index_view/table.ex`; retain tags elsewhere. |
| NetFlow aggregate planning and query selection | `aeb107468f`, `ec9a6d7fb7`, `9bc0e3f2a3`, `3b2f052888` | Final Rust `query/downsample/{flow_dimensions,flow_apps}.rs`, `query/flows/activity.rs`, `query/flows/stats/{cagg,query}.rs`, and narrow registration/binding changes. Include aggregate coverage, disjoint raw edges and constant bounds for chunk pruning. Pair with the schema and bootstrap work below. |
| NetFlow page avoids unnecessary panel queries | `e0cfbc151b`, `ec9a6d7fb7`, `9bc0e3f2a3` | `web/live/log_live/{netflow_runtime,netflow_summary,netflow_activity}.ex` and narrow Index wiring. Preserve per-view loading and visible query failures, with tests. |
| Transaction-local JIT setting | `ea774b02b2` | Only the `jit=off` addition in `elixir/web-ng/lib/serviceradar_web_ng/srql.ex::session_setup_sql/0` and focused tests in `test/app_domain/srql_plan_cache_mode_test.exs`. Preserve transaction-local behavior, commit/rollback cleanup and existing timeout/plan-cache settings. Exclude the surrounding archive batch API and NIF work. |
| Sweep summary timing | `ea54c128c6` | Narrow Go agent changes in `metric_envelope.go` and `push_loop_sweep_results.go`, with synthetic tests: emission-time timestamps and one summary per chunked report. Review independently of archive ingestion. |
| Inventory reconciliation freshness race | `6d4633c4fb` | `elixir/serviceradar_core/lib/serviceradar/inventory/endpoint_inventory_ingestor.ex`; derive directives from the locked freshness state. Review as a separate correctness fix. |

Availability must preserve the final behavior, not just the early ICMP patch:

- Unknown historical gaps remain unknown.
- Explicit status gauges determine availability; latency is not a substitute.
- A selected observer remains authoritative, including its failures.
- With fallback selection, an available observer wins for that interval.
- Changing source cancels prior work, and stale results cannot overwrite it.
- Periodic device-list refreshes must not discard pending sparklines.

## Timescale aggregate dependencies

The PostgreSQL NetFlow improvements are useful independently of DuckDB, but
require coordinated schema, backfill, query and test changes:

- Final migration `20260916003000_repair_flow_traffic_refresh_policies.exs`
  repairs hourly/daily refresh windows.
- Migration `20260916030000_create_flow_app_dimensions_cagg.exs` adds lossless
  application/port dimensions. Preserve NULL port values and sampling semantics.
- `ServiceRadar.Jobs.BootstrapFlowAppDimensionsWorker` fills closed hours
  newest-first with durable checkpoints. Preserve safe partial-coverage queries,
  retry behavior and regular refresh-policy coexistence.
- Preserve `flow_app_dimensions_cagg_test.exs`,
  `jobs/bootstrap_flow_app_dimensions_worker_test.exs`, their test-inventory and
  Bazel disposition entries, and Rust boundary/filter/parity tests.
- The audited base lacks `QueryPlan.dialect`. Port PostgreSQL behavior directly
  without introducing DuckDB infrastructure merely to satisfy dialect guards.
- Preserve the application classification guard in `flows/activity.rs`: enabled
  rules using source port or source/destination CIDR require raw queries because
  the aggregate dimensions cannot evaluate those rules.

Keep raw drill-down behavior correct for filters the aggregates cannot answer.
Revalidate migration compatibility with existing installations before shipping.

## Excluded from the follow-up fix PR

Archive driver selection, hybrid routing, pg_duckdb execution, file manifests,
archive batches/outbox, compaction, expiry, recovery tooling, dedicated head
provisioning and archive-specific NIF batching remain on this reference branch.
Their continued presence here is not approval to reuse the architecture.

Do not archive-apply this change or `add-tiered-telemetry-offload`. Independent
compression work remains separate. The next storage proposal should retain the
product requirements: fast dashboards; optional object storage for OSS;
configurable per-dataset history; a one-year hosted archive-retention default;
and JetStream-first ingestion through the single persistence owner. These
requirements do not select a replacement database or prove fleet capacity.

## Validation and limits

The final implementation passed the full repository `make test` gate: 274 tests
passed and two platform-specific tests were skipped. The preserved
[BuildBuddy run](https://carverauto.buildbuddy.io/invocation/d8a6e03a-4cb7-4942-8c43-3fb91d05e0a4)
is evidence for that source snapshot, not for a future extracted patch.

Other completed checks included 741 SRQL library tests, strict Clippy, synthetic
Timescale comparisons for aggregate boundaries/NULLs/sampling, cookie and chart
tests, and transaction-local setting cleanup tests. Rerun the relevant checks
after extraction; copied code does not inherit the original validation.

GitHub checks were not all green at withdrawal: the aggregate CodeQL check
reported a failure and other checks were still pending. No cause was established
as part of preservation; closure is not a CI approval.

The newest rebuilt images were not deployed. Final live 7/30/90-day acceptance,
browser preference verification and remaining hot-history restoration were
canceled, so this work must not be described as production-ready or accepted.

## Operational boundary

Closing the PR does not undo an existing installation's schema, writer mode,
query routing or stored data. The running deployment was left unchanged, and
the unexecuted image-pin update was canceled separately. Existing archive data
and recovery checkpoints must be retained until a deliberate migration plan
verifies hot-data coverage and defines rollback. Do not delete the analytics
head, bucket or manifests as part of closing this PR.

Local operational scratch files and the independent untracked compression
draft are not part of the source snapshot. They remain local; captured values
must not become repository fixtures or documentation.
