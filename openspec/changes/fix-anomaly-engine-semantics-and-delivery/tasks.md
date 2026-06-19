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
- [ ] 5.1 Add production persistence for seasonal confirmation counters keyed by source, series, day-of-week, and hour-of-day.
- [ ] 5.2 Load persisted counters before NIF evaluation and write returned counters after each pass.
- [ ] 5.3 Add restart/multi-run tests showing `confirm_slots > 1` can surface a sustained seasonal breach.
- [ ] 5.4 Add cleanup/TTL for stale seasonal state keys.

## 6. Configuration
- [ ] 6.1 Decide and implement the operator tuning path for edge spike detector params.
- [x] 6.2 Validate edge add-on assignment config with `min_samples <= window_size`.
- [ ] 6.3 Add seeder/reconciler tests showing default anomaly profiles carry intended detector knobs or docs/UI clearly split the knobs.
- [ ] 6.4 Update operator docs for the final tuning ownership model.

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
- [ ] 9.3 Distinguish EOF from transport errors in `grpc.go` stream loops and emit stream-loss diagnostics.
- [x] 9.4 Base the backoff reset on run stability, not last-run duration.
- [ ] 9.5 Add Go tests for drain reconnect, breaker recovery, and stream-loss reporting.

## 10. Verdict Idempotency (F12)
- [ ] 10.1 Remove per-run wall-clock time from capacity and seasonal `event_id`/finding identity.
- [ ] 10.2 Make edge verdict `time` deterministic from the producer epoch (depends on 4.1) so `(id, time)` dedup holds on redelivery.
- [ ] 10.3 Add a dead-letter path or alert for JetStream `max_deliver` exhaustion.
- [ ] 10.4 Add tests proving redelivery and repeated worker runs converge on one finding.

## 11. Identity Partition Scoping And Correlation (F13, F14)
- [x] 11.1 Incorporate attested `partition_id` into the canonical `series_key` / finding identity.
- [x] 11.2 Escape or hash free-form producer tag/host/IP values before splicing into delimited keys (core `series_key.ex` and edge `series_key_for`).
- [x] 11.3 Scope the `InterfaceCapacity` link-speed join by `partition_id`.
- [x] 11.4 Route re-keyed edge verdicts through the central emitters' subject sanitization.
- [x] 11.5 Add tests for partition scoping, key collision resistance, and edge↔central subject parity.

## 12. Seasonal Data Feed And Semantics (F15, blocker)
- [ ] 12.1 Implement the `profile_hour_of_week` SRQL stats verb (or an equivalent bucket-profile query) producing `dow/hod/center/mad/p05/p95/bucket_count/bucket_sum/bucket_sum_sq`.
- [ ] 12.2 Make the worker fail loudly with telemetry when the profiling query returns no profile columns.
- [ ] 12.3 Emit seasonal clears; fix the zero-width bucket window (distinct started/ended).
- [ ] 12.4 Fix the Oban uniqueness key so per-run `evaluated_at` does not defeat dedup; align dow/hod bucketing to a configured time zone.
- [ ] 12.5 Add an integration test that exercises the real SRQL path end-to-end (not mock rows).

## 13. Capacity Forecast Correctness (F16)
- [x] 13.1 Fix the flow-capacity source unit label and add a threshold so it can alert.
- [x] 13.2 Guard the Holt-Winters ETA against negative `slope_per_second`.
- [ ] 13.3 Insert a gap marker instead of deleting interior points on counter wrap.
- [x] 13.4 Constrain `warning_horizon_seconds <= horizon_seconds`.

## 14. Detector Numeric Safety (F17)
- [x] 14.1 Replace the unconditional zero-variance breach with a magnitude/floor-aware rule that does not fire for floor-less counter rates; widen the near-zero stddev guard beyond `f64::EPSILON`.
- [x] 14.2 Make `sample_stats` defined for windows of length 0/1 (no NaN/inf/panic).
- [x] 14.3 Keep Welford sample count consistent with logical samples (handle non-finite explicitly).
- [ ] 14.4 Pin a `confirm_slots` definition shared by edge and central seasonal confirmation.

## 15. Config Reconciliation (F18)
- [x] 15.1 Decide and document the role of `window_duration_seconds` for the count-based edge window (map or scope away).
- [x] 15.2 Remove or correctly map the `mem` runtime alias to a real tier/gauge class.
- [ ] 15.3 Align edge 32-bit counter-wrap salvage (modulus / unknown `counter_width`) with central's per-sample-max behavior.

## 16. Operability (F19)
- [ ] 16.1 Add a scoring-liveness/health surface (verdict throughput, tracked-series vs cap, last-scored time).
- [ ] 16.2 Emit a signal when cgroup resource enforcement is absent or a limit write failed.

## 17. Performance At Scale (F20, extends F8)
- [ ] 17.1 Batch causal-prediction inserts (`insert_all` + `ON CONFLICT DO NOTHING`); drop the per-row existence SELECT.
- [ ] 17.2 Stream worker history instead of `List.flatten`-ing the full result set into memory.
- [ ] 17.3 Reduce per-reading allocations in the counter normalization path.
- [x] 17.4 Document or revisit F8's O(window) per-sample envelope under the F9 eviction changes.

## 18. Live-Confirmed Edge Delivery Fixes (F21-F24, demo 2026-06-19)
- [ ] 18.1 F21: stop the seeder/assignment from writing empty-string `""` for unset numeric add-on params (omit, or send number/null).
- [x] 18.2 F21: make the Rust `AddonConfig` deserializer coerce empty/absent optional knobs to defaults instead of rejecting `""` ("invalid type: string, expected u64").
- [ ] 18.3 F21: add a migration/repair to clear empty-string params already persisted for mis-seeded agents (`agent-k8s-cp2-worker1`, `k8s-agent`) and recover their `circuit_open` add-ons.
- [x] 18.4 F22: make the add-on `Shutdown` return promptly (abort the scoring task, close the feed) so the manager stops SIGKILLing it; test that stop completes within the grace window.
- [ ] 18.5 F23: place the add-on in `serviceradar-addons.slice` with the declared `memory.max`/`tasks.max`, and emit a health signal when enforcement is absent (ties F19).
- [ ] 18.6 F24: unify device identity (uid + hostname) and series-key host component across sysmon and SNMP edge findings on the canonical re-key path (ties F4/F13).
- [ ] 18.7 Add an end-to-end smoke test that fires `sysmon.debug_spike` and asserts one open finding (not one-per-sample-per-core), sample-time `time`, and coherent device identity.

## 19. Verification
- [ ] 19.1 Run `sfw cargo test -p serviceradar-anomaly-addon -p serviceradar-anomaly-core -p serviceradar-causal-disposition`.
- [ ] 19.2 Run `sfw cargo test -p serviceradar-srql` if the seasonal profiling verb is implemented in SRQL.
- [ ] 19.3 Run `go test ./go/pkg/agent/addon/...` (and update bazel BUILD deps for any new test files/imports).
- [ ] 19.4 Run focused core-elx tests for status handler, causal signals, seasonal disposition, capacity forecasting, and anomaly profile seeding.
- [ ] 19.5 Run `./scripts/elixir_quality.sh --project elixir/serviceradar_core` if the implementation changes shared core-elx behavior broadly.
- [ ] 19.6 Run native add-on manifest/version gates if add-on package metadata or Rust add-on sources change.
- [ ] 19.7 Re-run the live `sysmon.debug_spike` trace in demo and confirm the F1/F3/F6/F12/F15/F21-F24 behaviors are resolved.
