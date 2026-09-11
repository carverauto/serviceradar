# Change: Restore seasonal baseline delivery, bound central seasonal episodes, and make capacity runway truthful

## Why

A live audit of the demo cluster (2026-09-10, core v1.4.56, anomaly add-on 0.3.4)
found that no anomaly or capacity output can be relied on, and that this is not a
tuning problem. Four independent code defects were each reproduced in place:

1. **Seasonal baseline delivery has been dead since 2026-07-17 16:53 UTC.** The
   edge-baseline producer's host chunk planner bin-packs devices by "combos" with
   a width of 1 per host and a cap of 200, so every host device in the fleet lands
   in ONE `profile_hour_of_week_full` statement. That statement is cancelled by the
   database role's 30 s `statement_timeout` (measured: 1 device 2.5-3.3 s, 5
   devices 0.8 s, 10 devices cancelled, 20 devices cancelled). `build_delivery/2`
   halts on the first failing source, so nothing is delivered — interface
   baselines included. Every hourly run since logs `Edge baseline source fetch
   failed` with the source and reason in logger metadata the release formatter
   drops. The freshness tripwire has recorded `unhealthy` since 2026-07-18 and
   produced zero alerts. Profiles and assignments still carry a July relic of one
   bucket per series with `sample_count: 2`, which the edge discards (it trusts a
   bucket at 4+ samples), so every edge payload reports `seasonal: "no baselines
   configured"`.
2. **A delivered baseline cannot suppress a periodic burst anyway.** The detector
   treats a breach as "any signal breached" (`rust/anomaly-core/src/detector.rs`),
   and hour-of-week buckets are built from hourly averages, so a 20-minute bulk
   transfer that recurs all day breaches the rolling signal AND the seasonal
   signal every time. One router with periodic ~700 KB/s bursts over a ~14 KB/s
   median produced ~20 High episodes per day per interface series and 148 of the
   206 anomaly alerts in 24 h (108 of them critical via the `severity_from:
   source` rule).
3. **Every central seasonal (cpu/memory) episode is mishandled.** The verdict
   emitter stamps the event time with the END of the evaluated bucket, which is
   already 47 minutes old when the hourly worker runs at :47. The stale sweep
   closes anything unseen for 60 minutes (2 x the edge heartbeat), so every breach
   is `stale_closed` at bucket_end + 60 min, before the next hourly evaluation.
   The next hour's clear derives a new episode id from finding + opened time,
   misses the closed episode, and inserts a phantom zero-length `cleared` row. In
   7 days: 377 stale-closed + 320 phantom = 697 of 697. `confirm_slots` defaults
   to 1 and the median breach score is 3.19 against a 3.0 threshold, so most of
   what does surface is threshold noise, and the finding modal renders the raw
   `disposition=suppress score=0.0000 ...` string as the resolution.
4. **Capacity runway shows June data and hides the one real risk.** The
   Observability Health query has no time bound and sorts by exhaustion
   ascending, so the oldest rows from the pre-gate model win (a disk at 75.8
   "projected" to 1.69 with an exhaustion date). The worker still runs hourly but
   has written no `projected` row since 2026-07-11, and no `cleared` row is ever
   persisted, so stale projections never retire. The kernel drops any crossing
   further out than 2 x the observed history span and the worker records that as
   `no_projected_exhaustion`: a volume growing 0.57 points/day from 24 days of
   history (PI 93-98 % at +90 d, threshold 80) is invisible.

## What Changes

- **Edge baseline delivery (serviceradar_core)**: host sources fetch one
  full-profile statement per device (the interface path already does), the
  producer keeps delivering the sources that succeeded when one source fails,
  records an `unhealthy` heartbeat naming the failed sources so the freshness
  tripwire fires with a reason, and logs the failing source and reason in the
  message body.
- **Central seasonal lifecycle (serviceradar_core)**: verdict events are
  timestamped with the evaluation time (the bucket window stays in the
  `seasonal_disposition` payload); the stale-close sweep applies a
  producer-cadence window to `central_seasonal` episodes (default 150 min,
  `SERVICERADAR_CENTRAL_SEASONAL_STALE_AFTER_MINUTES`); the episode registry no
  longer mints a zero-length episode for a clear that has no open episode to
  close; the verdict `reason` is an operator-readable sentence; the production
  default for `SERVICERADAR_SEASONAL_DISPOSITION_CONFIRM_SLOTS` becomes 2.
  **BREAKING** for consumers that parsed the `disposition=... score=...` reason
  string: those fields are already carried structurally in
  `seasonal_disposition`.
- **Periodic-burst governance (rust/anomaly-core, rust/anomaly-addon)**: an
  optional per-class burst envelope. When a series' lagged raw history holds at
  least `min_samples` points, an upward breach must also exceed
  `multiplier x quantile(lagged raw tail, q)`; otherwise the sample is reported
  as within the recent burst envelope and does not breach. Enabled by default
  for interface counter rates only (quantile 0.99, multiplier 1.25, lag 2 x
  confirm_slots), off for every other class; per-class overrides project through
  the existing settings chain. Downward breaches and CUSUM drift are unaffected.
  **BREAKING**: interface spike volume drops for series with recurring bursts;
  a taller-than-recent burst still opens. Add-on version bumps to 0.3.7.
- **Capacity runway (anomaly-disposition kernel, serviceradar_core, web-ng)**:
  the kernel reports the uncapped crossing alongside the capped ETA and the
  worker records `exhaustion_beyond_history_cap` (with the raw crossing, the
  history span, and the cap) instead of `no_projected_exhaustion` when the only
  reason for "no ETA" is the extrapolation cap; the Health page's default runway
  query is bounded to the last 24 h and deduplicated to the newest forecast per
  resource before sorting by exhaustion.

## Impact

- Affected specs: `anomaly-detection`, `capacity-forecasting`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/observability/seasonal_disposition/{edge_baseline_producer,verdict_emitter}.ex`
  - `elixir/serviceradar_core/lib/serviceradar/observability/{anomaly_episode_stale_close_worker,production_schedule}.ex`
  - `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/anomaly_episode_registry.ex`
  - `elixir/serviceradar_core/lib/serviceradar/observability/capacity_forecasting/worker.ex`
  - `rust/anomaly-disposition/src/disposition/capacity/{exhaustion,linear,holt_winters,mod}.rs`
  - `rust/anomaly-core/src/{detector,types}.rs`, `rust/anomaly-addon/src/{config,metrics_classify}.rs`, `rust/anomaly-addon/src/engine/{mod,types}.rs`, `addons/anomaly-addon/{addon.yaml,config.schema.json}`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/observability_health_live/index.ex`
- Out of scope, tracked as follow-ups in `tasks.md`: forecasting disk usage per
  mount point (the `disk_usage` source averages every mount per device via
  `series:uid`, which SRQL cannot split today), and a seeded alert rule for the
  three anomaly tripwire health checks.
