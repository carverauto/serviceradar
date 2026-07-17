# Tasks — fix-anomaly-spike-flapping-and-duplication

## 0. Demo mitigation (config-only, before any release)

- [x] 0.1 Project non-zero interface-class rolling floors (`metric_classes.interface.min_cv`, `min_std_floor`) through Settings → AnomalyAddonConfigProjector and verify they reach both agents' assignments
- [x] 0.2 Unpin one of the two agents from the demo "Default SNMP" profile (`agent_ids`) so each target is polled once; verify episode duplication stops
- [ ] 0.3 Re-measure demo volume after 24h (episodes/day per series, anomaly OCSF rows/day, critical alert count)

## 1. Edge: bounded withholding + spike adoption (rust/anomaly-core, rust/anomaly-addon)

- [x] 1.1 Winsorized admission in `finalize_detector_verdict`/`branch_with`: admit breaching samples clamped to `center ± n_sigma × effective_scale`; window ages on every sample
- [x] 1.2 Per-series withheld/clamped-sample telemetry counter surfaced through addon status (parallel to `drift_inactive_no_baseline`)
- [x] 1.3 Spike adoption: raw ring buffer of recent samples; after `spike_adopt_after_samples` continuously-anomalous and non-saturated, rebuild the rolling window, clear episode with reason `adopted`; per-class default (interface counters lower than drift's 600)
- [x] 1.4 New config knob `spike_adopt_after_samples` (engine config + config.schema.json + managed projection), default preserving current behavior only where a class opts out
- [x] 1.5 Checkpoint the new state (ring buffer bounded; adoption counters)

## 2. Edge: interface-class floors + absolute significance (rust/anomaly-addon)

- [x] 2.1 `counter_series_profile()`: non-zero `min_cv` and per-family absolute floor (pkt/s vs B/s) for the rolling path
- [x] 2.2 `SeriesProfile.abs_effect_floor` + absolute term in `practical_significance_passes` for counter classes (`delta >= max(0.30 × center, abs_effect_floor)`)
- [x] 2.3 Managed-config plumbing for both knobs so Settings can tune them per class
- [x] 2.4 Wire the already-projected per-class `severity_cap`/`severity_bands` keys into the addon severity path (today they are parsed and dropped — dead config), or remove them from the projector whitelist with a schema note

## 3. Edge: spike reopen/flap-merge parity (rust/anomaly-addon)

- [x] 3.1 `SeriesState` gains `spike_last_cleared_at`, `spike_last_episode_started_at`, `spike_reopen_count`; set on the Clear arm before `reset_active_episode`
- [x] 3.2 Open within `reopen_cooldown_secs` of last clear reuses prior `episode_started_at` (same `episode_uid`), increments reopen count, emits `update`/reason `flapping` instead of `open`
- [x] 3.3 Clear on a reopened episode is rewritten to `flap_merged`; clear-spam inside the flap window is swallowed (mirror drift)
- [x] 3.4 Spike payload carries `reopen_count`; checkpoint persistence for the new fields
- [x] 3.5 Addon version bump 0.2.0 → 0.3.0 and `producer_version` propagation

## 4. Core ingest: flap + duplicate-producer folding (elixir/serviceradar_core)

- [x] 4.1 `AnomalyEpisodeRegistry`: fold an incoming open whose `finding_uid` has an episode cleared within the flap window into that row (reopen semantics + `episode_uid` alias for subsequent transitions), env kill switch
- [x] 4.2 Fold an incoming open whose canonical `series_key` already has an open episode into that row (multi-producer fold; open-wins reconciliation, clear requires all producers clean or stale), telemetry counter for multi-producer series
- [x] 4.3 Config-hygiene warning surfacing SNMP targets polled by more than one agent (device/agent assignment surface)

## 5. Core: seasonal baseline delivery correctness (elixir/serviceradar_core, rust/srql)

- [x] 5.1 Full-profile SRQL variant returning every populated `(dow,hod)` bucket per series; `EdgeBaselineProducer` consumes it (latest-bucket shape unchanged for central disposition)
- [x] 5.2 Delivery gates: minimum per-bucket sample count (aligned with edge `min_bucket_samples`) and minimum bucket-coverage fraction; below-gate series stay in `drift_inactive_no_baseline`
- [x] 5.3 Fix interface baseline scoping: resolve polling agents for a device and write scoped baselines to every enabled anomaly assignment of each such agent (not `partition == agent_uid`)
- [x] 5.4 Edge: distinct seasonal reasons ("no baselines configured" / "no bucket for this hour" / "bucket below trust threshold") instead of one ambiguous "signal disabled"
- [x] 5.5 E2E regression test running the real SRQL profile query (srql-fixtures DB) through `EdgeBaselineProducer`, asserting near-168-bucket delivery for a series with weeks of history and edge bucket resolution at a non-latest hour

## 6. Verification

- [x] 6.1 Harness scenario: diurnal interface series (quiet night ~15 pkt/s, day 40–75, 1-min cadence), no delivered baseline, rolling path at production defaults (n_sigma 3.0/3.5, confirm 5) — assert bounded spike episodes/day, bounded scores, adoption clear on sustained shift
- [x] 6.2 Corpus generator: truth-label recurring diurnal spike alerts as false positives; wire into scorecard CI gate
- [x] 6.3 Harness scenario: flap sequence (breach/clear cycles inside the flap window) asserting single episode with incrementing reopen_count and `flap_merged` clear
- [x] 6.4 Harness/ingest test: two producers, same canonical series → one episode stream
- [ ] 6.5 Demo soak re-check against documented gates (<1,000 anomaly rows/day fleet-wide, ≤20 rows/series/day, Critical share <5%) and alert-volume sanity
- [x] 6.6 Update `docs/docs/anomaly-engine.md` + `docs/docs/anomaly-detection.md` (adoption semantics, spike flap-merge, multi-producer folding, baseline delivery gates)
