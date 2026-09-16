## Context

Evidence gathered on demo (carverauto context, namespace demo) on 2026-09-10/11
via psql on the CNPG primary and release RPC into a core pod. Numbers below are
the measurements the decisions rest on.

| Signal (7 days unless noted) | Value |
| --- | --- |
| Last healthy `seasonal-baseline-producer` heartbeat | 2026-07-17 16:53 UTC |
| Hosts in the single full-profile statement | 20 |
| Full-profile statement time: 1 / 5 / 10 / 20 devices | 2.5-3.3 s / 0.8 s / cancelled / cancelled (30 s `statement_timeout`) |
| Interface full-profile statement, widest device (9 ifs) | 0.9 s |
| Central seasonal episodes: stale_closed / phantom cleared | 377 / 320 (of 697) |
| Median central seasonal peak score vs threshold | 3.19 vs 3.0 |
| Interface spike episodes | 1,001, seasonal signal "no baselines configured" on all |
| Anomaly alerts in 24 h from one bursty router | 148 of 206 |
| Last `projected` capacity row | 2026-07-11 02:41 UTC |
| `projected` rows with exhaustion already in the past | 2,628 |

## Goals / Non-Goals

- Goals: baselines reach the edge again and stay observable; central seasonal
  episodes open, heartbeat, and clear as episodes; recurring bursts stop paging;
  the runway surface shows current forecasts and explains a capped crossing.
- Non-Goals: replacing the rolling robust z-score, changing seasonal bucket
  granularity, per-mount disk forecasting (needs SRQL grouping work), alert
  routing for tripwire health events (follow-up).

## Decisions

- **One full-profile statement per host device.** The planner's "combos" unit
  counts a host series as width 1, which is not the statement's cost driver: cost
  is devices x 168 buckets x history. Measured cost is non-linear (0.8 s at 5
  devices, cancelled at 10), so a device-count cap is data dependent; one device
  per statement is the only sizing that is predictable across fleets and matches
  the interface path. Cost: 20 hosts x ~2 s per hour on demo. Alternative
  considered: raise `statement_timeout` for the role. Rejected: it masks the
  growth and the timeout protects everything else.
- **Partial delivery over all-or-nothing.** A failed source no longer aborts the
  run. Sources that succeeded are delivered, the heartbeat is recorded
  `unhealthy` with `failed_sources`, so the freshness tripwire still fires and
  now says why. The run returns `{:ok, summary}` (no Oban retry storm; the next
  cron run retries anyway).
- **Log the reason in the message body.** The release logger format prints
  `[level] message` only; structured metadata is invisible in `kubectl logs`.
  Delivery failures now carry `source=<name> reason=<inspect>` in the message.
- **Evaluation time is the event time.** The verdict `timestamp` was
  `bucket_ended_at`, which is >= 47 min old at emission and therefore always
  inside the 60 min stale window. `evaluated_at` is the producer's heartbeat;
  `bucket_started_at`/`bucket_ended_at` remain in `seasonal_disposition` for
  the detection-window bands.
- **Detector-aware stale window.** The edge heartbeat window (2 x
  `episode_update_interval_secs`, floor 30 min) is wrong for an hourly central
  producer. `central_seasonal` episodes use `max(150 min, edge window)`; env
  `SERVICERADAR_CENTRAL_SEASONAL_STALE_AFTER_MINUTES` overrides. 150 min covers
  two missed hourly runs plus queue delay. Implemented as a second cutoff in the
  same sweep statement keyed on `detector`.
- **A clear without an open episode is not an episode.** The registry's upsert
  inserts unconditionally, so an orphan clear became a row whose `opened_at ==
  cleared_at`. The insert is now gated: a `clear` transition that resolves no
  existing episode (open, exact id, or within the flap fold window) is a no-op
  for `anomaly_episodes`. OCSF emission for such a clear was already withheld
  (`emit_transition?/2` requires `previous_status: "open"`).
- **Readable seasonal reasons.** `reason` becomes a sentence
  ("Residual z 3.32 exceeded 3.0 for hour-of-week bucket dow 4 hod 6" /
  "Within hour-of-week baseline for dow 4 hod 6"). The machine fields already
  live in `seasonal_disposition.*` and `explainability.severity_score`.
- **Confirm slots default 2.** One hourly bucket at z just over 3.0 is
  threshold noise (median 3.19). Two consecutive buckets is the smallest change
  that removes the single-bucket flicker; operators keep the env override.
- **Burst envelope is a post-signal gate in anomaly-core, computed by the
  add-on.** The add-on already keeps `raw_tail` (raw, un-winsorized values, up
  to 2 x window). It computes `envelope = multiplier x quantile(raw_tail minus
  the newest `lag` samples, q)` when the lagged tail has >= `min_samples`
  points, and passes it in `ReasonContext.burst_envelope`. anomaly-core applies
  it once to the combined verdict: an UPWARD sample (`value > rolling center`)
  with `value <= envelope` does not breach, whatever the rolling or seasonal
  z-scores say, and the verdict reason says so. Lagging the tail by
  `2 x confirm_slots` keeps a sustained surge's first samples above the
  envelope so it still confirms; a recurring burst leaves its own samples in the
  lagged tail so the next one is within the envelope. Sustained level changes
  are drift's job (CUSUM against the seasonal center), which the envelope does
  not touch. Downward breaches are untouched. Alternative considered: letting a
  trusted seasonal bucket veto the rolling breach. Rejected: buckets are hourly
  averages, so a sub-hour burst breaches the seasonal signal too (measured on
  the bursty router the bucket center would be ~84 KB/s against 700 KB/s bursts).
- **Kernel reports the uncapped crossing.** `CapacityForecast` gains
  `raw_projected_exhaustion_at_unix_micros` (the linear crossing bounded only
  by the 10 x horizon noise cap) and `exhaustion_history_capped` (true when the
  capped ETA is `None` solely because the crossing lies beyond 2 x the observed
  span). The worker maps that to skip reason `exhaustion_beyond_history_cap`
  with diagnostics `raw_projected_exhaustion_at`, `history_span_seconds`,
  `extrapolation_cap_seconds`. The parity gate compares named fit fields, so
  additive fields do not disturb it. The 2 x cap itself is unchanged: with 24
  days of history a 58-day crossing is still reported as capped, but now
  visibly and with the date.
- **Newest forecast per resource on the Health page.** Default query becomes
  `status:projected has_exhaustion:true time:last_24h sort:forecasted_at:desc
  limit:500`; rows are deduplicated on (resource_id, resource_key, metric_name)
  keeping the newest, sorted by `projected_exhaustion_at` ascending, and cut to
  25. An operator-typed query in the SRQL bar is still honored verbatim.

## Risks / Trade-offs

- Per-device statements multiply query count by the host count. Bounded by the
  hourly cadence; telemetry already counts chunks. Mitigation: `max_devices`
  opt (default 1) if a deployment measures headroom.
- The burst envelope can hide a real event whose magnitude matches a recent
  burst. Mitigation: multiplier 1.25 default, class-scoped default (interface
  rates only), envelope only suppresses upward moves, drift still covers level
  changes, and the verdict reason names the suppression so it is auditable.
- Raising confirm slots delays a real central seasonal breach by one hour.
  Acceptable: central seasonal is a slow-signal tier.
- Changing event timestamps to evaluation time shifts the finding's displayed
  time from the bucket end to the run time (up to +47 min). The chart still
  shades the bucket window.

## Migration Plan

- No schema change. Add-on version 0.3.6 -> 0.3.7 (config schema gains the
  burst envelope keys, all optional).
- After deploy: the next :53 producer run repopulates `seasonal_baselines`
  (byte-inequality forces the write); the relic single-bucket payload is
  replaced. Verify with the `seasonal-baseline-producer` healthy heartbeat and a
  payload `seasonal.reason != "no baselines configured"`.
- Existing stale `projected` rows are not rewritten; the bounded query stops
  showing them.
- Rollback: revert the release; env overrides
  (`SERVICERADAR_CENTRAL_SEASONAL_STALE_AFTER_MINUTES`,
  `SERVICERADAR_SEASONAL_DISPOSITION_CONFIRM_SLOTS=1`, per-class
  `burst_envelope_enabled: false`) restore prior behaviour without a rebuild.

## Open Questions

- Should the 2 x history extrapolation cap relax when the PI at the crossing is
  narrow? Deferred; the new skip reason makes the cases countable first.
- Should the freshness/silence/liveness tripwires seed an alert rule? Yes in
  principle (they were unhealthy for 8 weeks unnoticed); follow-up task.
