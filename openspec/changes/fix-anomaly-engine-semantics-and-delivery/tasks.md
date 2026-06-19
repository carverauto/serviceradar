## 1. Proposal
- [x] 1.1 Audit edge add-on, core-elx routing, seasonal disposition, and config propagation.
- [x] 1.2 Validate this OpenSpec change with `openspec validate fix-anomaly-engine-semantics-and-delivery --strict`.
- [x] 1.3 Review and approve proposal before implementation.

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
- [x] 19.1 Query `device_uid_exact` first as a bare indexed equality; stop trying `agent_id`/`host_id` first (which seq-scan the OCSF hypertable).
- [x] 19.2 Drop the capacity `resource_key '%<id>%'` leading-wildcard ILIKE; add a btree index on capacity `resource_id`.
- [x] 19.3 Run the anomaly and capacity loads concurrently (Task.async) instead of sequential `load_first`; short-circuit empty candidates.
- [x] 19.4 Lower the anomaly/capacity query `limit` and project only rendered fields (not full metadata/raw_data/unmapped).

## 20. Operator-Actionable Anomaly/Capacity Rows (F26)
- [x] 20.1 Make finding rows and capacity rows clickable (`phx-click` + uid) opening a detail modal.
- [x] 20.2 Prefer `finding_info.title` for the human title; demote the raw `verdict.reason` to a sub-line.
- [x] 20.3 Render real identity: metric_name, interface_uid/if_index (for interface findings), anomaly value + score; stop showing bare `"snmp"`.
- [x] 20.4 Add `title=`/tooltip with full id and resolve a human device label for truncated ids.
- [x] 20.5 Label capacity with units/metric-type/threshold/headroom; hide or aggregate `skipped` rows; reconcile the metric_class row label vs the RED chip bucketing.

## 21. SNMP Anomaly Target Attribution (F27)
- [x] 21.1 Edge: prefer `resource.target_device_ip` for non-self SNMP polls when choosing `device_uid`/`series_key` (`addon.rs:857-862`).
- [x] 21.2 Core: for `snmp_target_poll?` rows, set the leading `device_uid` resolution candidate to the target (not the agent host) (`causal_signals.ex:1356-1357`).
- [x] 21.3 Emit `target_device_ip` at a stable top-level/anomaly path, not only under `source_identity`; add a regression test for resolved device_uid on an SNMP poll.
- [x] 21.4 Once attribution is correct, scope the web-ng device-finding query by canonical device/series instead of `agent_id`-first.

## 22. Metric Chart Fidelity (F28)
- [ ] 22.1 For per-core metrics, render per-core series (or a max-across-cores line); stop collapsing to `series=nil` avg-across-cores.
- [ ] 22.2 Offer `agg:max` (or an avg+max envelope) per bucket so short spikes are visible; make the header min/avg/max match the plotted aggregation.
- [ ] 22.3 Annotate finding timestamps/series on the chart and let a finding click focus the chart on its series/time window.

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
- [ ] 25.2 Thread `metric.unit` from the SRQL row into the panel spec and prefer it over field-name inference (`timeseries.ex:91-126,685-711`).
- [ ] 25.3 Add y ticks/gridlines/labels to NetFlow grid + BGP + stacked-area charts.

## 26. NetFlow Traffic Correctness (F32)
- [ ] 26.1 Carry `sampling_rate` into flow rows and weight every byte/packet sum by it (Total Bandwidth, Top-N, gauges, p95, subnet).
- [ ] 26.2 Divide window-sum totals by the window seconds before labeling a per-second rate (`dashboard.ex:1241-1246,1283-1302`).
- [ ] 26.3 Align the interface gauge and p95 to the selected time window; make peak vs average explicit.
- [ ] 26.4 Add tests pinning correct bandwidth math for a sampled exporter and each time window.

## 27. SNMP Counter Rendering Semantics (F33)
- [ ] 27.1 Use the counter PDU width (or SRQL native `agg:rate`) instead of guessing 32/64-bit from the `"HC"` label (`timeseries.ex:358-366`).
- [ ] 27.2 Render counter resets/gaps as no-data gaps, not `0 B/s`; drop the always-0 first sample (`timeseries.ex:319-346`).
- [ ] 27.3 Clamp only octet series to link speed; render byte-rate vs count-rate on separate axes (`timeseries.ex:335,368-376`).

## 28. Chart Finding/Threshold Annotation (F34)
- [ ] 28.1 Add an `annotations` list ({dt, label, severity}) to the timeseries panel assigns, rendered as SVG marker lines/bands via the existing time mapping.
- [ ] 28.2 Draw per-metric threshold reference lines on interface/sysmon charts.
- [ ] 28.3 Make a finding click focus/mark its time + series on the chart.

## 29. Chart Hover/Tooltip Correctness (F35)
- [ ] 29.1 Invert mouse-x with the same geometry as `idx_to_x` (8px pad + viewBox scaling) in `TimeseriesChart.js`/`TimeseriesCombinedChart.js` and `netflow_charts/util.js`.
- [ ] 29.2 Fix `NetflowGridChart` hover to map to the correct grid panel; add per-series crosshair markers; add a BGP tooltip.

## 30. Chart Gap/Error Honesty (F36)
- [ ] 30.1 Use `null` sentinels + `.defined()` so missing buckets render as breaks, not drops-to-zero (`FlowRateChart.js`, `BGPTimeSeriesChart.js:53-62`).
- [ ] 30.2 Distinguish query-error vs no-data vs disabled empty states; link empty states to the relevant SNMP/polling config.

## 31. Charted Coverage & Accessibility (F37)
- [ ] 31.1 Chart `process.count`; add per-process history/sparklines so process spikes are visible.
- [ ] 31.2 Show absolute volume alongside the NetFlow 100%-stacked view.
- [ ] 31.3 Add non-color series encoding (shape/pattern/label) for color-blind operators.

## 32. Chart Renderer Modularization (F38)
- [ ] 32.1 Break up `dashboard/plugins/timeseries.ex` (~1544 lines) into focused modules each under ~300 lines, e.g. point extraction/normalization, downsampling, counter-rate derivation, scale/units, SVG path geometry, hover/annotation, and the LiveComponent shell.
- [ ] 32.2 Do the split as a behavior-preserving refactor first (no logic change), then land the F30/F31/F33/F34/F35 fixes against the smaller modules.
- [ ] 32.3 Audit sibling oversized chart/device modules (`live/device_live/sysmon_metrics.ex`, `netflow_live/dashboard.ex`) for the same >300-line split.

## 33. Verification
- [x] 33.1 Run `sfw cargo test -p serviceradar-anomaly-addon -p serviceradar-anomaly-core -p serviceradar-causal-disposition`.
- [x] 33.2 Run `sfw cargo test -p serviceradar-srql` if the seasonal profiling verb is implemented in SRQL.
- [x] 33.3 Run `go test ./go/pkg/agent/addon/...` (and update bazel BUILD deps for any new test files/imports).
- [ ] 33.4 Run focused core-elx tests for status handler, causal signals, seasonal disposition, capacity forecasting, anomaly profile seeding, and alert generation.
- [ ] 33.5 Run web-ng tests for the device-details anomaly/capacity components, chart renderer, NetFlow/interface data layers, and JS chart hooks.
- [ ] 33.6 Run `./scripts/elixir_quality.sh --project elixir/serviceradar_core` if the implementation changes shared core-elx behavior broadly.
- [x] 33.7 Run native add-on manifest/version gates if add-on package metadata or Rust add-on sources change.
- [ ] 33.8 Re-run the live `sysmon.debug_spike` trace in demo and confirm the F1/F3/F6/F12/F15/F21-F37 behaviors are resolved (one open finding, sample-time, coherent identity, visible+annotated chart spike, correct NetFlow units, no alert storm).
