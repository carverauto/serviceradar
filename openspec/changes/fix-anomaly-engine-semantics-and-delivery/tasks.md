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
- [x] 18.7 Add an end-to-end smoke test that fires `sysmon.debug_spike` and asserts one open finding (not one-per-sample-per-core), sample-time `time`, and coherent device identity.

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
- [x] 22.1 For per-core metrics, render per-core series (or a max-across-cores line); stop collapsing to `series=nil` avg-across-cores.
- [x] 22.2 Offer `agg:max` (or an avg+max envelope) per bucket so short spikes are visible; make the header min/avg/max match the plotted aggregation.
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
- [x] 24.3 Split per-series: disk by `mount_point`, CPU by core/`series_key`; offer `agg:max` alongside avg; compute header min/max from raw rows.
- [x] 24.4 For counter/interface charts offer finer buckets or a raw window so microbursts are visible.

## 25. Chart Scale & Units (F31)
- [ ] 25.1 Scale Y to the data band (min..max + padding) instead of a hardcoded 0 floor; add an opt-in log scale (`timeseries.ex:186-221,378-384`).
- [x] 25.2 Thread `metric.unit` from the SRQL row into the panel spec and prefer it over field-name inference (`timeseries.ex:91-126,685-711`).
- [ ] 25.3 Add y ticks/gridlines/labels to NetFlow grid + BGP + stacked-area charts.

## 26. NetFlow Traffic Correctness (F32)
- [ ] 26.1 Carry `sampling_rate` into flow rows and weight every byte/packet sum by it (Total Bandwidth, Top-N, gauges, p95, subnet).
- [x] 26.2 Divide window-sum totals by the window seconds before labeling a per-second rate (`dashboard.ex:1241-1246,1283-1302`).
- [ ] 26.3 Align the interface gauge and p95 to the selected time window; make peak vs average explicit.
- [ ] 26.4 Add tests pinning correct bandwidth math for a sampled exporter and each time window.

## 27. SNMP Counter Rendering Semantics (F33)
- [ ] 27.1 Use the counter PDU width (or SRQL native `agg:rate`) instead of guessing 32/64-bit from the `"HC"` label (`timeseries.ex:358-366`).
- [ ] 27.2 Render counter resets/gaps as no-data gaps, not `0 B/s`; drop the always-0 first sample (`timeseries.ex:319-346`).
- [ ] 27.3 Clamp only octet series to link speed; render byte-rate vs count-rate on separate axes (`timeseries.ex:335,368-376`).

## 28. Chart Finding/Threshold Annotation (F34)
- [x] 28.1 Add an `annotations` list ({dt, label, severity}) to the timeseries panel assigns, rendered as SVG marker lines/bands via the existing time mapping.
- [ ] 28.2 Draw per-metric threshold reference lines on interface/sysmon charts.
- [ ] 28.3 Make a finding click focus/mark its time + series on the chart.

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
- [x] 32.1 Break up `dashboard/plugins/timeseries.ex` (~1544 lines) into focused modules each under ~300 lines, e.g. point extraction/normalization, downsampling, counter-rate derivation, scale/units, SVG path geometry, hover/annotation, and the LiveComponent shell.
- [x] 32.2 Do the split as a behavior-preserving refactor first (no logic change), then land the F30/F31/F33/F34/F35 fixes against the smaller modules.
- [ ] 32.3 Break up the other oversized chart/dashboard/flow modules into focused files under ~300 lines each (behavior-preserving): `netflow_live/visualize.ex` (~4532), `dashboard_live/data.ex` (~3148), `dashboards/authored.ex` (~1551), `dashboard_live/index.ex` (~1544), `netflow_live/dashboard.ex` (~1478), `device_live/sysmon_metrics.ex`, `device_live/flow_components.ex`.

## 33. Flow Sampling-Rate End-to-End (F39)
- [x] 33.1 Collector: capture NetFlow v9/IPFIX sampling IEs (incl. options/sampler records) per exporter; add a configured per-exporter fallback (esp. v5); set `sampling_rate` on the proto.
- [x] 33.2 Core: persist `sampling_rate` to a real flow column (stop `zero_to_nil`-dropping it into the `unmapped` blob).
- [x] 33.3 Scale bytes/packets by `sampling_rate` in flow queries (and rebuild/relearn the hierarchical continuous aggregates to store scaled volume).
- [x] 33.4 Normalize sFlow byte layer (L2 vs L3) and per-sample packet count; add a test that sampled exporters report true volume.

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
- [ ] 37.1 Scope the interface bandwidth gauge to the interface (not whole-exporter bytes); label peak vs average correctly.
- [x] 37.2 Compute Sankey "Other" from the full result set (don't drop the tail at the DB); keep sort on limited timeseries.
- [ ] 37.3 Canonicalize bidirectional flows (Top Conversations, device ingress+egress) to avoid double-counting; unify talker scoping with the device tab.
- [ ] 37.4 Filter reverse-DNS/Geo enrichment by expiry; distinguish chart query-error from no-traffic.

## 38. Flow Ingest Defaults (F44)
- [ ] 38.1 Use NULL (not 0) for directional byte/packet counts a protocol does not carry; divide bps/pps by covered data span, not the full wall-clock window.

## 39. Dashboard Load Performance (F45)
- [x] 39.1 Parallelize the ~20 dashboard data queries + ~30 schema probes (concurrent, not sequential).
- [ ] 39.2 Split `dashboard_live/data.ex` (~3148 lines) per §32.3.

## 40. Data Retention Coverage (F46)
- [x] 40.1 Verify a retention policy exists for every high-volume hypertable (`otel_traces`, `ocsf_network_activity` only got one 2026-06-19); add any missing.
- [x] 40.2 Track that the F1/F12/F17/F39 write-flood fixes reduce `ocsf_events`/`capacity_forecasts`/flow growth.
- [ ] 40.3 (ops, separate) Resolve the failing CNPG scheduled base backup (Longhorn throughput) so there is a recovery point.

## 42. Mapper SNMP Discovery (F47)
- [x] 42.1 Dispatch ifXTable PDUs through `updateInterfaceFromOID` so ifName/ifAlias populate (not just ifHighSpeed); add a synthetic-ifXTable test.
- [x] 42.2 Connect the SNMP client exactly once per target (drop the double `Connect()`); verify FDs are released; add a leak test.
- [x] 42.3 Fix FDB MAC-to-port last-walked collapse; return `ErrNoSNMPDataReturned` for wrong-community; implement or remove `selectDensePortNeighbors`; make worker-result send not undercount progress.

## 43. UniFi / UBNT Polling (F48)
- [x] 43.1 Paginate the UniFi `/clients` fetch (no silent truncation).
- [x] 43.2 Paginate the UniFi `/devices` fetch (remove the 500/100 hard caps).
- [x] 43.3 Fix uplink `parentPortIndex` selection (port 0 valid); stop logging full response bodies at Debug; unify ctx; fix Protect WS read cap and UTF-8-safe `trimBody`.

## 44. Sweeper / SYN Scanner (F49)
- [x] 44.1 Fix SYN reply-to-port attribution after source-port reuse; reset per-scan stats counters between scans.
- [x] 44.2 Don't prune results before concurrent scan (GetStatus partial-set race); treat ICMPv6 dest-unreachable as a clean closed result; account for retry packets so they aren't silently dropped.

## 45. Topology Graph (F50)
- [x] 45.1 Escape backslashes (and audit all Cypher literal building) so attacker-controlled LLDP/CDP/ifAlias cannot inject (`graph.ex:106-110`).
- [x] 45.2 Preserve parallel links (LAG/redundant) instead of collapsing to one canonical edge; prune reverse `CONNECTS_TO` edges on one-endpoint re-report.
- [x] 45.3 Fix IPv6 device-id/IP `:`-split matching; make the Cypher read-only guard literal/comment-aware; link device-graph peer interfaces to their owning device.

## 46. MTR Consensus / Baseline / UI (F51)
- [x] 46.1 Compute path RTT from the destination hop (or a true avg), not MAX over all hops, so transit ICMP-deprioritization doesn't fabricate `:degraded_path` signals.
- [x] 46.2 Re-emit non-incident (manual/baseline) cohorts on escalation so degraded-to-outage transitions surface.
- [x] 46.3 Report the chosen class's probability as confidence; scope "Page Reachability" correctly; add a timezone indicator to MTR timestamps.

## 47. SRQL Engine Hardening (F52)
- [x] 47.1 Fix the bucket-duration multibyte-char panic (`parser.rs:550`) - char-boundary-safe parsing.
- [x] 47.2 Fix the relative-time overflow panic (`time.rs:42-50`) - checked arithmetic + validation bounds.
- [x] 47.3 Append a unique tie-breaker to downsample ORDER BY (stable pagination).
- [x] 47.4 Make empty IN/NOT-IN lists well-defined (not "all rows"); bound/authenticate cursor offset; only force LIKE when the field/op is wildcard-capable.

## 48. SRQL Query Modules (F53)
- [x] 48.1 Use array-overlap (`&&`) not contains-all (`@>`) for `discovery_sources` (and audit other list filters).
- [x] 48.2 Append a unique tie-breaker to the events and interfaces (non-latest) ORDER BY (stable pagination).
- [x] 48.3 Make `field != x` / `not like` row vs stats populations consistent re: NULLs.
- [x] 48.4 Move interface error-metric LATERAL joins after LIMIT; fix CAGG partial-bucket truncation; guard the non-ASCII stats-expression case-fold panic (`flows.rs:1340`).
- [x] 48.5 Support `other:true` for additive grouped timeseries stats (`timeseries_metrics`, `snmp`, `rperf`) and reject non-additive averages (#4021 follow-up).

## 49. UI Device List & Settings (F54)
- [x] 49.1 Fix Bulk-edit "Apply tags" to run with the actor/scope so the policy permits it (and add a test).
- [x] 49.2 Batch the SNMP-profile count N+1; make interface target-count fail-closed like device count.
- [x] 49.3 Debounce the sweep-group count; align "Run Task" enablement+targets with select-all-matching; use a real CSV parser; bound `get_all_matching_uids`; run SNMP test-connection off-process.

## 50. Oversized-File Breakups, Round 2 (F55)
- [ ] 50.1 Break up (behavior-preserving, <~300 lines): `device_live/index.ex` (3931), `go/pkg/scan/syn_scanner.go` (3831), `snmp_profiles_live/index.ex` (3596), `go/pkg/sweeper/sweeper.go` (3007), `go/pkg/mapper/snmp_polling.go` (2996), `go/pkg/mapper/discovery.go` (2741), `networks_live/index.ex` (2726), `topology_graph.ex` (2356), `diagnostics_live/mtr.ex` (2023), `ubnt_poller.go` (1728), `unifi-protect/main.go` (1385).
- [ ] 50.2 Break up the SRQL modules: `flows.rs` (2914), `parser.rs` (1306), `query/mod.rs` (1091), `interfaces.rs` (954), `events.rs` (939), `devices/filters.rs` (817), `downsample.rs` (812), `devices/stats.rs` (792).

## 51. Verification
- [x] 51.1 Run `sfw cargo test -p serviceradar-anomaly-addon -p serviceradar-anomaly-core -p serviceradar-causal-disposition`.
- [ ] 51.2 Run `sfw cargo test -p serviceradar-srql` (parser/time DoS guards, list-filter and pagination tie-breaker fixes).
- [ ] 51.3 Run `go test ./go/pkg/agent/addon/... ./go/pkg/mapper/... ./go/pkg/sweeper/... ./go/pkg/scan/...` (update bazel BUILD deps for new test files/imports).
- [ ] 51.4 Run focused core-elx tests for status handler, causal signals, seasonal disposition, capacity forecasting, anomaly profile seeding, alert generation, flow ingest, topology graph, and MTR consensus.
- [ ] 51.5 Run web-ng tests for device-details anomaly/capacity, chart renderer, NetFlow/interface data layers, JS chart hooks, dashboard authoring, table/topology plugins, device list bulk-edit, and SNMP/networks settings.
- [ ] 51.6 Run `./scripts/elixir_quality.sh --project elixir/serviceradar_core` and `--project elixir/web-ng` if implementation changes shared behavior broadly.
- [ ] 51.7 Run `sfw cargo test -p serviceradar-flow-collector` if collector sampling changes land.
- [ ] 51.8 Run native add-on manifest/version gates if add-on package metadata or Rust add-on sources change.
- [ ] 51.9 Re-run the live `sysmon.debug_spike` trace + a sampled-flow check in demo and confirm F1/F3/F6/F12/F15/F21-F55 behaviors are resolved (one open finding, sample-time, coherent identity, visible+annotated chart spike, correct sampled NetFlow units, safe dashboard variables, no alert storm, no SRQL panics).

## 52. CI Action Flood (ops/infra, separate) (F56) - fj #4098
- [x] 52.1 Add Forgejo workflow concurrency groups with `cancel-in-progress` keyed on workflow/ref for build and scan workflows, while queueing same-tag publish reruns so in-flight publishes are not cancelled.

## 53. StatusHandler endpoint_inventory {:results_update} Crash-Loop (F57) - fj #4136
_From the 2026-06-20 demo RCA: `ServiceRadar.StatusHandler` can crash-loop when the synchronous `GenServer.call({:results_update}, 30_000)` to `ResultsRouter` times out under slow endpoint_inventory ingest. The immediate fault is an uncaught `GenServer.call` exit in the singleton StatusHandler path; broader endpoint_inventory async/cancellation hardening remains separate work._
- [x] 53.1 Urgent stopgap: wrap StatusHandler's synchronous ResultsRouter call in `try`/`catch :exit`, returning `{:error, :results_router_timeout}` on timeout so the singleton does not crash and drop its mailbox.
- [x] 53.2 Root-cause: make the endpoint_inventory results path asynchronous with an ack-on-completion contract, so `StatusHandler`/`ResultsRouter` never block synchronously on ingest.
- [x] 53.3 Decouple nested timeout budgets by lowering the inner endpoint_inventory ingest timeout below the outer gateway/core call timeout; do not raise the outer timeout.
- [x] 53.4 Bound or cancel the in-flight ingest transaction on timeout so abandoned tasks cannot keep consuming the connection pool.
- [x] 53.5 Add a cheap core-side idempotency/short-circuit before `build_context`, upload, and transaction work for unchanged and empty/not-scanned payloads.
- [x] 53.6 Move hash-freshness/noop decisions before transaction reads/writes so unchanged scans skip unnecessary writes.
- [x] 53.7 Index or rewrite the agent-scoped scan lookup used by endpoint inventory context building.
- [x] 53.8 Add per-agent queue fairness/load-shedding and surface queue-full as a fast gateway-buffered reply.

## 54. NetFlow Cache-Refresh Full-Scan CPU (F58) - fj #4096
_From the 2026-06-19 demo CNPG CPU investigation (`pg_stat_statements` on primary `cnpg-23`): the recurring `SELECT DISTINCT sampler_address, ocsf_payload #>> '{connection_info,input_snmp|output_snmp}'` full-scan of `platform.ocsf_network_activity` was the #1 DB-CPU consumer (~4.9s/call, ~22% of DB time). Code stopgap landed via #4102; documented here to reconcile the task list to staging-canonical (the section was missing despite the code landing)._
- [x] 54.1 Replace the periodic re-derive with an incrementally-maintained `(sampler, interface_index)` dimension or a TimescaleDB continuous aggregate (long-term fix). **Recovered via incremental ingest-maintained interface observations.**
- [x] 54.2 Stopgap: bound the cache-refresh `since` window (30m default / 1h cap) + add the partial time-first indexes on `ocsf_network_activity`. **Landed via #4102.**
- [x] 54.3 Secondary observability-query CPU (triage/track): `INSERT INTO logs`, `refresh_device_inventory_rollups()`, DIRE `stale_to_active`/`mac_to_active`, and the `netflow_provider_cidrs` per-row join (~741k calls). **Recovered via #4153 (provider cache), #4156 (rollup batching), #4157 (DIRE lookup indexes), and #4158 (logs insert placeholders).**

## 55. Topology Apache AGE Query Frequency (F59) - fj #4097
_#2 demo DB-CPU consumer: 187k `ag_catalog.cypher` calls (~19.8% of DB time), the `MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)` runtime-graph query re-run per LiveView render/poll. Code partially landed; documented here to reconcile to staging-canonical._
- [x] 55.1 Throttle/debounce the runtime-graph refresh so bursty render/poll casts collapse to at-most-once per interval. **Landed via #4103.**
- [x] 55.2 Make each topology read cheap: the AGE property indexes (#4104) do not help the full `MATCH … CANONICAL_TOPOLOGY` traversal (it's a full edge scan + graphid join, not a point lookup); the effective fix is the graphid join index (confirm the prod AGE install exposes the btree opclass) OR a materialized/mutation-invalidated topology projection. **Recovered via rebuild-maintained SQL runtime topology projection with AGE fallback.**
