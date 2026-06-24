# Tasks — canonical device-identity alignment for anomalies

## 0. Decision / preconditions (done)
- [x] 0.1 Establish the edge is correct (agent stamps `target_device_ip` + tags; addon attributes to target; 100% of SNMP metric rows carry `target_device_ip` + `device_id=sr:<target>`). No agent/addon change.
- [x] 0.2 Establish the metric `series_key` is the wrong join target: not reproducible from stored fields (6 component sets tried), hashed with `device_id` empty (B1), folds in ingestion tags (M3). Disposition already groups by `device_id`.
- [x] 0.3 Establish the canonical join key is `(device_id, metric_name, if_index)` and that `anomaly_detection_device_uid` already resolves SNMP via `target_device_ip` + `DeviceCorrelation`.

## 1. Root-cause the empty `device.uid` (the load-bearing unknown)
- [ ] 1.1 Demo shows 100% of last-3h anomalies have an empty resolved `device.uid`. Determine why: (a) deployed build predates `anomaly_detection_device_uid`, (b) `DeviceCorrelation.resolve` misses for these (cache/inventory gap), or (c) the resolved uid is computed but not written to the field the finding/disposition reads. Pin to a line.
- [ ] 1.2 If (a) stale deploy: confirm current-code behavior in a test (an SNMP verdict with `target_device_ip` resolves to `sr:<target>`); the live fix is a deploy, tracked separately.
- [ ] 1.3 If (b)/(c) code gap: fix so the resolved canonical `device_id` is persisted on the finding as a **queryable field** (not only in metadata), type-agnostically (review M2 — SNMP and host series).

## 2. Key the joins on the canonical tuple (not `series_key`)
- [ ] 2.1 Audit the disposition feed + the `#4288` stale-alert liveness query: ensure both correlate anomaly↔metric on `(device_id, metric_name, if_index)`. The `profile_hour_of_week_peak` SQL already groups by `device_id`; confirm the anomaly side supplies the resolved `device_id`, `metric_name`, `if_index`.
- [ ] 2.2 Remove any reliance on `series_key` equality for anomaly↔metric correlation.

## 3. The parity gate (definition of done)
- [ ] 3.1 Parity test: for a known SNMP series, a resolved anomaly's `(device_id, metric_name, if_index)` equals the metric's, and a join on that tuple returns the metric's samples. Add a host-series case (M2).
- [ ] 3.2 Negative test: an anomaly whose device cannot be resolved retains its raw id and joins nothing (no false correlation).
- [ ] 3.3 Cutover (M4): anomalies already open at deploy are not orphaned — re-keyed in place on next evaluation, or remain resolvable by raw id.

## 4. Verify + close the loop
- [ ] 4.1 Verify on demo (read-only): after the fix/deploy, a new SNMP anomaly's resolved `device_id` is `sr:<target>` and joins `timeseries_metrics` on the canonical tuple (the `agent-dusk01` → `sr:<target>` case now correlates).
- [ ] 4.2 Note in the disposition proposals that the correlation precondition is now proven (was "asserted, not proven" in `add-anomaly-finding-disposition`), and that it joins on `device_id`, not `series_key`.
- [ ] 4.3 Unblock `#4288`: liveness keys on `(device_id, metric_name, if_index)` from `timeseries_metrics`, so the orphaned-alert sweep uses real series liveness.
