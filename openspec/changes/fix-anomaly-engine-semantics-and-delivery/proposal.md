# Change: Fix anomaly engine semantics and delivery

## Why
The edge anomaly add-on and core-elx anomaly ingestion path now own short-term
spike detection, central seasonal disposition, and alert surfacing. A grounded
audit found several correctness and operability gaps that can generate
pre-confirmation findings, lose clear transitions, mis-time persisted findings,
leave canonical identity inconsistent, stop delivery after stream reconnects,
and make seasonal confirmation ineffective when confirm slots exceed one.

## What Changes
- Emit edge spike findings only on confirmed anomaly-open and anomaly-clear
  transitions; do not persist `pending_anomaly` as an OCSF Detection Finding.
- Track active anomaly state per edge series so clears can be emitted and
  duplicate open findings are suppressed while a series remains anomalous.
- Make native telemetry delivery reconnect-safe and lossy-by-contract: a dropped
  telemetry client must not permanently disable future verdicts or backpressure
  the metric-feed scoring loop.
- Normalize causal anomaly/capacity timestamps from ISO8601, Unix milliseconds,
  microseconds, or nanoseconds instead of falling back to ingest time for numeric
  OCSF `time` fields.
- Recompute or overwrite anomaly `finding_info.uid` and dimensions after
  core-elx canonical re-keying so `device_uid`, `series_key`, and finding UID
  remain coherent.
- Persist central seasonal confirmation counters per `(source, series_key, dow,
  hod)` so multi-slot confirmation survives Oban runs and node restarts.
- Project operator anomaly settings into edge add-on assignment/profile params,
  or explicitly mark edge-only knobs as assignment-managed, so the Settings UI
  does not imply tuning that the add-on ignores.
- Tighten config validation so `min_samples <= window_size` and invalid edge
  detector settings cannot silently disable scoring.

A deep multi-agent audit (2026-06-18) added F9-F20 (see `design.md`). The change
also:
- Bound and staleness-evict both edge detector maps (`series` and `counters`),
  cap counters at restore, and report counter-map size in capacity-shed
  diagnostics (F9).
- Make the edge metric-feed a single-owner task that aborts/replaces a prior task
  on reopen, and recover from a poisoned engine mutex instead of dying (F10).
- Make agent-side delivery self-healing: reconnect telemetry/metric-feed/artifact
  drains with backoff while the add-on is alive, re-arm a circuit-broken add-on
  after a cooldown, and stop swallowing stream-loss diagnostics (F11).
- Make verdict identity idempotent: remove per-run wall-clock time from event
  identity, fix the numeric-timestamp parse so `(id, time)` dedup works on
  redelivery, and add a dead-letter/alert for max-deliver exhaustion (F12).
- Scope canonical anomaly identity and the capacity link-speed join by
  `partition_id`, and escape/hash free-form producer values before splicing them
  into delimited series/finding keys (F13).
- Route edge re-keyed verdicts through the same subject sanitization the central
  emitters use so edge and central findings for one series correlate (F14).
- Implement the seasonal profiling data feed (the `profile_hour_of_week` SRQL verb
  or an equivalent bucket-profile query), fail loudly when it returns no profile
  columns, emit seasonal clears, and fix the zero-width bucket window, Oban
  uniqueness key, and UTC bucketing (F15, blocker).
- Fix capacity-forecast dead paths and math (flow `bps` mislabel + missing
  threshold, negative-slope ETA, interior counter-wrap deletion, warning-horizon
  bound) (F16).
- Make the detector numerically safe: no unconditional zero-variance breach
  (especially for floor-less counter rates), defined stats for short windows,
  honest Welford sample counts, and a spec-level `confirm_slots` definition (F17).
- Reconcile config models across core/edge/SRQL (`window_duration_seconds`, the
  `mem` alias, counter-wrap salvage) (F18).
- Add an end-to-end scoring-liveness/enforcement-applied health surface so silent
  failure is observable (F19).
- Batch the causal-prediction inserts and remove per-verdict/per-reading hot-path
  costs on the verdict spine and workers (F20, extends F8).

A live end-to-end trace in the `demo` namespace (2026-06-19, see `design.md`)
confirmed delivery works on 11/12 agents and that an injected CPU spike scores and
persists end to end, but surfaced four new live issues and confirmed F1/F3/F6/F12/
F15/F17 in production. The change also:
- Stop writing empty-string `""` numeric add-on params, coerce empty/absent optional
  knobs to defaults in the Rust config layer, and repair already-bricked
  (`circuit_open`) agents (F21 — two agents are dead today from this).
- Make the add-on shut down promptly so reconcile/restart does not SIGKILL it or
  corrupt the baseline (F22, the F10 fix in practice).
- Actually enforce the add-on's declared resource slice/limits instead of running it
  unbounded in the base-agent cgroup, and signal when enforcement is absent (F23).
- Unify device identity (uid + hostname) and the series-key host component across
  sysmon and SNMP edge findings (F24).

A live device-details UI/chart/alerting triage (2026-06-19, see `design.md`) added
F25-F29. The change also:
- Fix the device-details panel load (query the indexed `device_uid` first, drop the
  leading-wildcard ILIKE, index capacity `resource_id`, run anomaly + capacity
  concurrently, trim limits/projection) (F25).
- Make anomaly/capacity rows operator-actionable: clickable drill-down, human title,
  metric/interface/value identity instead of bare `"snmp"`, tooltips/human labels for
  truncated ids, and a readable capacity column with units/threshold (skip the
  `skipped`-row noise) (F26).
- Attribute SNMP-polled anomalies to the polled device (edge prefers
  `target_device_ip`; core stops passing the agent-host `device_uid` for
  `snmp_target_poll?`; UI scopes by canonical device) (F27).
- Make device metric charts show the per-core, short-duration spikes the detector
  scores (per-core/max series + `agg:max`/envelope), reconcile header stats, and
  annotate findings on the chart (F28).
- Make `alert_generator.ex` handle anomaly + capacity findings, transition-gated and
  deduped (sequenced after F1/F12/F17 so it cannot storm) (F29).

A 7-surface chart-UX + SNMP rendering audit (2026-06-19, see `design.md`) added
F30-F37: the chart layer systematically hides the signal the engine scores. The
change also:
- Preserve extremes when downsampling/aggregating (min/max envelope, per-series/
  per-core/per-mount split, finer counter buckets); stop interpolating measured
  samples (F30).
- Scale axes to the data band with optional log, and label axes from the metric
  unit instead of the field name (F31).
- Fix NetFlow traffic correctness: apply the sampling-rate multiplier and divide
  windowed totals by the window before labeling a per-second rate (F32).
- Fix SNMP counter rendering: derive rates from PDU width / native `agg:rate`,
  render wrap/reset as gaps not fabricated spikes or zeros, clamp only octet series
  (F33).
- Add a chart annotation layer for findings/thresholds (F34); fix hover/tooltip
  x-alignment and add crosshairs (F35); render gaps/errors honestly (F36); chart
  collected-but-unshown signal and add non-color encoding (F37).
- Break the chart/dashboard/flow god-modules (`timeseries.ex`, `visualize.ex`,
  `dashboard_live/data.ex`, `authored.ex`, …) into <~300-line modules (F38).

A flow-pipeline + dashboard-authoring end-to-end audit (2026-06-19, see `design.md`)
added F39-F46. The change also:
- Carry the flow sampling rate end to end (collector populates it for NetFlow too,
  core persists it to a column, queries + continuous aggregates scale by it) (F39).
- Close the authored-dashboard variable injection / viewer authz bypass and bound
  authored queries (F40).
- Fix authored-panel readouts (reversed trend, oldest-bucket sparklines,
  client-truncated aggregations) (F41); fix the table/topology plugins (pagination,
  column order, node truncation) (F42).
- Fix NetFlow aggregation/attribution (interface-scoped gauge, full-set Sankey
  "Other", bidirectional canonicalization, enrichment expiry) (F43); flow ingest
  directional NULLs and partial-window rates (F44).
- Parallelize dashboard load + split the data god-module (F45).
- Verify retention coverage for all high-volume hypertables and confirm the
  write-flood fixes cut DB growth (F46).

A 9-subsystem bug hunt (mapper, sweep/scan, topology, MTR, SRQL engine + query
modules, UI) added F47-F55 (51 verified bugs). The change also:
- Mapper: dispatch ifXTable so ifName/ifAlias populate; connect SNMP once (FD leak)
  (F47); paginate UniFi clients/devices fetches (F48); fix SYN scanner attribution +
  per-scan stat reset (F49).
- Topology: escape Cypher literals against LLDP/CDP/ifAlias injection; preserve
  parallel links; prune reverse stale edges (F50).
- MTR: compute path RTT from the destination hop (not MAX over hops) so transit hops
  don't fabricate `:degraded_path` signals (F51).
- SRQL: fix the two parser/time DoS panics, add stable pagination tie-breakers, and
  fix `discovery_sources` overlap vs contains-all and `!=`/`not like` NULL semantics
  (F52, F53).
- UI: fix bulk-edit "Apply tags" (actor/scope), batch the settings count N+1, and
  bound the unbounded select-all fetch (F54).
- Break up the round-2 oversized files (Go/Rust/Elixir) into <~300-line modules (F55).

## Impact
- Affected specs: `edge-architecture`, `observability-signals`
- Affected code: `rust/anomaly-addon` (engine state bounds, feed task lifecycle,
  counter path), `rust/anomaly-core` (`stats.rs`/`detector.rs` numeric guards),
  `rust/causal-disposition` (Holt-Winters slope), `rust/srql` (seasonal profiling
  verb), `go/pkg/agent/addon` (`manager.go`/`metric_feed.go` reconnect + breaker
  recovery, `resource_limits_linux.go` enforcement signal), `go/pkg/addon/grpc.go`
  (stream-loss diagnostics), `elixir/serviceradar_core/.../status_handler.ex`,
  `.../event_writer/processors/causal_signals.ex` (idempotent identity, batched
  insert, timestamp parse), `.../observability/seasonal_disposition`,
  `.../observability/capacity_forecasting`,
  `.../observability/anomaly_detection/series_key.ex`,
  `.../observability/anomaly_config_runtime.ex`, anomaly add-on profile/config
  seeders, `.../monitoring/alert_generator.ex` (anomaly/capacity alerting), web-ng
  device-details (`.../live/device_live/anomaly_capacity_components.ex`,
  `anomaly_capacity_data.ex`, `sysmon_metrics.ex`, `interface_data.ex`, `show.ex`),
  the shared chart renderer (`.../dashboard/plugins/timeseries.ex`, `table.ex`,
  `topology.ex`), the JS chart hooks (`assets/js/hooks/charts/*`,
  `assets/js/netflow_charts/util.js`), NetFlow dashboards
  (`.../live/netflow_live/dashboard.ex`, `visualize.ex`), the flow ingest +
  collector (`rust/flow-collector`, `.../event_writer/processors/flows.ex`, flow
  caggs), dashboard authoring (`.../live/authored_dashboard_live/*`,
  `.../dashboards/authored.ex`, `.../live/dashboard_live/data.ex`), SRQL
  capacity/event/flow indexes and counter-rate path, TimescaleDB retention
  coverage, and focused tests.
