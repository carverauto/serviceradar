## 1. Proposal
- [x] 1.1 Audit edge add-on, core-elx routing, seasonal disposition, and config propagation.
- [x] 1.2 Validate this OpenSpec change with `openspec validate fix-anomaly-engine-semantics-and-delivery --strict`.
- [ ] 1.3 Review and approve proposal before implementation.

## 2. Edge Add-on Semantics
- [x] 2.1 Add per-series active anomaly state to the edge engine/checkpoint.
- [x] 2.2 Emit an anomaly-open finding only when a series transitions from inactive to confirmed anomalous.
- [x] 2.3 Emit an anomaly-clear finding when an active anomalous series returns clean.
- [x] 2.4 Suppress `pending_anomaly` from OCSF Detection Finding emission.
- [x] 2.5 Add Rust tests for confirm-slot suppression, one open per active anomaly, clear emission, and checkpoint restore of active state.

## 3. Delivery Resilience
- [x] 3.1 Replace the anomaly add-on single-use telemetry receiver with reconnect-safe broadcast/drop delivery.
- [x] 3.2 Ensure native telemetry backpressure cannot block metric-feed acknowledgement or scoring.
- [x] 3.3 Add tests for telemetry reconnect and lag/drop behavior.
- [x] 3.4 Decide whether agent-side stream drain should reconnect on stream close for native telemetry and metric-feed streams.

## 4. Core Ingestion Fidelity
- [x] 4.1 Parse causal signal timestamps from ISO8601 and Unix seconds/milliseconds/microseconds/nanoseconds.
- [x] 4.2 Recompute or overwrite anomaly `finding_info.uid`, `group_uid`, and dimensions after canonical device/series re-keying.
- [x] 4.3 Add tests proving edge add-on numeric OCSF `time` persists as sample time, not ingest time.
- [x] 4.4 Add tests proving canonical re-keying updates finding identity consistently.

## 5. Seasonal State
- [x] 5.1 Add production persistence for seasonal confirmation counters keyed by source, series, day-of-week, and hour-of-day.
- [x] 5.2 Load persisted counters before NIF evaluation and write returned counters after each pass.
- [x] 5.3 Add restart/multi-run tests showing `confirm_slots > 1` can surface a sustained seasonal breach.
- [x] 5.4 Add cleanup/TTL for stale seasonal state keys.

## 6. Configuration
- [x] 6.1 Decide and implement the operator tuning path for edge spike detector params.
- [x] 6.2 Validate edge add-on assignment config with `min_samples <= window_size`.
- [x] 6.3 Add seeder/reconciler tests showing default anomaly profiles carry intended detector knobs or docs/UI clearly split the knobs.
- [x] 6.4 Update operator docs for the final tuning ownership model.

## 7. Edge Detector State Bounds (F9)
- [x] 7.1 Apply the `max_series` cap to the `counters` map on both the live normalize path and `restore_checkpoint`.
- [x] 7.2 Add staleness eviction for `series` and `counters` keyed on `last_observed_at_unix_nano` so the cap reclaims dead series.
- [x] 7.3 Include counter-map size in the capacity-shed diagnostic.
- [x] 7.4 Add Rust tests for counter cap, staleness eviction, and that a saturated map still admits a fresh active series after eviction.

## 8. Edge Feed Task Lifecycle (F10)
- [x] 8.1 Make `stream_metric_feed` single-owner: abort/replace any prior scoring task on reopen and track the `JoinHandle`.
- [x] 8.2 Recover from a poisoned engine mutex (re-init state) instead of `expect`-panicking all future scoring.
- [x] 8.3 Add tests for feed reopen (no double-scoring / no checkpoint race) and panic recovery.

## 9. Agent Delivery Self-Healing (F11)
- [x] 9.1 Reconnect `drainTelemetry`, `drainArtifacts`, and `metricFeedLifecycle.run` with bounded backoff while the subprocess is alive.
- [x] 9.2 Re-arm the restart circuit breaker after a cooldown; surface circuit-open as a health failure.
- [x] 9.3 Distinguish EOF from transport errors in `grpc.go` stream loops and emit stream-loss diagnostics.
- [x] 9.4 Base the backoff reset on run stability, not last-run duration.
- [x] 9.5 Add Go tests for drain reconnect, breaker recovery, and stream-loss reporting.

## 10. Verdict Idempotency (F12)
- [x] 10.1 Remove per-run wall-clock time from capacity and seasonal `event_id`/finding identity.
- [x] 10.2 Make edge verdict `time` deterministic from the producer epoch (depends on 4.1) so `(id, time)` dedup holds on redelivery.
- [x] 10.3 Add a dead-letter path or alert for JetStream `max_deliver` exhaustion.
- [x] 10.4 Add tests proving redelivery and repeated worker runs converge on one finding.

## 11. Identity Partition Scoping And Correlation (F13, F14)
- [x] 11.1 Incorporate attested `partition_id` into the canonical `series_key` / finding identity.
- [x] 11.2 Escape or hash free-form producer tag/host/IP values before splicing into delimited keys (core `series_key.ex` and edge `series_key_for`).
- [x] 11.3 Scope the `InterfaceCapacity` link-speed join by `partition_id`.
- [x] 11.4 Route re-keyed edge verdicts through the central emitters' subject sanitization.
- [x] 11.5 Add tests for partition scoping, key collision resistance, and edge↔central subject parity.

## 12. Seasonal Data Feed And Semantics (F15, blocker)
- [x] 12.1 Implement the `profile_hour_of_week` SRQL stats verb (or an equivalent bucket-profile query) producing `dow/hod/center/mad/p05/p95/bucket_count/bucket_sum/bucket_sum_sq`.
- [x] 12.2 Make the worker fail loudly with telemetry when the profiling query returns no profile columns.
- [x] 12.3 Emit seasonal clears; fix the zero-width bucket window (distinct started/ended).
- [x] 12.4 Fix the Oban uniqueness key so per-run `evaluated_at` does not defeat dedup; align dow/hod bucketing to a configured time zone.
- [x] 12.5 Add an integration test that exercises the real SRQL path end-to-end (not mock rows).

## 13. Capacity Forecast Correctness (F16)
- [x] 13.1 Fix the flow-capacity source unit label and add a threshold so it can alert.
- [x] 13.2 Guard the Holt-Winters ETA against negative `slope_per_second`.
- [x] 13.3 Insert a gap marker instead of deleting interior points on counter wrap.
- [x] 13.4 Constrain `warning_horizon_seconds <= horizon_seconds`.

## 14. Detector Numeric Safety (F17)
- [x] 14.1 Replace the unconditional zero-variance breach with a magnitude/floor-aware rule that does not fire for floor-less counter rates; widen the near-zero stddev guard beyond `f64::EPSILON`.
- [x] 14.2 Make `sample_stats` defined for windows of length 0/1 (no NaN/inf/panic).
- [x] 14.3 Keep Welford sample count consistent with logical samples (handle non-finite explicitly).
- [x] 14.4 Pin a `confirm_slots` definition shared by edge and central seasonal confirmation.

## 15. Config Reconciliation (F18)
- [x] 15.1 Decide and document the role of `window_duration_seconds` for the count-based edge window (map or scope away).
- [x] 15.2 Remove or correctly map the `mem` runtime alias to a real tier/gauge class.
- [x] 15.3 Align edge 32-bit counter-wrap salvage (modulus / unknown `counter_width`) with central's per-sample-max behavior.

## 16. Operability (F19)
- [x] 16.1 Add a scoring-liveness/health surface (verdict throughput, tracked-series vs cap, last-scored time).
- [x] 16.2 Emit a signal when cgroup resource enforcement is absent or a limit write failed.

## 17. Performance At Scale (F20, extends F8)
- [x] 17.1 Batch causal-prediction inserts (`insert_all` + `ON CONFLICT DO NOTHING`); drop the per-row existence SELECT.
- [x] 17.2 Stream worker history instead of `List.flatten`-ing the full result set into memory.
- [x] 17.3 Reduce per-reading allocations in the counter normalization path.
- [x] 17.4 Document or revisit F8's O(window) per-sample envelope under the F9 eviction changes.

## 18. Live-Confirmed Edge Delivery Fixes (F21-F24, demo 2026-06-19)
- [x] 18.1 F21: stop the seeder/assignment from writing empty-string `""` for unset numeric add-on params (omit, or send number/null).
- [x] 18.2 F21: make the Rust `AddonConfig` deserializer coerce empty/absent optional knobs to defaults instead of rejecting `""` ("invalid type: string, expected u64").
- [x] 18.3 F21: add a migration/repair to clear empty-string params already persisted for mis-seeded agents (`agent-k8s-cp2-worker1`, `k8s-agent`) and recover their `circuit_open` add-ons.
- [x] 18.4 F22: make the add-on `Shutdown` return promptly (abort the scoring task, close the feed) so the manager stops SIGKILLing it; test that stop completes within the grace window.
- [x] 18.5 F23: place the add-on in `serviceradar-addons.slice` with the declared `memory.max`/`tasks.max`, and emit a health signal when enforcement is absent (ties F19).
- [x] 18.6 F24: unify device identity (uid + hostname) and series-key host component across sysmon and SNMP edge findings on the canonical re-key path (ties F4/F13).
- [ ] 18.7 Add an end-to-end smoke test that fires `sysmon.debug_spike` and asserts one open finding (not one-per-sample-per-core), sample-time `time`, and coherent device identity.

## 19. Device-Details Panel Performance (F25)
- [x] 19.1 Query canonical `source_device_uid` first via the indexed device-UID equality path; stop trying `agent_id`/`host_id` before the canonical lookup.
- [x] 19.2 Drop the capacity `resource_key '%<id>%'` leading-wildcard ILIKE; add a btree index on capacity `resource_id`.
- [x] 19.3 Run the anomaly and capacity loads concurrently (Task.async) instead of sequential `load_first`; short-circuit empty candidates.
- [x] 19.4 Lower the anomaly/capacity query `limit`.
- [ ] 19.5 Project only rendered fields once SRQL supports row projection for events/capacity rows (avoid fetching full metadata/raw_data/unmapped).

## 20. Operator-Actionable Anomaly/Capacity Rows (F26)
- [x] 20.1 Make finding rows and capacity rows clickable (`phx-click` + row index) opening a detail modal.
- [x] 20.2 Prefer `finding_info.title` for the human title; demote the raw `verdict.reason` to a sub-line.
- [x] 20.3 Render real identity: metric_name, interface_uid/if_index (for interface findings), anomaly value + score; stop showing bare `"snmp"`.
- [x] 20.4 Add `title=`/tooltip with full id on truncated resource/series identity.
- [x] 20.5 Resolve a human device label for truncated device/resource ids when the row only carries uid-like values.
- [x] 20.6 Label capacity with units/metric-type/threshold/headroom; hide or aggregate `skipped` rows.
- [x] 20.7 Reconcile the metric_class row label vs the RED chip bucketing.

## 21. SNMP Anomaly Target Attribution (F27)
- [x] 21.1 Edge: prefer `resource.target_device_ip` for non-self SNMP polls when choosing `device_uid`/`series_key` (`addon.rs:857-862`).
- [x] 21.2 Core: for `snmp_target_poll?` rows, set the leading `device_uid` resolution candidate to the target (not the agent host) (`causal_signals.ex:1356-1357`).
- [x] 21.3 Emit `target_device_ip` at a stable top-level/anomaly path, not only under `source_identity`; add a regression test for resolved device_uid on an SNMP poll.
- [x] 21.4 Once attribution is correct, scope the web-ng device-finding query by canonical device/series instead of `agent_id`-first.

## 22. Metric Chart Fidelity (F28)
- [ ] 22.1 For per-core metrics, render per-core series (or a max-across-cores line); stop collapsing to `series=nil` avg-across-cores.
- [ ] 22.2 Offer `agg:max` (or an avg+max envelope) per bucket so short spikes are visible; make the header min/avg/max match the plotted aggregation.
- [x] 22.3 Annotate finding timestamps/series on the chart and let a finding click focus the chart on its series/time window.

## 23. Anomaly & Capacity Alerting (F29, gated on F1/F12/F17)
- [x] 23.1 Add `alert_generator.ex` handling for anomaly findings: alert only on confirmed anomaly-open and clear transitions, never on `pending_anomaly` or per-sample.
- [x] 23.2 Dedup/coalesce per canonical series with a cooldown/suppression window so one ongoing condition is one alert.
- [x] 23.3 Add capacity alerting on a real exhaustion-ETA crossing the warning horizon, not on every `projected` re-emit.
- [x] 23.4 Map detector/finding severity to alert severity; exclude floor-less counter false-criticals until F17 lands.
- [x] 23.5 Add tests proving no alert storm: a sustained anomaly yields one open + one clear, and pending/duplicate findings produce no alert.

## 24. Chart Aggregation Fidelity (F30)
- [x] 24.1 Replace `limit_points` stride decimation with min/max-envelope (LTTB) downsampling so extremes survive (`timeseries.ex:629-655`).
- [x] 24.2 Stop interpolating/box-smoothing measured `bytes_per_sec` series (`timeseries.ex:528-595`); interpolate visually only.
- [ ] 24.3 Split per-series: disk by `mount_point`, CPU by core/`series_key`; offer `agg:max` alongside avg; compute header min/max from raw rows.
- [ ] 24.4 For counter/interface charts offer finer buckets or a raw window so microbursts are visible.

## 25. Chart Scale & Units (F31)
- [x] 25.1 Scale Y to the data band (min..max + padding) instead of a hardcoded 0 floor; add an opt-in log scale (`timeseries.ex:186-221,378-384`).
- [x] 25.2 Thread `metric.unit` from the SRQL row into the panel spec and prefer it over field-name inference (`timeseries.ex:91-126,685-711`).
- [x] 25.3 Add y ticks/gridlines/labels to NetFlow grid + BGP + stacked-area charts.

## 26. NetFlow Traffic Correctness (F32)
- [ ] 26.1 Carry `sampling_rate` into flow rows and weight every byte/packet sum by it (Total Bandwidth, Top-N, gauges, p95, subnet).
- [x] 26.2 Divide window-sum totals by the window seconds before labeling a per-second rate (`dashboard.ex:1241-1246,1283-1302`).
- [x] 26.3 Align the interface gauge and p95 to the selected time window; make peak vs average explicit.
- [ ] 26.4 Add tests pinning correct bandwidth math for a sampled exporter and each time window.

## 27. SNMP Counter Rendering Semantics (F33)
- [x] 27.1 Use the counter PDU width (or SRQL native `agg:rate`) instead of guessing 32/64-bit from the `"HC"` label (`timeseries.ex:358-366`).
- [x] 27.2 Render counter resets/gaps as no-data gaps, not `0 B/s`; drop the always-0 first sample (`timeseries.ex:319-346`).
- [x] 27.3 Clamp only octet series to link speed; render byte-rate vs count-rate on separate axes (`timeseries.ex:335,368-376`).

## 28. Chart Finding/Threshold Annotation (F34)
- [x] 28.1 Add an `annotations` list ({dt, label, severity}) to the timeseries panel assigns, rendered as SVG marker lines/bands via the existing time mapping.
- [x] 28.2 Draw per-metric threshold reference lines on interface/sysmon charts.
- [x] 28.3 Make a finding click focus/mark its time + series on the chart.

## 29. Chart Hover/Tooltip Correctness (F35)
- [x] 29.1 Invert mouse-x with the same geometry as `idx_to_x` (8px pad + viewBox scaling) in `TimeseriesChart.js`/`TimeseriesCombinedChart.js` and `netflow_charts/util.js`.
- [x] 29.2 Fix `NetflowGridChart` hover to map to the correct grid panel; add per-series crosshair markers; add a BGP tooltip.

## 30. Chart Gap/Error Honesty (F36)
- [x] 30.1 Use `null` sentinels + `.defined()` so missing buckets render as breaks, not drops-to-zero (`FlowRateChart.js`, `BGPTimeSeriesChart.js:53-62`).
- [x] 30.2 Distinguish query-error vs no-data vs disabled empty states; link empty states to the relevant SNMP/polling config.

## 31. Charted Coverage & Accessibility (F37)
- [x] 31.1 Chart `process.count`; add per-process history/sparklines so process spikes are visible.
- [x] 31.2 Show absolute volume alongside the NetFlow 100%-stacked view.
- [x] 31.3 Add non-color series encoding (shape/pattern/label) for color-blind operators.

## 32. Chart Renderer Modularization (F38)
- [ ] 32.1 Break up `dashboard/plugins/timeseries.ex` (~1544 lines) into focused modules each under ~300 lines, e.g. point extraction/normalization, downsampling, counter-rate derivation, scale/units, SVG path geometry, hover/annotation, and the LiveComponent shell.
- [ ] 32.2 Do the split as a behavior-preserving refactor first (no logic change), then land the F30/F31/F33/F34/F35 fixes against the smaller modules.
- [ ] 32.3 Break up the other oversized chart/dashboard/flow modules into focused files under ~300 lines each (behavior-preserving): `netflow_live/visualize.ex` (~4532), `dashboard_live/data.ex` (~3148), `dashboards/authored.ex` (~1551), `dashboard_live/index.ex` (~1544), `netflow_live/dashboard.ex` (~1478), `device_live/sysmon_metrics.ex`, `device_live/flow_components.ex`.

## 33. Flow Sampling-Rate End-to-End (F39)
- [ ] 33.1 Collector: capture NetFlow v9/IPFIX sampling IEs (incl. options/sampler records) per exporter; add a configured per-exporter fallback (esp. v5); set `sampling_rate` on the proto.
- [ ] 33.2 Core: persist `sampling_rate` to a real flow column (stop `zero_to_nil`-dropping it into the `unmapped` blob).
- [ ] 33.3 Scale bytes/packets by `sampling_rate` in flow queries (and rebuild/relearn the hierarchical continuous aggregates to store scaled volume).
- [ ] 33.4 Normalize sFlow byte layer (L2 vs L3) and per-sample packet count; add a test that sampled exporters report true volume.

## 34. Dashboard Query Safety (F40)
- [x] 34.1 Parameterize/escape authored dashboard variable values; never interpolate them into the SRQL grammar; validate against the variable's declared type/allowed set.
- [x] 34.2 Enforce a default time window and a max `LIMIT` on every authored panel query.
- [x] 34.3 Add tests proving a view-only user cannot rewrite a panel's collection/filters via a variable.

## 35. Authored-Panel Readout Correctness (F41)
- [x] 35.1 Fix the Stat/Count trend to compare true first/last by enforced time sort (correct arrow + delta sign).
- [x] 35.2 Fix KPI sparklines to select the most-recent buckets (`ORDER BY bucket DESC LIMIT N` then reverse).
- [x] 35.3 Compute pivot/stat aggregations server-side over the full result, not the 250-row client-truncated set; stop type-inferring from a 100-row sample.

## 36. Dashboard Table & Topology Plugins (F42)
- [x] 36.1 Table plugin: server-side pagination/cap + sort; preserve authored SELECT column order; format numeric cells (units/separators).
- [x] 36.2 Topology: cap nodes with an explicit "+N more" truncation indicator; use a stable node id (not `phash2` of the raw map).

## 37. NetFlow Aggregation & Attribution (F43)
- [x] 37.1 Scope the interface bandwidth gauge to the interface (not whole-exporter bytes); label peak vs average correctly.
- [x] 37.2 Compute Sankey "Other" from the full result set (don't drop the tail at the DB); keep sort on limited timeseries.
- [ ] 37.3 Canonicalize bidirectional flows (Top Conversations, device ingress+egress) to avoid double-counting; unify talker scoping with the device tab.
- [x] 37.4 Filter reverse-DNS/Geo enrichment by expiry; distinguish chart query-error from no-traffic.

## 38. Flow Ingest Defaults (F44)
- [x] 38.1 Use NULL (not 0) for directional byte/packet counts a protocol does not carry; divide bps/pps by covered data span, not the full wall-clock window.

## 39. Dashboard Load Performance (F45)
- [ ] 39.1 Parallelize the ~20 dashboard data queries + ~30 schema probes (concurrent, not sequential).
- [ ] 39.2 Split `dashboard_live/data.ex` (~3148 lines) per §32.3.

## 40. Data Retention Coverage (F46)
- [x] 40.1 Verify a retention policy exists for every high-volume hypertable (`otel_traces`, `ocsf_network_activity` only got one 2026-06-19); add any missing.
- [x] 40.2 Track that the F1/F12/F17/F39 write-flood fixes reduce `ocsf_events`/`capacity_forecasts`/flow growth.
- [ ] 40.3 (ops, separate) Resolve the failing CNPG scheduled base backup (Longhorn throughput) so there is a recovery point.

## 41. Verification
- [x] 41.1 Run `sfw cargo test -p serviceradar-anomaly-addon -p serviceradar-anomaly-core -p serviceradar-causal-disposition`.
- [x] 41.2 Run `sfw cargo test -p srql profile_hour_of_week -- --nocapture` for the implemented SRQL seasonal profiling verb (`serviceradar-srql` is not the Cargo package name).
- [x] 41.3 Run `go test ./go/pkg/agent/addon/...` (and update bazel BUILD deps for any new test files/imports).
- [x] 41.4 Run focused core-elx tests for status handler, causal signals, seasonal disposition, capacity forecasting, anomaly profile seeding, alert generation, and flow ingest.
- [ ] 41.5 Run web-ng tests for device-details anomaly/capacity, chart renderer, NetFlow/interface data layers, JS chart hooks, dashboard authoring, and the table/topology plugins.
- [x] 41.6 Run `./scripts/elixir_quality.sh --project elixir/serviceradar_core` if the implementation changes shared core-elx behavior broadly.
- [ ] 41.7 Run `sfw cargo test -p serviceradar-flow-collector` if collector sampling changes land.
- [ ] 41.8 Run native add-on manifest/version gates if add-on package metadata or Rust add-on sources change.
- [ ] 41.9 Re-run the live `sysmon.debug_spike` trace + a sampled-flow check in demo and confirm F1/F3/F6/F12/F15/F21-F46 behaviors are resolved (one open finding, sample-time, coherent identity, visible+annotated chart spike, correct sampled NetFlow units, safe dashboard variables, no alert storm).

## 42. NetFlow Cache-Refresh Full-Scan CPU (F47) — fj #4096
_From the 2026-06-19 demo CNPG/core CPU investigation (`pg_stat_statements` on primary `cnpg-23`)._
- [ ] 42.1 Replace the recurring `SELECT DISTINCT sampler_address, ocsf_payload #>> '{connection_info,input_snmp|output_snmp}'` over raw `platform.ocsf_network_activity` (`netflow_interface_cache_refresh_worker.ex` ~L158-180 `input_q`/`output_q` + `netflow_exporter_cache_refresh_worker.ex`) with an incrementally-maintained `(sampler, interface_index)` dimension or a TimescaleDB continuous aggregate. **#1 CPU consumer: ~4.9s/call, 22% of DB time; recurs hourly and grows with the hypertable.**
- [ ] 42.2 Stopgap: tighten the worker `since` window (the interface set is stable) + add a supporting index for the time bound.
- [ ] 42.3 Secondary observability-query CPU (triage/track): `INSERT INTO logs` 9.2% (32.7k calls), `refresh_device_inventory_rollups()` 3.4% (8045 calls), DIRE `stale_to_active`/`mac_to_active` ~1s ×1444 each, and `netflow_provider_cidrs` join called **741,215×** (cheap each but a hot per-row loop — batch/cache).

## 43. Topology Apache AGE Query Frequency (F48) — fj #4097
- [ ] 43.1 Cache the topology graph result (per scope) + invalidate on mutation instead of re-running the `MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)` cypher per LiveView render/poll (`topology/runtime_graph.ex`, `graph.ex`). **#2 CPU consumer: 187,455 cypher calls = 19.8% of DB time.**
- [ ] 43.2 Add AGE indexes for the hot paths (a `Device.id` vertex index + a `CANONICAL_TOPOLOGY` edge index) and debounce the LiveView topology refresh.

## 44. CI Action Flood (ops/infra, separate) — fj #4098
- [ ] 44.1 (repo-wide, not anomaly-specific — flagged here per request) Add `concurrency:` groups with `cancel-in-progress` keyed on workflow+ref, and de-dup `push` vs `pull_request` triggers, in `.forgejo/workflows/*.yml` — ~900 runs flooding the act_runners (full `build`/`lint`/`test-go`/`interop`/`gitleaks` matrix ×2 events per stacked-PR merge), amplified by the stack relinearization.

## 45. StatusHandler endpoint_inventory {:results_update} Crash-Loop (F49) — fj #4136
_From the 2026-06-20 demo RCA (9-agent workflow + adversarial verification, high confidence). `ServiceRadar.StatusHandler` crash-loops ~30–35s (45×/24min, only the advisory-lock-owning core pod) — a synchronous `GenServer.call({:results_update}, 30_000)` to a slow endpoint_inventory ingest times out. Root cause is an **uncaught `GenServer.call` in a hot cluster singleton with equal nested 30s budgets**, amplified by the CNPG write contention tracked in §42/§43 (do NOT duplicate that DB-CPU work here)._
- [ ] 45.1 **URGENT stopgap:** wrap StatusHandler's `GenServer.call` at `status_handler.ex:130` in `try/catch :exit` (mirroring the gateway `status_processor.ex:285-287` and queue `endpoint_inventory_ingestor_queue.ex:130-134`), returning `{:error, :results_router_timeout}`. Removes the crash class + mailbox-loss-on-restart with zero timeout retuning. Crash loop is **active on demo**.
- [ ] 45.2 **Root-cause:** make the endpoint_inventory results path asynchronous (gateway `cast`, or `enqueue` + reply `:ok` + ack-on-completion) so the singleton `StatusHandler`/`ResultsRouter` never block synchronously. `ack_result_status?` (`status_processor.ex:324-327`) is the switch. Removes both the crash class AND the head-of-line serialization of all agents/services; needs an async-ack contract (don't silently drop on later ingest failure).
- [ ] 45.3 Decouple the equal nested 30s budgets — lower inner `ingest_timeout_ms` (`config.exs:188`, e.g. 20_000) below the outer call so the queue's clean `{:error, :endpoint_inventory_ingest_queue_timeout}` fires first. **Do NOT raise the outer/gateway timeout** (aggravates singleton HOL). Stopgap only — inferior to 45.1.
- [ ] 45.4 **Bound/cancel the in-flight ingest transaction** (a `statement_timeout` on the `Repo.transaction`, or task-kill on queue-timeout). Currently a queue timeout abandons the caller's wait but the Task keeps running → after 45.1/45.3 the crash loop becomes a pool-stall + gateway retry storm. No existing fix covers this.
- [ ] 45.5 Cheap idempotency/short-circuit in core **before** `build_context`/`maybe_upload`/`Repo.transaction` (`endpoint_inventory_ingestor.ex:36-102`), covering **both** `(agent_id, package_set_hash)`-matches-current + unchanged/`upload_already_acknowledged` (16/45 crashes) **and** `not_scanned`/`package_count==0` (29/45). Core has no dedup gate today (`upload_already_acknowledged` is agent-side only).
- [ ] 45.6 Move the `apply_hash_freshness`/noop decision (`ingestor.ex:52`) before the transaction reads/writes so an unchanged scan skips the upsert/ocsf-insert/artifact-replace/promote_current writes.
- [ ] 45.7 Index `endpoint_inventory_scans(agent_id, last_scan_at)` (or rewrite `existing_scan_device_uid`, `ingestor.ex:860-870`, onto the `[:agent_id,:current]` path) to remove the unbounded agent-scoped sort in `build_context`.
- [ ] 45.8 Per-agent fairness + load-shedding on the ingest queue (one agent can't monopolize concurrency-4 / 256-pending); surface `:endpoint_inventory_ingest_queue_full` as a fast gateway-buffered reply.
