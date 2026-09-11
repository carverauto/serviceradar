## 1. Seasonal baseline delivery
- [x] 1.1 `EdgeBaselineProducer.plan_device_chunks/3`: host sources emit one full-profile chunk per device (opt `edge_baseline_max_devices_per_query`, default 1); update the batching tests.
- [x] 1.2 `build_delivery/2` keeps delivering the sources that succeeded; the summary carries `failed_sources`; the heartbeat is recorded `unhealthy` with the failed source names when any source failed.
- [x] 1.3 Delivery failure log message carries `source=` and `reason=` in the body.
- [ ] 1.4 Verify on demo after deploy: healthy heartbeat within one hour, profile params carry 168-bucket profiles, an edge payload shows `seasonal.reason` other than "no baselines configured".

## 2. Central seasonal lifecycle
- [x] 2.1 `VerdictEmitter.payload/2` stamps `timestamp` with `evaluated_at`; `reason/1` renders a sentence.
- [x] 2.2 `AnomalyEpisodeStaleCloseWorker` applies a `central_seasonal` cutoff of `max(150 min, edge window)`; `ProductionSchedule.app_env/1` exposes `SERVICERADAR_CENTRAL_SEASONAL_STALE_AFTER_MINUTES`.
- [x] 2.3 `AnomalyEpisodeRegistry` upsert does not insert an episode row for a clear that resolves no existing episode.
- [x] 2.4 `ProductionSchedule.seasonal_disposition_worker_config/1` defaults `confirm_slots` to 2; docs updated.
- [ ] 2.5 Verify on demo: no `central_seasonal` episode with `opened_at == cleared_at`; stale-closed share drops to near zero over 24 h.

## 3. Periodic-burst envelope
- [x] 3.1 anomaly-core: `ReasonContext.burst_envelope: Option<f64>`; an upward sample at or below the envelope does not breach; reason names the suppression; unit tests.
- [x] 3.2 anomaly-addon: `SeriesProfile.burst_envelope` (quantile, multiplier, lag, min_samples); computed from the lagged `raw_tail`; interface counter rates enabled by default, other classes off; per-class overrides `burst_envelope_enabled/quantile/multiplier`; `config.schema.json`; projector edge-safe key list.
- [x] 3.3 Harness scenario: recurring 2-sample bursts every 20 samples open once, never re-open; a 3x burst opens; a downward drop still breaches; existing quiet/diurnal scenarios stay green.
- [x] 3.4 Bump `addons/anomaly-addon/addon.yaml` to 0.3.7; `bash scripts/check-native-addon-version-bumps.sh` and `bazel test //build/native_addons:build_gates_test` green.

## 4. Capacity runway
- [x] 4.1 Kernel: `CapacityForecast.raw_projected_exhaustion_at_unix_micros` and `exhaustion_history_capped`; linear and Holt-Winters paths; kernel tests.
- [x] 4.2 Worker: skip reason `exhaustion_beyond_history_cap` with `raw_projected_exhaustion_at`, `history_span_seconds`, `extrapolation_cap_seconds` diagnostics; worker test; parity gate green.
- [x] 4.3 Health page: default runway query bounded to `time:last_24h`, newest row per resource, sorted by exhaustion; LiveView test.
- [ ] 4.4 Verify on demo: the runway table shows only rows from the latest run; the growing volume appears in the skipped summary as `exhaustion_beyond_history_cap`.

## 5. Gates
- [ ] 5.1 `make test` green (Rust crates and the core unit tier verified locally on RBE; the `:requires_app`/`:integration` lanes and the web-ng LiveView tier run in BazelCI); `cargo test -p serviceradar-anomaly-core -p serviceradar-anomaly-addon -p serviceradar-anomaly-disposition`; `mix format --check-formatted` in both Elixir projects.
- [x] 5.2 `openspec validate fix-anomaly-baseline-delivery-and-capacity-runway --strict`.
- [x] 5.3 Docs: `docs/docs/anomaly-detection.md` and `anomaly-engine.md` describe the burst envelope, the seasonal event time, and the new capacity skip reason.

## 6. Follow-ups (not in this change)
- [ ] 6.1 Per-mount disk forecasting: SRQL `series:` grouping by tag so `disk_usage` no longer averages every mount per device.
- [ ] 6.2 Seed a stateful alert rule for the `seasonal-baseline-freshness`, `anomaly-ingest-silence`, and `anomaly-alert-liveness` health checks so an unhealthy tripwire pages.
