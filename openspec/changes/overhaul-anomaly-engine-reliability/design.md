# Design: overhaul-anomaly-engine-reliability

## Context

### Live evidence (demo cluster, 2026-07-03, CNPG `platform.ocsf_events`)

- 294,598 anomaly events in 7 days = **84.6% of ALL OCSF ingest**; 65.2% Critical, 32.4% High.
- Volume doubled to ~80k/day on Jul 2–3, coinciding with the v1.3.10 rollout that shipped addon 0.1.20 with CUSUM default-ON (commit 588280170, 2026-06-28).
- Last-24h reason mix: drift down 50,700 + drift up 25,902 (**91.5% of volume, all High/Critical**), spike opens 2,946, clears 3,010.
- Top offender: `192.168.10.1 ifOutUcastPkts if4` — 5,118 events/24h, median inter-event gap **0.8s**. 552 distinct series; 93 series ≥1k events each — the noise is broad, not a few bad series.
- Severity is a pure score-threshold map; drift scores are unbounded CUSUM accumulators (observed max 6.6e23 → Critical forever).
- Drift Criticals routinely fire while the rolling z signal is clean (z=0.48, 0.81 in sampled events) — the alarm comes from the accumulator, not any breached signal.
- Each row stores the same JSON ~3× (metadata 2,104B + unmapped 1,476B + raw_data 2,751B ≈ 6.3KB); hypertable at 111GB.
- `cpu.frequency_hz` (normal DVFS scaling) is a top Critical generator: 27σ "breach" because the window MAD was 134kHz on a 1GHz mean.
- Operator-confirmed noise (screenshots 2026-07-03): single-core CPU at 94% for ~2.5min → High "breach confirmed" (k8s-cp2-worker1 CPU20); Critical "sustained upward drift" at 27.98% on one core (k8s-cp2-worker2 CPU16 — **below the cpu saturation gate of 85, proving the drift path bypasses per-class gates**); capacity forecast projecting a 6%-avg bursty CPU gauge to cross 100% on 2026-08-02, displayed with the projected date in the "Observed" field and no chart marker.

### Root causes (all verified with file:line)

| # | Root cause | Evidence |
|---|-----------|----------|
| RC1 | CUSUM drift: frozen warm-up anchor (set once at first 30 clean samples), reset-and-re-accumulate on alarm, emit-per-alarm with no lifecycle/cooldown/clear | `rust/anomaly-addon/src/engine/mod.rs:394-421`, `rust/anomaly-core/src/cusum.rs:87-99`, `rust/anomaly-addon/src/frame.rs:145-154`, `verdict.rs:164` (ts_nano event_id) |
| RC2 | Interface counters excluded from seasonal baselines (cpu/memory only), and baseline keys lack `if_index`, so per-interface deseasonalization is structurally impossible; repo harness measured raw CUSUM 42–74% FP on seasonal data and mandated deseasonalized-only | `elixir/.../seasonal_disposition/source.ex:91-111,186-201`, `edge_baseline_producer.ex`, `refactor-anomaly-engine-rigor/tasks.md` 2.2, addon test `tests/engine.rs:1105-1167` |
| RC3 | Severity: unbounded accumulator fed to z cutpoints (≥6→Critical), drift `confirmed=true` by construction, magnitude > h=5 ⇒ floor High | `rust/anomaly-addon/src/verdict.rs:152-155,269-281` |
| RC4 | CUSUM anchor scale floors at `f64::EPSILON` — counters have zero dispersion floors and the anchor path skips the near-zero guard the z-path has ⇒ ~1e15σ residuals on quiet interfaces | `engine/mod.rs:400-404` vs `rust/anomaly-core/src/stats.rs:283-313`; `metrics_classify.rs:104-144` |
| RC5 | No episode semantics at ingest: deterministic `finding_uid` computed but metadata-only; row id embeds ts_nano; every report = new immutable row | `analytics_signals.ex:1638-1651,2021-2051,239-259` |
| RC6 | Legacy `signal_type=causal` payloads fall through to the class-1008 builder with **no confirmation gate and no severity clamp** (12.7% duplicate rows, pending Criticals) | `analytics_signals.ex:757-768,879-895` |
| RC7 | Four generations of suppression/disposition tiers designed, none active: peak disposition report-only (`suppression_enabled` default false), alert-engine seasonal gate scoped to edge-spike + cpu/memory only — SNMP and ALL edge-drift bypass everything | `anomaly_disposition.ex:92-101`, `edge_anomaly_disposition.ex:73-75,106-119` |
| RC8 | Config severed: Settings singleton reaches only central workers; addon profile seeder seeds only `metric_feed.sources`; edge runs hardcoded Rust defaults; `anomaly_series_config()` has no consumer | `anomaly_addon_profile_seeder.ex:18-51`, `anomaly_config_runtime.ex:88-125` |
| RC9 | Blast radius: StatefulAlertEvaluationQueue bounded 512/2 overflows under storms (real alerts silently lost); shared 8GiB/24h 'events' JetStream stream eviction risk; ~500MB/day storage | `stateful_alert_evaluation_queue.ex:26-28`, `event_writer/config.ex:248-254` |
| RC10 | Secondary: per-core `tag_core_id` fan-out (32+ detectors/host); `cpu.frequency_hz` false Criticals; sysmon.process pid/start_time series churn (229→2,959 series/hr); spike open/clear flap pairs; central VerdictEmitter mints a new finding per (dow,hod) per hour | `identity.rs:67-115`, `retire-uasb-causal-disposition/tasks.md` 5.1, `verdict_emitter.ex:123-145` |
| RC11 | Drift path bypasses per-class saturation gates and dispersion floors that protect the z path. Live 48h: 2,952/2,952 cpu.usage_percent drift findings below the 85 gate, 2,128 Critical, median Critical value **40.5%**; "sustained downward drift" Criticals fire on utilization gauges where easing load is never an incident | `engine/mod.rs:384-421` (no gate consult), `:463-474` (only `!verdict.breached` filter), `verdict.rs:151-155`; live 48h severity/value distribution |
| RC12 | Capacity forecasting is statistically unsound for its dominant sources: 63% of `projected` findings are on mean-reverting bursty gauges (CPU avg-current 7.4%, interfaces avg-current 3.0%) against a 100% domain-ceiling threshold; the only gates are ≥24 points, slope>0, crossing ≤10× horizon — no slope significance, no fit-quality gate, PI computed but display-only; demo fits ~7 days of history extrapolated 90 days (13×); the operator's series flipped projected↔skipped 18 times/week with a 45-day ETA dispersion. Worker re-emits a verdict for EVERY series EVERY hourly run (3,067/run; ingest backlogged 2–4 days); 97% of interface capacity findings carry `device_id='default'` (partition used as resource_id); configured `model=linear` is silently dropped and `warning_threshold_percent=80` flaps 80↔100 across runs (per-node config cache divergence) | `capacity_forecasting/source.ex:44-105` (thresholds 100.0), `rust/anomaly-disposition/src/disposition/capacity/mod.rs:71-102` (gates), `exhaustion.rs:54-79`, `worker.ex:546-575` (emit per run), `:873-879` (resource_id = first key field = partition), `anomaly_config_runtime.ex:290-293` (drops :linear); live `platform.capacity_forecasts` flap/dispersion stats |
| RC13 | SNMP interface **collection is healthy** (perfect 60s cadence, 100% `counter_width=64`, raw values >2³² prove ifHC polling works). The gappy/garbled charts are UI/SRQL defects: device-page panels query `agg:rate` (SRQL returns rates) but stamp `rate_mode: :counter`, so rates are differentiated a second time — ~50% of buckets dropped as bogus counter decreases (tonka01 eth9: 146/288 buckets nil, displayed 1.8 KB/s vs true 344 KB/s); the interface detail page has the mirror bug (`agg:max` + `:rate` = raw cumulative counters labeled B/s); latent: SRQL `agg:rate` LAG partitions by metric_name only, interleaving 5–6 agents' polls of one target (clock skew ⇒ +2⁶⁴ wrap branch ⇒ 1.8e19 B/s spikes); y-axis tick labels wider than 62 SVG units are viewport-clipped, garbling the ladder; single-point line segments render as invisible bare `M x,y` | introduced by commit 7955a1a0a; `device_live/interface_data.ex:343-345,429`, `interface_live/metrics_query.ex:4-25` + `show.ex:1517-1519`, `dashboard/plugins/timeseries/metrics.ex:161-230`, `rust/srql/src/query/downsample/sql.rs:193-216`, `chart_card.ex:323-326,374-377`, `paths.ex:120-121`; live SQL replay |
| RC14 | **Anomaly alerting is dead**: the stateful alert engine stopped firing at the 2026-06-30 02:40Z signals.analytics.* cutover (19,024 fires before, zero since, across 295k subsequent events) — ingestion followed the rename, the alert engine did not; separately, fired alerts reference `alert_ids` that do not exist in `platform.alerts` (0 anomaly-titled alerts all-time), so even when rules fired operators saw nothing | `platform.stateful_alert_rule_histories` max(fired)=2026-06-30 02:40:28; consumer `serviceradar-event-writer-analytics-predictions` created 06-30 03:50; dangling alert_ids 47153898-… |
| RC15 | Deployment hygiene multiplies risk: TWO enabled anomaly AddonProfiles tie at priority 100 with different packages (0.1.20 full params vs legacy 0.1.19 minimal params) — which params win is resolver-tiebreak-dependent; 2 agents pinned to stale v0.1.1 by manual assignments the reconciler skips; every v0.1.20 instance reports "resource limits not enforced" (cgroup permission denied); no `checkpoint_path` in the active profile so every addon restart cold-starts baselines | `platform.addon_profiles` e89a5f67 vs 66d0746b; `addon_assignments` manual rows (agent-k8s-cp2-worker1 live on 0.1.1); `addon_statuses` degradation_reason |
| RC16 | Per-core CPU is the only alerting unit — the agent emits cpu.usage_percent per core only (no host aggregate exists anywhere), the addon keys per core_id, so "1 of 32 cores at 94% for 2.5 min" is the smallest and only cpu alert the system can produce; severity is two-level by construction (breach needs z≥3 which already maps High) and inversely correlated with load (Critical median value 94.6 < High median 96.1 — busy windows inflate MAD); cpu spike episodes never clear on demo (1,898 pre-lifecycle opens permanently open; the current addon emitted ZERO cpu spike opens in 48h — the spike path swung from flood to silent while drift floods instead) | `go/pkg/agent/metric_envelope.go:886-917` (per-core only), `identity.rs:88-94,333-337`, `verdict.rs:269-281`; live 7d/48h distributions; `fix-anomaly-engine-semantics-and-delivery/design.md:419` (F1), `:525-543` (F28) |

### Existing machinery this design builds on (do not reinvent)

- Spike-path Open/Clear lifecycle with confirm-slot hysteresis — already correct and transition-gated (`engine/mod.rs:532-568`, `frame.rs:126-139`). It is the template for the drift lifecycle.
- Robust median/MAD scoring with near-zero scoring floors (`stats.rs:283-340`), hour-of-week `SeasonalBaseline` expansion (`seasonal.rs`), CUSUM primitive (`cusum.rs`), checkpointing.
- SRQL `stats:profile_hour_of_week` / `profile_hour_of_week_peak` verbs over hourly CAGGs; `EdgeBaselineProducer` → `AddonProfile.params.seasonal_baselines` → `configure()` delivery channel.
- Shed-record machinery (`shed.rs`, `status_code=anomaly_capacity_shed` precedent) for auditable overflow accounting.
- Seeded alert rule collapsing per (device, series_key) with 300s cooldown (`rule_seeder.ex:163-200`) — alerts are already bounded; the events surface is the flood.
- Proof harness `tools/anomaly-proof` + `rust/anomaly-core/src/bin/anomaly-backtest` with an existing scorecard.

## Goals / Non-Goals

- Goals:
  - Kill ≥95% of anomaly event volume at the source while retaining real recall (spikes, genuine sustained drifts, capacity exhaustion).
  - One logical anomaly = one bounded episode, end-to-end (edge → NATS → ingest → storage → UI → alerting).
  - Severity an operator can trust: Critical = act now; fleet-wide Critical rate in single digits per day.
  - Every suppressed/shed emission is auditable (telemetry + rollup records); no silent drops.
  - Operator tuning in the Settings UI actually changes edge behavior.
  - Each phase independently shippable, machine-verified, and revertible.
- Non-Goals:
  - New detection algorithms beyond the calibrated CUSUM/z pair (S-H-ESD/RPCA stay reference-only).
  - Activating the peak-profile disposition tiers (remains report-only; separate calibration effort).
  - Per-device timezone seasonal profiles; holiday awareness (documented limitation).
  - Static per-interface thresholds (`add-interface-metric-thresholds` stays open as the complement).
  - Retention/compaction of the existing 111GB backlog (ops task, not spec).

## Decisions

### D1. Drift detection: keep CUSUM, fix reference/scale/semantics; deseasonalized-only by default

The two-sided tabular CUSUM (S⁺/S⁻, slack k, decision interval h) is the right statistic — O(1)/sample, minimax-optimal for sustained mean shifts, already implemented. The defects were the reference (frozen 15-minute anchor), the scale (EPSILON floor), and the alarm semantics (reset-and-re-emit). Fix all three:

- **Reference** — per-metric-class `drift_mode ∈ {off, deseasonalized_only, always}`:
  - `deseasonalized_only` (default for snmp/interface counters, cpu.usage_percent, memory.used_percent, icmp): CUSUM updates only when a delivered hour-of-week center resolves for the series (`engine/mod.rs:412-416` already selects the seasonal target; the change is gating updates on its presence instead of falling back to the frozen anchor). No baseline ⇒ no drift detection ⇒ **bounded silence, counted in telemetry as `drift_inactive_no_baseline`** — never fabricated alarms. This is the posture the repo's own harness mandated (42–74% FP raw vs 0.6–1.0% deseasonalized).
  - `always` (opt-in for known-stationary series): anchor re-baselines after every episode clear/adoption, plus `anchor_max_age_secs` (default 86400) refresh when idle. Scale refreshes from the current rolling window every evaluation (already computed — zero added cost); only the center stays anchored, because a tracking center is what makes the rolling z blind to slow drift.
  - `off` (default for disk — capacity forecasting territory — and unclassified series).
- **Scale**: the anchor/baseline scale uses the same `effective_scoring_scale` near-zero guard as the z path (`stats.rs:283-313`: max(configured floors, 5%·|center|, 1.0 near zero)) instead of `effective_scale().max(f64::EPSILON)`. Counters additionally get `min_cv=0.05` on the drift path. The floors double as the effect-size gate in absolute units: with scale ≥ 5% of level, a statistically-real-but-trivial shift cannot accumulate.
- **Alarm semantics — latch-and-confirm, then episode**: crossing h does NOT emit and does NOT reset. The series enters drift-pending; it confirms when the accumulator reaches `h_confirm` (default 1.5×h) within `drift_confirm_window` samples, else decays back to zero silently. On confirm, compute the bounded shift estimate **δ̂ = k + S/N** (standard CUSUM post-alarm estimator; N = samples since S last touched zero) and require `δ̂ ≥ drift_min_effect` (default 2.0 floored-σ). h default rises 5.0 → 8.0: two-sided k=0.5/h=5 has ARL₀≈465 samples under ideal i.i.d. noise — at 30s cadence across 552 series that alone is thousands of false episodes/day; h=8 + confirm pushes per-series false-opens into multi-day territory while a real 1σ shift still confirms in ~19 samples (~10 min).
- **Gate parity (RC11)**: the drift path applies the same per-class directional saturation gates and dispersion floors as the z path. A drift on a bounded gauge below its saturation band cannot open above Medium.
- **Denylist / key hygiene (RC10)**: `metric_denylist` default `["cpu.frequency_hz"]` (DVFS is a control value, not health); `pid`/`start_time` join the excluded volatile keys in `identity.rs` (absorbs retire-uasb 5.1).

Rejected: BOCPD (per-series posteriors, untunable hazard priors, same episode layer needed anyway); STL/matrix-profile at the edge (blows the 50%CPU/256MiB/50k-series budget; the 168-bucket table *is* the cheap robust decomposition); pure re-tuning of h/k (re-alarm period ceil(h/(δ−k)) is finite for any δ>k — no parameter fixes an anchored CUSUM on a shifted series); EWMA-tracking center as primary (absorbs the drift it should detect; kept as documented fallback); disabling CUSUM permanently (slow-drift recall is a product promise; deseasonalized mode is proven at 0.6–1% FP).

### D2. Drift episode lifecycle at the edge

Model on the spike path state machine: `idle → pending → open → clearing → cleared`. One `anomaly_drift_open` on confirm; while open, no emission except (a) one severity-escalation update and (b) a bounded still-open heartbeat every `episode_update_interval_secs` (default 1800). Clear on either recovery (|z| < k for `drift_clear_slots`, default 30 samples) or **adoption**: after `drift_adopt_after_samples` (default 600 ≈ 5h @30s) the new level is adopted as baseline — re-anchor, reset S±, emit `anomaly_drift_clear` with reason `"level adopted as new baseline"`. Adoption is blocked while a bounded gauge sits inside its saturation band (never adopt 95% memory as normal). Re-opens within `reopen_cooldown_secs` (600) of a clear reuse the episode identity with `flap_count` incremented — a sustained flapper converges to one long-lived episode annotated "flapping" (the annotation is the signal to fix the floor/threshold, not more events). Clears carry a `clear_reason ∈ {recovered, adopted, stale, flap_merged}`. Episode state joins the checkpoint. Worst case any series emits ≤ ~6 drift rows/day; a benign regime change costs exactly one open + one clear.

### D3. Episode model end-to-end: transition rows + AnomalyEpisode resource

A persisted `ocsf_events` row means a **lifecycle transition**, not a detector evaluation: Create on open, Update only on severity-band escalation (folded otherwise), Close on clear — matching OCSF class 2004 activity semantics and keeping the hypertable append-only. Every emission carries `finding_uid` (already deterministic per series), `episode_uid = UUIDv5(finding_uid, episode_started_ns)`, `transition ∈ {open, update, clear}`, `producer_version` (ADDON_VERSION), and effect/peak fields. Transition row `event_id` is **deterministic from (episode_uid, transition, severity_band)** — ts_nano leaves row identity entirely, so duplicate emissions and JetStream redeliveries collapse via the existing (time,id) conflict target. The still-open heartbeat is a non-OCSF telemetry record folded into the episode row (last_seen_at, peak), never a persisted event.

New Ash resource `ServiceRadar.Observability.AnomalyEpisode` → `platform.anomaly_episodes` (Ash codegen migration): identity `episode_uid`; attrs `finding_uid, device_uid, series_key, metric_name, if_index, metric_class, detector (spike|drift|central_seasonal|capacity), status (open|cleared|stale_closed), severity_id, peak_severity_id, effect_size, peak_score, opened_at, last_seen_at, cleared_at, occurrence_count, reopen_count, last_payload (jsonb, single copy)`. Upsert keyed on `episode_uid`; a staleness sweep (reuse the state_machine.ex stale-anomaly sweep pattern) closes episodes unseen for 30min as `stale_closed` so a crashed addon cannot leak永-open episodes.

**Producer-version-independent ingest backstop (the stale-addon lesson)**: ingest folds against the episode registry — a duplicate open for an already-open episode updates `occurrence_count`/`last_seen_at` and writes **no new row**; payloads without episode fields (legacy addons) collapse under `UUIDv5(finding_uid)`; a per-`finding_uid` rate guard (max 12 persisted rows/hour) converts any pathological producer into episode updates + telemetry. This bounds the events surface even where the new addon has not rolled out.

UI reads: events page reads `ocsf_events` unchanged (bounded rows now); the device-detail anomaly panel and a new "active anomalies" view read `anomaly_episodes` (one row per episode — structurally kills the 5s-timeout class of incident). An ETS cache fronts the registry to avoid a DB read per message.

Rejected: mutate-in-place episode rows in `ocsf_events` (UPDATE-heavy pattern on a compressed hypertable; clears arriving after chunk compression fail; breaks append-only semantics) — considered as a zero-read-path-change alternative, but the new resource is Ash-native, cheap, and gives the UI the bounded surface it needs anyway.

### D4. Severity calibration

Never map a raw accumulator onto z cutpoints (RC3). Evidence `e` is bounded: spike → robust z on floored scale; drift → δ̂ (same σ units, so one band table serves both); stored scores capped at 50.

- Bands (replacing `verdict.rs:269-281`): `e < 4` Low; `4 ≤ e < 8` Medium; `e ≥ 8` High; **Critical = High AND a class impact test passes AND the condition has persisted ≥ `critical_min_duration_secs` (default 600)** — no instantaneous reading pages a human. (A bounded transform such as `10·(1−exp(−z/z_ref))` is an acceptable implementation of the score bound; the band semantics above are what the spec fixes.)
- Practical-significance gates (kills "statistically enormous, operationally nil"): percent gauges require |x−center| ≥ 5 percentage points; counter rates require relative deviation ≥ 30%; unclassified series skip the gate.
- Impact tests for Critical: cpu/memory gauges — episode peak inside the saturation band (cpu 85 / mem 80, the existing gate values): Critical means *actually saturated*, not merely unusual. Interface counters and icmp — **statistical detection caps at High**; an unsupervised detector cannot know a traffic change is service-impacting; interface Critical is reserved for explicit semantics (link-down, operator static thresholds via `add-interface-metric-thresholds`). Disk — never Critical from edge detection (capacity path owns it).
- Edge drift caps at High everywhere ("the level changed and stayed changed" is an investigate signal, not a page); drift opens at Medium (with effect/practical gates passed) and may escalate to High after `drift_escalate_after` (default 1h) while still open. Only central seasonal escalation (existing `edge_anomaly_disposition.ex:174-186` machinery) or saturation semantics can mint drift-related Critical.
- Per-core cpu series (`tag_core_id` present) cap at High; only host-level series are Critical-eligible.
- Ingest backstop clamps (producer-version-independent): `verdict_source=edge-drift` ⇒ ≤ High; reason prefix "breach pending" ⇒ ≤ Low.
- Central VerdictEmitter aligns to the same band table and drops (dow,hod) from finding identity so an ongoing seasonal breach is one episode with folded updates, not 24 findings/day (`verdict_emitter.ex:123-145,237-245`).
- Operator contract (spec language): Critical = confirmed anomaly whose current value indicates service-impacting saturation or outage-consistent behavior; expected fleet-wide rate single digits/day. High = large confirmed deviation worth same-day attention. Medium = confirmed, modest. Low = bookkeeping/clears.

### D5. Emission governance (no silent drops)

1. Per-series cooldown `emission.cooldown_secs` (default 300) between non-clear emissions; clears always pass (downstream state machines need them); transitions inside the window coalesce to the terminal state.
2. Per-addon budget `emission.budget_per_tick` (default 100 records per 30s push tick). On exhaustion the addon enters **storm mode with hysteresis** (exit below 50% usage sustained ~5 min; one governance event on entry/exit): opens for series with NO open episode keep a ~20% reserved sub-budget (protect novel signal); queued transitions compact latest-state-wins per series (an open followed by a clear while queued compacts away, flap_count preserved); overflow coalesces into ONE OCSF Event Log Activity rollup per interval (`status_code=anomaly_emission_shed`, reusing `shed.rs` verbatim) carrying per-class counts + top-N series — a mass event (site outage) surfaces as one blast-radius summary plus the highest-priority individual opens (priority: clears and High+ opens first, then opens, then updates). CI-tested invariant: **detected transitions == emitted + rollup-accounted**.
3. Core tripwire: if anomaly upserts/min exceed a threshold, core emits a `serviceradar.core` operational event — a regressed/stale addon is detected in hours, not weeks.
4. Alert-path protection (RC9): only opens, severity-escalation updates, and clears enqueue `StatefulAlertEvaluationQueue`; the seeded per-(device,series_key) collapse and 300s cooldown are untouched; `rule_seeder` recovery matcher gains `anomaly_drift_clear` so drift alerts auto-resolve.

Guarantee statement (spec): every detected condition either produces an episode record, is folded into an open episode (visible via heartbeat/occurrence_count), or is counted in an explicit shed rollup + telemetry — no path where detection output vanishes untraceably.

### D6. Ingest correctness (analytics_signals.ex)

1. Single classification (RC6): anomaly-shaped payloads (an `anomaly` block or anomaly event_type) route through the class-2004 builder + confirmation gate regardless of `signal_type` ("prediction" or legacy "causal"); the class-1008 fallthrough is closed for them (escape hatch env `SERVICERADAR_ANOMALY_LEGACY_CLASS1008`, default off).
2. Hardened gate: `anomaly_finding_unconfirmed?` additionally withholds any payload whose reason carries the "breach pending" prefix regardless of claimed state.
3. Episode upsert as D3; the existing upsert-replace branch (`:239-259`) extends its replace field set for episode updates on `anomaly_episodes`.
4. Payload stored once: `raw_data` nil for anomaly rows (byte-duplicate of unmapped); `metadata.detection_finding` keeps summary fields only; the full signal array lives in `unmapped` alone. ~6.3KB → ≤2KB/row.

### D7. Config unification (RC8)

One authoritative chain: Settings-UI singleton (`AnomalyDetectionConfig`) → `AnomalyConfigRuntime` → new Oban worker `AnomalyAddonConfigProjector` (pattern-cloned from EdgeBaselineProducer, flag `SERVICERADAR_ANOMALY_EDGE_CONFIG_PROJECTION`) writes a `managed` sub-key of the anomaly AddonProfile params → existing reconciler → AddonAssignment → agent configure(). The addon merges `managed` < operator-explicit params (hand-tuned profiles always win); the projector is a separate reversible writer so deployed addons are untouched until enabled. Baseline producer and projector own disjoint top-level keys.

New schema (`addons/anomaly-addon/config.schema.json`, additive; old addons ignore unknown keys, new addon serde-defaults missing ones; two-direction compat test required): `metric_classes.{cpu,memory,disk,interface,icmp,other}` with `{enabled, drift_mode, cusum_k, cusum_h, h_confirm_mult, drift_confirm_window, drift_clear_slots, drift_min_effect, drift_adopt_after_samples, drift_escalate_after_secs, severity band overrides, severity_cap, min_std_floor, min_cv}`; `emission.{cooldown_secs, budget_per_tick, episode_update_interval_secs, reopen_cooldown_secs}`; `seasonal.{max_baselines}`; `metric_denylist`. The 0.2.0 schema/UI exposes per-class `drift_mode`, not the old global `cusum_enabled`; the 0.2.0 runtime ignores stale `cusum_enabled` if it appears in old profile data. An omitted drift block means per-class defaults (functionally off for uncovered classes).

Kill switches: per-class `drift_mode=off` / `enabled=false` (60s config poll); `cusum_enabled=false` is only the deployed 0.1.20 demo bridge before 0.2.0 lands and is scrubbed/ignored by 0.2.0; emission governor toggle; core `EVENT_WRITER_ANOMALY_EPISODES` (revert to per-report rows); projector flag; baseline cron gate (exists).

### D8. Seasonal coverage for interface counters (RC2)

Extend the existing chain, do not build a new one. Baseline key gains a third segment `<device_uid>|<metric_name>|<if_index>` (empty for host metrics — backward compatible): a new `interface_seasonal` source in `seasonal_disposition/source.ex` (allowlist widened for **baseline delivery only**; central disposition verdicts stay cpu/memory-scoped — delivery of context and central suppression authority are deliberately decoupled). Edge `seasonal_series_key` (`identity.rs:172-188`) appends if_index when present; 3-segment lookup with 2-segment fallback; old addons never match 3-segment keys (safe degradation to no-baseline = no drift = silence).

Payload governance (mandatory): per-agent scoping (producer writes per-assignment params covering only devices that agent polls), top-K active interfaces per device (default 16, by traffic), minimum history ≥3 weeks, compact array-of-168 f32 encoding, hard per-agent cap (default 1,000 series) with truncation telemetry. Pre-flight verification task: confirm the hourly CAGG carries per-second rates + if_index in its group set (the (device_id, metric_name, if_index) canonical join was established by align-edge-anomaly-series-key); if it does not, this sub-phase blocks without affecting the noise reduction from Phases 0–2. Buckets UTC-phased on both ends; per-device timezones deferred.

Cold start is explicit: a series without a delivered baseline has no drift detection; spike detection covers it from ~15min as today. The alternative — raw CUSUM meanwhile — is the measured 42–74% FP mode this change deletes.

### D9. Capacity forecasting soundness (RC12)

- Eligibility: runway ("projected crossing") findings are emitted by default only for **monotone consumable resources** — disk usage, memory working set. `cpu.usage_percent` and interface utilization (302 near-idle interfaces produced 1,223 projected findings in 7d) are excluded by default; per-source opt-in remains. If CPU/interface saturation forecasting is wanted later, it must forecast the sustained busy-hour statistic (daily p95) against an 80–90% threshold, never the raw hourly-avg gauge against the 100% domain ceiling.
- Significance gates before any `projected` finding: robust trend estimator (Theil–Sen or HAC-adjusted slope CI) excluding zero; trend persisted across k consecutive runs (hysteresis, kills the observed 18-flips/week); extrapolation capped at ~1–2× the *observed* history span (demo fit 7 days and extrapolated 90); and the ETA gate uses the **PI lower-bound crossing** (the PI is already computed correctly in `linear.rs:112-135`/`holt_winters.rs:252-298` — today it is display-only). Seasonality autodetection must use all complete periods, not the first 24h (`holt_winters.rs:199-241`).
- Emission: transition-only (projected↔cleared state changes with m-of-n hysteresis), replacing the per-series-per-run re-emission (3,067 events/run) that backed OCSF ingest up 2–4 days. Runway findings use episode semantics: one open per crossing condition, refreshed in place, cleared when the projection retreats.
- Attribution: interface-source `resource_id` must be the device (or device:if_index composite), not the partition key field (`worker.ex:873-879`) — 97% of capacity findings currently land on device `default`.
- Config honoring: `maybe_put_forecast_model` forwards `:linear` (`anomaly_config_runtime.ex:290-293` currently drops it, silently re-enabling Holt-Winters autodetect); the worker reads config transactionally at run start instead of trusting the per-node persistent_term cache (the 80↔100 threshold flap across the 3-replica cluster).
- UI: "Observed" renders `forecasted_at`; the projected crossing gets its own "Projected crossing" field (`anomaly_capacity_components.ex:435,1160-1164`); drop or rename the constant "PI coverage 95%" display (it is `COVERAGE_LEVEL`, identical on every forecast); the capacity modal reflects the LATEST run's state per series instead of any projected row from the last 24h.

### D10. Interface counter rate integrity — UI/SRQL, not collection (RC13)

Wave-2 verified collection is healthy end-to-end (mapper probes ifHC OIDs and ships `Supports64Bit`; the config compiler prefers `oid_64bit`; the checker stamps `counter_width` from the wire type; 100% of demo samples are 64-bit with values >2³²; perfect 60s cadence). The defects are one conversion done twice, and zero conversions, respectively:

- **Rate conversion happens exactly once**: device-page interface panels (`interface_data.ex:343-345,429`) query `agg:rate` and must stop stamping `rate_mode: :counter` (the Timeseries plugin re-differentiates rates, dropping ~50% of buckets as implausible counter decreases and rendering rate-of-rate garbage). The interface detail page (`interface_live/show.ex` + `metrics_query.ex`) must pick one side of the same contract: either restore `rate_mode: :counter` over `agg:max`, or switch to `agg:rate` with `:rate` as label-only. Codify the contract: SRQL `agg:rate` output is already a rate; `rate_mode: :counter` is reserved for raw cumulative queries.
- **SRQL `agg:rate` partitions deltas per polling series**: today LAG partitions by metric_name only while 5–6 agents poll the same target (`downsample/sql.rs:193-216`); include series_key/agent in the partition, and bound the 2⁶⁴ wrap branch with a plausibility ceiling like the edge normalizer's `plausible_counter_delta`.
- **Drop accounting**: the UI counter_rates and edge normalizer drop rules (gap/reset/decrease) gain counters/telemetry so future chart gaps are attributable.
- Regression lock: codify 64-bit polling preference + `counter_width` stamping (already implemented and verified) as spec requirements so they cannot silently regress.

### D11. Findings surface legibility (web-ng)

- Decode the v2 hex series key (encoder: `serviceradar_core .../anomaly_detection/series_key.ex:82-95,164-173`; no decoder exists anywhere in the repo) into human-readable fields in the finding modal; populate INTERFACE/RESOURCE from the payload's already-decoded `metadata.source_identity` tags (`tag_label=CPU20`, core_id, mount_point) instead of n/a; demote the raw key to a tooltip.
- Metric-context marker: for capacity rows the focus timestamp must lead with `forecasted_at` (today it resolves to `window_ended_at`/`projected_exhaustion_at` — never the "forecast event time" the copy promises, `anomaly_capacity_components.ex:565-583`); out-of-range markers clamp to the chart edge with an explicit "outside this window" caption instead of silently vanishing (`series_data.ex:329-337` returns nil); the marker helper text renders only when a marker was actually placed.
- Fix the `@chart_pad` undeclared-assign crash in `chart_card.ex:84-86` — the advertised detection-window shaded band can never have rendered; it raises on the first in-range window annotation.
- Y-axis tick labels: compute the left pad from the widest formatted tick (labels wider than 62 SVG units are viewport-clipped today — the "garbled ladder"); avoid non-uniform glyph scaling (`preserveAspectRatio="none"`).
- Gap rendering: single-point segments render as visible dots (today a bare `M x,y` draws nothing); position points by timestamp, not array index, so irregular sampling doesn't distort the time axis.
- Events page: debounce/coalesce the per-broadcast full refresh (`event_live/index.ex:94-101` re-runs the list query + both summaries on every EventWriter batch, per connected client); align stat-tile click-through queries with the rollup predicates that produced the counts.
- Device anomaly panel reads `anomaly_episodes` (bounded) instead of paging raw `ocsf_events`.

### D13. Restore the anomaly alert pipeline (RC14)

Zero-noise events are worthless if alerting stays dead. Two independent defects to fix and gate on:

- The stateful alert engine stopped matching anomaly events at the 2026-06-30 signals.analytics.* cutover (rule histories flatline at 02:40Z; the EventWriter's analytics-predictions consumer was created 03:50Z and ingests fine). Root-cause whether the engine still keys on the legacy subject/signal_type or on an OCSF field the 0.1.19+ addon no longer emits; fix, and add a **post-deploy liveness check** (seeded rule fires against a synthetic confirmed episode) so a silent stall can never again run for days.
- Fired alerts reference `alert_ids` absent from `platform.alerts` (0 anomaly-titled alerts all-time). Trace the fire→persist path (transaction failure vs retention prune) and make alert persistence verifiable.
- With episodes (D3), the alert engine consumes open/clear transitions; the seeded per-(device, series_key) collapse and cooldown remain the notification bound.

### D14. Host-aggregate CPU evaluation; per-core demoted to context (RC16)

The agent emits per-core gauges only; no host aggregate exists anywhere, so per-core series are unavoidably the alerting unit today. Synthesize host-level series and make them the Critical-eligible alerting series:

- Addon-side aggregation (avoids an agent protocol release): per identity+metric with core_id stripped, maintain host aggregates — mean utilization across cores and count/fraction of cores above the saturation gate — evaluated on the same 30s slot cadence; handle partial-core arrival within a slot by aggregating what the slot saw.
- Per-core series remain detected (real per-core pathologies exist) but are non-Critical (severity cap High per D4) and are attached as evidence/context on host findings where possible.
- For saturation gauges, severity derives from effect size + duration on the host aggregate (e.g. High = host >90% sustained ~10 min or >50% of cores pinned); z remains the trigger, not the grade.
- Slot semantics: consider dual max+mean within slots so a 1-second spike per 30s window cannot sustain an episode on its own.
- Post-fix check: the spike path must still open on genuine sustained single-core saturation in the harness — demo shows the current gate+MAD combination has swung the spike path to fully silent on cpu (zero opens in 48h while builds ran), which is the opposite failure.

### D15. OpenSpec debt and why this proposal won't stall like the last six

Creates the first `openspec/specs/anomaly-detection/spec.md` baseline. Archives as complete: `add-causal-anomaly-detection`, `move-anomaly-detection-to-edge`, `refactor-anomaly-engine-rigor`, `refactor-anomaly-reasoner-deepcausality`. Archives as obsolete (central engine deleted): `update-anomaly-evaluation-cadence`, `optimize-anomaly-production-path-2m`, `add-core-causal-disposition-nif`. Archives as superseded: `add-anomaly-finding-disposition`, `add-seasonal-anomaly-detection`. Absorbs remaining live tasks from `fix-anomaly-engine-semantics-and-delivery` (live verification, severity remnants) and `align-edge-anomaly-series-key` (join-key parity audit → Phase 4 prerequisite). Keeps open `add-interface-metric-thresholds`.

The 132/170-tasks disease was mega-audits mixing detector math, delivery hardening, and unowned live-verification tasks CI could not check. Here: each phase ≤ ~25 tasks, independently mergeable and revertible, machine-gated by harness scenarios, and live checks are literal commands with expected outputs.

## Risks / Trade-offs

- Timescale/CAGG work for if_index profile grouping may be costly on the 111GB hypertable → additive/parallel small CAGG; validate on the srql-fixtures scratch DB; Phase 4 is independently deferrable (drift stays safely off for uncovered series meanwhile).
- AddonProfile params bloat from baselines (48-port × 8-metric switch ≈ MBs naive) → per-agent scoping, top-K, f32 arrays, hard cap + truncation telemetry; measured on demo before enabling; failure mode is bounded silence, never noise.
- Two writers to AddonProfile params (baseline producer + config projector) → disjoint top-level keys, documented ownership, reconciler property test.
- Adoption can mask a true slow leak after ~5h → explicit "level adopted" clear records, capacity forecasting still owns exhaustion, saturation-band adoption block, configurable window.
- Severity recalibration changes alerting for rules keyed on Critical → bands config-deliverable per class, one-release overlap, seeded rule re-verified in the demo soak, release notes.
- Stale addon fleets (bit us at least twice: v0.1.1, mixed fleet on demo) → ingest is producer-version-independent (episode fallback, pending-reason gate, drift clamp); `producer_version` stamped on every record; Phase 0 includes a fleet version audit; SLO soak pins and verifies the addon version first.
- Hour-of-week profiles mis-modeling holidays/maintenance → bounded by effect floors, episode caps, drift ≤ High; holiday-aware profiles out of scope.
- Emission governor masking a genuine mass event → priority ordering + mandatory rollup record with blast-radius summary; alert rules can key on the rollup.
- Episode registry consistency (crashed addons, ETS vs DB) → 30min stale sweep, idempotent upserts.

## Migration Plan

- **Phase 0 — demo mitigation + deployment hygiene (config-only, day 1, no release)**: set `cusum_enabled=false` in the active anomaly AddonProfile params (kills the ~91% drift share within one 60s config poll); disable/delete the legacy "Default Edge Anomaly Detection" profile (0.1.19) so only one enabled profile targets `in:agents` (RC15 tiebreak ambiguity); delete the two manual assignments pinning agent-k8s-cp2-worker1/k8s-agent to stale v0.1.1 so the reconciler upgrades them; decide/confirm `checkpoint_path` behavior (no path in the active profile ⇒ every restart cold-starts baselines); optionally raise `n_sigma→4`/`confirm_slots→8` to damp per-core cpu spike noise; demo-only DELETE of the historical anomaly backlog including the 1,898 permanently-open pre-lifecycle cpu findings (demo data is disposable).
- **Phase 1 — edge correctness (addon 0.2.0)**: anchor scale floor; drift episode lifecycle + latch-confirm + adoption; per-class drift_mode defaults; gate parity; severity bands/caps; host-aggregate cpu series (D14); emission cooldown/budget/shed; metric denylist; pid excluded keys; producer_version stamping; checkpoint episode state. Independently kills the storm with zero core changes. Rollback = per-class off / previous artifact.
- **Phase 2 — core ingest episodes + alert pipeline restoration**: classification fix; pending-reason gate; AnomalyEpisode resource + Ash codegen migration; episode upsert + folding backstop + rate guard; payload slimming; transition-only alert enqueue; drift/pending severity clamps; drift-clear recovery matcher; VerdictEmitter re-keying; **root-cause and fix the 2026-06-30 alert-engine stall and the dangling alert_ids (D13), with a post-deploy alert liveness check**. Behind `EVENT_WRITER_ANOMALY_EPISODES`; effective against BOTH old and new addons.
- **Phase 3 — capacity soundness + rate integrity + UI**: capacity eligibility/significance/transition-only emission + resource_id attribution + config-honoring fixes; interface chart rate_mode fixes (both pages) + SRQL agg:rate partition/plausibility + drop accounting; web-ng modal decoding, marker semantics, `@chart_pad` crash, axis pad, single-point rendering, events-page debounce, episode-backed device panel.
- **Phase 4 — seasonal coverage for interfaces**: CAGG/SRQL if_index verification, interface_seasonal source, if_index-keyed EdgeBaselineProducer with payload governance, edge 3-segment lookup. Interface drift activates automatically as baselines arrive.
- **Phase 5 — config unification + docs + debt**: AnomalyAddonConfigProjector + Settings UI knobs; docs rewrite (drift glossary, score semantics, severity contract, expected healthy volume); archive/supersede the OpenSpec corpus per D15.
- Rollout of every phase: demo first (demo-local-rollout; note argocd-image-updater is scaled 0/0 — demo rolls are manual `kubectl set image`, and Kyverno enforces cosign-signed images), 48h–7d SLO soak (see verification tasks) before prod default flips; every phase has a config/env kill switch.

## Open Questions

- Does the hourly CAGG's group set already include if_index for interface rate series (Phase 4 pre-flight)? If not, additive CAGG vs backfill decision goes to implementation.
- Exact practical-significance defaults per metric class (5pp gauges / 30% rates are starting points; tune against the harness + demo soak).
- Whether the still-open drift heartbeat should surface in the events UI at all or remain episode-table-only (current design: episode-table-only; events rows are open/escalation/clear).
- Root cause of the alert-engine stall (needs code inspection: does the stateful engine still key on legacy signal_type/subject, or on an OCSF field the 0.1.19+ addon stopped emitting?) and of the dangling alert_ids (persist failure vs prune) — D13 scopes the fix, implementation pins the mechanism.
- Host-aggregate synthesis location: addon-side (chosen default — no agent protocol change, must handle partial-core slots) vs agent-side host-total emission; revisit if addon-side slot alignment proves fragile.
- Why the current addon emits zero cpu spike opens while builds run (85-gate + busy-window-inflated MAD over-suppression?) — the harness must pin spike recall before Phase 1 ships, so the fix doesn't swing cpu from flood to permanently silent.
- Two idle NATS consumers with dead backlogs (zen-consumer 6,946; db-event-writer 707, both "last delivery: never") — out of scope here but flagged for ops.
