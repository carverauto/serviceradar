# Tasks — edge↔central `series_key` alignment

## 0. Decision / preconditions
- [ ] 0.1 Confirm the exact `TimeseriesSeriesKey.build/1` field set is the agreed canonical composite (`metric_type, metric_name, partition, agent_id, device_id, target_device_ip, if_index`) and that both metric and anomaly must key through it. (design.md)
- [ ] 0.2 Capture the current-state evidence as a fixture: one SNMP series whose metric keys on `sr:<target>` while its anomaly keys on `agent_id` (the demo `agent-dusk01` case), so the test has a concrete before/after.

## 1. Edge: carry the poll-target identity onto the anomaly verdict
- [ ] 1.1 Ensure the SNMP metric the addon scores carries `target_device_ip` (+ `if_index`) — the agent knows the poll target; populate/propagate it through the metric envelope so `snmp_target_identity` resolves instead of falling through to `agent_id` (`anomaly-addon/src/addon.rs:anomaly_device_uid`).
- [ ] 1.2 Stamp `agent_id`, `target_device_ip`, `if_index`, `metric_name`, `metric_type`, `partition` onto the verdict's `source_identity` so central has every composite field for re-keying (do NOT trust the edge's `v2|…` key as the canonical).
- [ ] 1.3 Edge unit test: an SNMP point with a resolvable target attributes the anomaly to the target identity, not the polling agent.

## 2. Central: canonicalize the anomaly `series_key` the same way as the metric
- [ ] 2.1 In `causal_signals.ex`, where `series_key` is taken from `payload["anomaly"]["series_key"]` (`:1282/1290/1311`), when it is a structured edge key (`structured_series_key?/1`, `:1390`) recompute it as `TimeseriesSeriesKey.build/1` over the reconciled fields (canonical `device_id` from the existing re-key at `:1410`, plus `agent_id`, `target_device_ip`, `if_index`, `metric_*`, `partition`).
- [ ] 2.2 Keep the edge's `v2|…` key as debug-only metadata and log when it disagrees with the derived key (mirror `metric_envelope.ex` `maybe_record_series_hint`), so producer drift stays observable without trusting the hint.
- [ ] 2.3 Degradation guard: if the target identity cannot be resolved, leave the series_key un-joined (current behavior) — NEVER coin a colliding key. Anchor every derived key on the attested `agent_id`.

## 3. The parity gate (definition of done)
- [ ] 3.1 Parity test: build the canonical key from a metric's resource fields and from the matching anomaly verdict's `source_identity` for the SAME SNMP series; assert `TimeseriesSeriesKey.build(metric) == TimeseriesSeriesKey.build(anomaly)` AND that the persisted anomaly `series_key` equals the metric's. This is the precondition the disposition stack asserts — now proven.
- [ ] 3.2 Negative test: a series whose target cannot be resolved produces a non-colliding (un-joined) key, not a wrong one.

## 4. Verify + close the loop
- [ ] 4.1 Verify on demo (read-only): after deploy, a new SNMP anomaly's `series_key` matches the corresponding `timeseries_metrics.series_key` for the same series (the `agent-dusk01` → `sr:<target>` case from 0.2 now joins).
- [ ] 4.2 Note in the disposition proposals that the series-key precondition is now proven (was "asserted, not proven" in `add-anomaly-finding-disposition`).
- [ ] 4.3 Unblock `#4288` (stale-alert auto-resolve): with aligned keys, a series's liveness is queryable from `timeseries_metrics.series_key`, so the orphaned-alert sweep can key on real series liveness instead of `anomaly_open` recency.
