# Tasks — canonical device-identity alignment for anomalies

## 0. Decision / preconditions (done)
- [x] 0.1 Establish the edge is correct (agent stamps `target_device_ip` + tags; addon attributes to target; 100% of SNMP metric rows carry `target_device_ip` + `device_id=sr:<target>`). No agent/addon change.
- [x] 0.2 Establish the metric `series_key` is the wrong join target: not reproducible from stored fields (6 component sets tried), hashed with `device_id` empty (B1), folds in ingestion tags (M3). Disposition already groups by `device_id`.
- [x] 0.3 Establish the canonical join key is `(device_id, metric_name, if_index)` and that `anomaly_detection_device_uid` already resolves SNMP via `target_device_ip` + `DeviceCorrelation`.

## 1. Root cause (RESOLVED): stale addon + one unmerged refinement
- [x] 1.1 Empty `device.uid` is NOT a central code gap. The central resolver (`anomaly_detection_device_uid`, `e9c249798`) is correct AND deployed (in `4c4a76341`). The defect is upstream: the **deployed addon on the agents is stale** (`serviceradar-anomaly-addon` v0.1.1, built Jun 18 20:15) and predates BOTH SNMP-target-attribution fixes (`6cd7c4440` Jun 19 03:25, on staging; `0422ae92e` Jun 19 11:13). So the verdict carries the AGENT identity (`v2:…class=snmp…identity=agent-sr-test-pve04…`) with no `target_device_ip`, leaving the resolver nothing to resolve. Confirmed via SSH to dusk01 + the decoded v2 subject.
- [ ] 1.2 Merge `0422ae92e` ("derive SNMP target identity from tags") to staging — it is currently only on feature branches, not staging (staging has only the base `6cd7c4440`).
- [ ] 1.3 Rebuild + deploy the addon to the demo agents (so it carries `6cd7c4440` + `0422ae92e`); the central resolver already does the rest. This is a deploy, not a code change.

## 2. Key the joins on the canonical tuple (not `series_key`)
- [ ] 2.1 Audit the disposition feed + the `#4288` stale-alert liveness query: ensure both correlate anomaly↔metric on `(device_id, metric_name, if_index)`. The `profile_hour_of_week_peak` SQL already groups by `device_id`; confirm the anomaly side supplies the resolved `device_id`, `metric_name`, `if_index`.
- [ ] 2.2 Remove any reliance on `series_key` equality for anomaly↔metric correlation.

## 3. The parity gate (definition of done)
- [ ] 3.1 Parity test: for a known SNMP series, a resolved anomaly's `(device_id, metric_name, if_index)` equals the metric's, and a join on that tuple returns the metric's samples. Add a host-series case (M2). Resolve BOTH sides under the **same inventory snapshot** (assert they go through the one `DeviceCorrelation.resolve`) so the cache-backed resolver can't make them diverge spuriously and pass/fail by timing.
- [x] 3.2 Negative test: an SNMP anomaly whose polled device cannot be resolved is withheld instead of falling back to the polling agent (no false correlation).
- [ ] 3.3 Cutover (M4): anomalies already open at deploy are not orphaned — re-keyed in place on next evaluation, or remain resolvable by raw id.

## 4. Verify + close the loop
- [ ] 4.1 Verify on demo (read-only): after the fix/deploy, a new SNMP anomaly's resolved `device_id` is `sr:<target>` and joins `timeseries_metrics` on the canonical tuple (the `agent-dusk01` → `sr:<target>` case now correlates).
- [ ] 4.2 Note in the disposition proposals that the correlation precondition is now proven (was "asserted, not proven" in `add-anomaly-finding-disposition`), and that it joins on `device_id`, not `series_key`.
- [ ] 4.3 Unblock `#4288`: liveness keys on `(device_id, metric_name, if_index)` from `timeseries_metrics`, so the orphaned-alert sweep uses real series liveness.
