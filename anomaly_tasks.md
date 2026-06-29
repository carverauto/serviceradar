1. [x] Checkpoint the spec cleanup
   - Kept the current OpenSpec correction.
   - Did not add back UASB naming to the implemented peak-profile code.
   - `profile_hour_of_week_peak` is treated as robust peak context, not a fake methodology.
   - Verified with:
     - `openspec validate add-anomaly-finding-disposition --strict`
     - `openspec validate retire-uasb-causal-disposition --strict`
     - `openspec validate align-edge-anomaly-series-key --strict`
     - `sfw cargo test -p srql profile_hour_of_week -- --nocapture`

2. [x] Finish CPU anomaly semantics
   - Inspected edge CPU output and confirmed the edge emits episode start/end, peak value/time, and confirmation metadata.
   - Short CPU spikes do not become confirmed anomalies unless they satisfy completed evaluation slots.
   - Added/kept synthetic CPU coverage for recurring spikes, one-off short spikes, prolonged high CPU, and low-value false positives.
   - The modal and chart annotations distinguish episode peak, emitted finding/confirmation time, episode window, and clear time.
   - Verified with:
     - `sfw cargo test -p serviceradar-anomaly-addon cpu -- --nocapture`
     - `SERVICERADAR_ALLOW_DB_FREE_TESTS=1 mix test test/phoenix/live/device_live/sysmon_metrics_test.exs test/phoenix/live/device_live/anomaly_capacity_components_test.exs --trace`

3. [x] Implement robust peak disposition only after that
   - No UASB.
   - No `Uncertain<T>`.
   - Implemented a deterministic `deep_causality_core::CausalFlow` robust peak-profile kernel.
   - Report-only by default with invariant tests for poison bounds, low-n inflation, cold/over-dispersed/ceiling pass-through, asymmetric safety, and leaky counter decay.
   - Verified with:
     - `sfw cargo test -p serviceradar-anomaly-disposition peak_profile -- --nocapture`

4. [x] Then fix SNMP attribution
   - SNMP interface anomalies resolve to the polled network device, not the polling agent.
   - Resolution is keyed on `(device_id, metric_name, if_index)`, not `series_key`.
   - Unresolved SNMP targets are withheld rather than shown on the agent.
   - Verified with:
     - `SERVICERADAR_ALLOW_DB_FREE_TESTS=1 mix test test/serviceradar/event_writer/processors/causal_signals_test.exs --trace`

5. [x] Then tackle capacity projection sanity
   - Negative and >100% percent projections are not rendered as physical forecast values.
   - The Rust model preserves raw projections only as diagnostics, while bounded percent outputs clamp to `[0, 100]`.
   - The worker no longer rejects steep but valid percent trends as "implausible"; it keeps the threshold ETA and bounded display value.
   - Physically impossible input percent samples split the series as gaps before fitting, so bad source data cannot poison the trend.
   - Verified with:
     - `SERVICERADAR_ALLOW_DB_FREE_TESTS=1 mix test test/serviceradar/observability/capacity_forecasting/worker_test.exs --trace`
     - `sfw cargo test -p serviceradar-anomaly-disposition capacity -- --nocapture`
