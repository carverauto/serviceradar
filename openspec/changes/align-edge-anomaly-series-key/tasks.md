# Tasks — edge↔central `series_key` alignment

## 0. Decision / preconditions
- [ ] 0.1 Confirm the exact `TimeseriesSeriesKey.build/1` field set is the agreed canonical composite (`metric_type, metric_name, partition, agent_id, device_id, target_device_ip, if_index`) and that both metric and anomaly must key through it. (design.md)
- [ ] 0.2 Capture the current-state evidence as a fixture: one SNMP series whose metric keys on `sr:<target>` while its anomaly keys on `agent_id` (the demo `agent-dusk01` case), so the test has a concrete before/after.

## 1. Edge: already carries the target (trace-confirmed — no code change)
- [x] 1.1 The agent stamps `target_device_ip` on every SNMP metric and the addon attributes to it (not `agent_id`); the verdict emits `source_identity.target_device_ip` (4-way trace, design.md). No agent/addon change is in scope.
- [ ] 1.2 Verify the *deployed* demo addon is the version with `snmp_target_identity` — the demo's `agent-dusk01`-attributed anomalies suggest a stale image. (Deploy is operational, not code; the central fix is required regardless of edge attribution because the edge carries the raw target IP, not the canonical `sr:`.)

## 2. Central: resolve to the canonical device + canonicalize the `series_key` (the fix)
- [ ] 2.1 In `causal_signals.ex`, resolve the anomaly's device to the canonical `sr:` device by **`target_device_ip`** (the polled switch IP from `source_identity`) — the same lookup the metric pipeline uses to assign `sr:<target>` — for SNMP, instead of resolving off the raw `device_uid` (which is an IP/agent, not a canonical device). Locate/extend the existing re-key at `:1410`.
- [ ] 2.2 Where `series_key` is taken verbatim from `payload["anomaly"]["series_key"]` (`:1282/1290/1311`), when it is a structured edge key (`structured_series_key?/1`, `:1390`) recompute it as `TimeseriesSeriesKey.build/1` over the canonical fields (`metric_type, metric_name, partition, agent_id, device_id=sr:<target>, target_device_ip, if_index`) — the SAME composite the metric uses.
- [ ] 2.3 Keep the edge's `v2|…` key as debug-only metadata and log when it disagrees with the derived key (mirror `metric_envelope.ex` `maybe_record_series_hint`).
- [ ] 2.4 Degradation guard: if the canonical device cannot be resolved (no `target_device_ip`, no matching device), leave the series_key un-joined (current behavior) — NEVER coin a colliding key. Anchor every derived key on the attested `agent_id`.

## 3. The parity gate (definition of done)
- [ ] 3.1 Parity test: build the canonical key from a metric's resource fields and from the matching anomaly verdict's `source_identity` for the SAME SNMP series; assert `TimeseriesSeriesKey.build(metric) == TimeseriesSeriesKey.build(anomaly)` AND that the persisted anomaly `series_key` equals the metric's. This is the precondition the disposition stack asserts — now proven.
- [ ] 3.2 Negative test: a series whose target cannot be resolved produces a non-colliding (un-joined) key, not a wrong one.

## 4. Verify + close the loop
- [ ] 4.1 Verify on demo (read-only): after deploy, a new SNMP anomaly's `series_key` matches the corresponding `timeseries_metrics.series_key` for the same series (the `agent-dusk01` → `sr:<target>` case from 0.2 now joins).
- [ ] 4.2 Note in the disposition proposals that the series-key precondition is now proven (was "asserted, not proven" in `add-anomaly-finding-disposition`).
- [ ] 4.3 Unblock `#4288` (stale-alert auto-resolve): with aligned keys, a series's liveness is queryable from `timeseries_metrics.series_key`, so the orphaned-alert sweep can key on real series liveness instead of `anomaly_open` recency.
