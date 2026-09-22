# Independent-fix extraction manifest

## Source and audit base

- Source implementation: `ea774b02b22d1819285b66df413fb9e9157ace21`.
- Preserved handoff: [83f0283e334030ad3083bae1f99a64546cccd14b](https://github.com/carverauto/serviceradar/blob/83f0283e334030ad3083bae1f99a64546cccd14b/openspec/changes/add-analytics-store-drivers/handoff.md).
- Proposal base: `31bae44e1215840da38035070e595b02f9481a8a`, fetched `origin/staging`.
- This manifest scopes selective ports; no code has been extracted or applied. Re-diff against the implementation PR's current base. The earlier clean-application claim for `d7ca1a8b11` was against another base and is not a current verification.

Path shorthand: `web` = `elixir/web-ng/lib/serviceradar_web_ng_web`; `web-tests` = `elixir/web-ng/test/phoenix`; `core` = `elixir/serviceradar_core/lib/serviceradar`. Test names below refer to the preserved source; new tests must use independently invented data.

## Port without analytics infrastructure

| Bundle / source commits | Selective implementation boundary | Tests and acceptance |
| --- | --- | --- |
| Pending interface work: `d7ca1a8b11` | `web/live/device_live/{device_tab_runtime,interface_runtime,show}.ex`; preserve task identities during refresh | `web-tests/live/device_live/device_tab_runtime_test.exs`; a pending load completes through background refresh, but a changed window invalidates it |
| ICMP and availability: `9287cfd30e`, `1a603bba83`, `ea54c128c6`, `e0cfbc151b` | Final `device_live/{icmp_data,availability_data,availability_components,index_refresh}.ex`, `index_data/telemetry.ex`, Index/Show/action/task wiring | `icmp_data_test`, `availability_data_test`, `availability_components_test`, `device_task_data_test`, `index_pagination_test`, `device_live_test`; explicit status, canonical failures, fallback success, unknown gaps, cancellation and stale-result rejection |
| History windows: `ea54c128c6`, `e0cfbc151b`, `9bc0e3f2a3` | `components/metric_window_components.ex`, SRQL builder/range helpers, sysmon/interface runtime state, `interface_live/{metrics_query,show}.ex`, NetFlow controls | `metric_window_components_test`, `device_metrics_runtime_test`, `interface_data_metrics_test`, `sysmon_metrics_query_test`, `interface_live_metrics_query_test`, NetFlow range/time-window tests; 1h/6h/24h/7d/30d/90d/custom changes both query and display |
| Dashboard preferences: `9bc0e3f2a3`, `b5b708cb12` | `assets/js/hooks/DashboardWindowSelect.js`, hook registration and BUILD inputs; `dashboard_live/{window,event_window,index}.ex`, loader and panel changes | Hook test, `dashboard_live/{window,events_panel,dashboard_layout}_test`, `dashboard_live_test`; independent cookies, valid default for malformed cookie, reload, Full Screen map propagation, authorized query scope, stale results |
| Bounds/axes/gaps: `ea54c128c6`, `9bc0e3f2a3`, `347dacdc48`, `b5b708cb12`, `9499e28575` | `dashboard/plugins/timeseries.ex` and chart-card/path/point/series modules; JS timeseries/NetFlow hooks; `utils/user_time.js`; formatter inventory | Timeseries component/points/counter-gap tests; affected JS hook tests, chart-util and user-time tests; requested bounds separate from sample bounds, calendar labels, UTC fallback, timezone after DOM replacement, final polling-cadence correction |
| Device-list Tags column: `ea54c128c6` | Only `device_live/index_view/table.ex` header/cell/import/colspan edits | Device list render with and without composite verdict column; tags remain available elsewhere |
| Per-view NetFlow loaders: `e0cfbc151b`, `ec9a6d7fb7`, `9bc0e3f2a3` | `log_live/{netflow_runtime,netflow_summary,netflow_activity}.ex` and narrow Index wiring; avoid replacing the whole Index module | `netflow_runtime_test`, `netflow_summary_test`, `netflow_activity_test`, `netflows_test`; inactive panels do not load, errors remain errors, authenticated scope survives |
| Transaction-local JIT: `ea774b02b2` | Only `elixir/web-ng/lib/serviceradar_web_ng/srql.ex::session_setup_sql/0` JIT setting | `test/app_domain/srql_plan_cache_mode_test.exs`; commit/rollback/no pool leakage; keep timeout/plan-cache settings; exclude archive batch APIs/NIF |
| Sweep summary correctness: `ea54c128c6` | `go/pkg/agent/{metric_envelope,push_loop_sweep_results}.go`; report emission timestamp and one summary across chunks, retain original sweep timestamp as metadata | `metric_envelope_test.go` plus chunked-report regression; all host results preserved, no repeated report totals |
| Locked inventory freshness: `6d4633c4fb` | `core/inventory/endpoint_inventory_ingestor.ex`; decide directive from row-locked transition, not preflight snapshot | Add/retain synthetic concurrent freshness test proving exactly one transition emission and no obsolete directive; separately review locking and transaction behavior |

The last two entries were checked against the actual diff: summary gauges use the envelope emission time; later chunks omit summary metric fields while retaining status JSON; freshness emission compares the locked pre-update state to the post-update state. This does not constitute runtime validation.

## New UI work, absent from #488

Render favorited-interface traffic, inbound-packet and outbound-packet charts as individual full-width rows, stacked vertically, with interface identity on every chart. Starting points: `web/live/device_live/interface_components.ex`, `web/dashboard/plugins/timeseries.ex` and its card/combined-card renderers. Preserve favorites, loading, windows, counters and genuine gaps. Verify synthetic desktop and narrow layouts, including long labels and large numeric axes. No live screenshot or device identifier becomes a fixture.

## Conditional PostgreSQL compatibility bundle

Keep this separate from UI and StarRocks. Port only if a retained CNPG path needs it:

- Commits `aeb107468f`, `ec9a6d7fb7`, `9bc0e3f2a3`, `3b2f052888`: Rust `query/downsample/{flow_dimensions,flow_apps}.rs`, `query/flows/activity.rs`, `query/flows/stats/{cagg,query}.rs` with narrow dispatch/bindings changes.
- Pair aggregate planning with `20260916003000_repair_flow_traffic_refresh_policies.exs`, `20260916030000_create_flow_app_dimensions_cagg.exs`, and `BootstrapFlowAppDimensionsWorker`. Never port only the query side. Check migration numbering and deployed schema first.
- Keep newest-first durable backfill, safe incomplete coverage, disjoint partial-window raw edges, constant pruning bounds, NULL ports and sampling parity. Source-port/CIDR filters or classification rules requiring absent fields must use raw data.
- Keep `flow_app_dimensions_cagg_test.exs`, `jobs/bootstrap_flow_app_dimensions_worker_test.exs`, Rust filter/boundary/parity tests, core source disposition inventory and Bazel integration dispositions.
- Current base `QueryPlan` has no `dialect`. Implement PostgreSQL fixes without importing DuckDB dialect guards. Shared semantics/tests can inform StarRocks; the PostgreSQL CAGG SQL is not portable.

## Explicitly excluded

Do not port archive driver selection, hybrid raw/file query routing, pg_duckdb execution, file manifests, archive outbox/batch API, compaction, expiry, dedicated analytics-head images or provisioning, recovery tooling, or archive NIF batching. Leave the independent compression draft and private recovery checkpoints intact. Backend-coupled topology/threshold/retention/retrohunt edits must be redesigned, not copied as UI dependencies.

## Validation ownership

Each later PR owns focused tests plus required `make test` before opening a PR. New core tests need disposition rows and `python3 -m unittest build/contracts/ci_heavy_gate_contract_test.py`. Source snapshot evidence is historical only; no final live acceptance occurred. Integration parity requires synthetic data and real supported databases; browser acceptance includes canceled requests, errors, sparse history, preference reloads and both viewport sizes.
