# Design — restore-anomaly-alerting-and-surfacing

## Context

The 2026-07-04 `overhaul-anomaly-engine-reliability` change (merged as `bf13097a0`, shipped v1.4.1+) implemented episodes, emission governance, alert restoration, seasonal baseline delivery, and capacity soundness — but four independent deployment-layer defects keep most of it dormant in every production deployment, and the demo DB carries pre-cutover rows the code never repairs. Evidence for each defect (live RPC/SQL output, file:line, adversarial verification) is summarized in `proposal.md`; this document records the fix decisions.

Key structural fact: the deployed core image is built from `elixir/serviceradar_core_elx` (`docker/images/BUILD.bazel:117-129`, `docker/compose/Dockerfile.core-elx:59,74`); `serviceradar_core` is a path dep whose `config/*.exs` Mix never evaluates for the release. Anything configured only in `serviceradar_core/config/runtime.exs` does not exist in production.

## Goals / Non-Goals

- Goals: anomalies and capacity findings that the (already shipped) engine produces become reliably visible in alerts and UI; silent-failure modes get tripwires; config that operators can set actually takes effect; specs match shipped reality.
- Non-Goals: changing detector math, thresholds, episode semantics, or emission governance (owned by the overhaul); enabling interface drift on demo (overhaul task 4.5); publishing the signed 0.2.0 addon package (overhaul task 6.2); reverting the Phase-0 damping profile (overhaul task 0.3); fixing the broader non-anomaly crontab drift (RootSpanRatioWorker, PruneStaleAgentsWorker, RemoteAccess reapers, object_store_retention — noted for a follow-up, the guard test should cover them once ported).

## Decisions

### D1. Cron parity via a shared crontab builder + guard test (defect 1)

Port the five entries into `core_elx/config/runtime.exs` with their existing env gates (`SERVICERADAR_SEASONAL_DISPOSITION_ENABLED`/`..._CRON` default on "47 * * * *"; `SERVICERADAR_SEASONAL_EDGE_BASELINE_ENABLED` default on "53 * * * *"; `SERVICERADAR_ANOMALY_EDGE_CONFIG_PROJECTION` per D6; stale-close `*/5`; resolve-stale `*/30`). Rather than copy-paste (which is how the drift happened), extract the anomaly/observability cron construction into a shared function in `serviceradar_core` (e.g. `ServiceRadar.Release.ObservabilityCrontab.entries(System.get_env/1)`) called from both runtime.exs files — runtime.exs may call library code at boot. Add a core_elx test that boots the release config and asserts the Oban crontab contains every required production worker.

- Alternatives: `import_config` across trees (Mix forbids importing a dep's config into a release); documentation-only parity rule (already failed).
- Ordering note: `ResolveStaleAnomaliesWorker` must not be scheduled before D5 lands (see Risks).

### D2. Alert-rule contract migration + managed-rule reconciliation (defect 2)

Forward-only idempotent migration cloning `20260628224553_flip_legacy_signal_type_rules_to_prediction.exs`: `jsonb_set` on `match->>'subject_prefix'` and `recovery->>'subject_prefix'` where the value is `signals.causal.predictions`, for the two seeded rule names. Then make drift impossible to reintroduce: seeded rules gain a `managed` marker + `template_version`; `RuleSeeder` upgrades from insert-if-absent to reconcile-if-managed-and-version-behind (pattern already exists in `ZenRuleSeeder.reconcile_or_create`, `zen_rule_seeder.ex:84-93,160-199`). Operator-modified rules (marker removed or fields diverged from template N-1) are left untouched and logged.

- Alternatives: matcher-side back-compat aliasing `signals.causal.*` (hides the data problem, keeps zombie strings); manual demo SQL (does not fix other deployments, and the create-only seeder guarantees recurrence at the next contract change).

### D3. Gateway opts out of Horde placement; shards fail loudly (defect 3)

`serviceradar_agent_gateway` config sets `host_distributed_processes: false` (and `join_process_registry: false` if parity with web-ng proves safe for its other registered processes — verify what the gateway actually registers before flipping the second flag). Defense in depth in `StatefulAlertEngine.load_rules`: when `repo_available?()` is false, emit `Logger.warning` (once per shard, not per evaluation) + a `[:serviceradar, :stateful_alert_engine, :shard_without_repo]` telemetry event, and expose per-shard `rules_count` as a metric so a zero-rule shard is visible on dashboards.

- Alternatives: Horde member filtering inside ProcessRegistry for repo-requiring children (more invasive, Horde 0.10 has no per-child placement constraint; would require a custom distribution strategy — revisit if more repo-dependent processes appear); RPC-to-core rule loading from repo-less nodes (adds a network dependency inside the hot evaluation path).
- Note: web-ng nodes were observed hosting no shards only by luck of `:auto` membership; web-ng already opts out explicitly — the gateway fix restores the intended "only core hosts distributed work" invariant.

### D4. Episodes default ON with a widened stale margin (defect 4)

Flip `AnomalyEpisodeRegistry.enabled?` default to `true`; `EVENT_WRITER_ANOMALY_EPISODES=false` (or app env) becomes the kill switch. Precondition: raise `AnomalyEpisodeStaleCloseWorker` default stale threshold from 30 min to ≥2× the addon episode heartbeat (`episode_update_interval_secs`, default 1800s) + sweep jitter — i.e. 65 min — or derive it from the emission config at runtime, so a single delayed heartbeat cannot stale-close a live episode. web-ng: keep `:ash` as default source (it now has data); keep `:legacy_srql` as documented escape hatch; align the legacy path's cpu-row filter with the episode path (episode rows synthesize `anomaly_disposition.action="escalate"` at `anomaly_capacity_data.ex:570,622-623`; the legacy filter at `:954-968` unconditionally hides cpu rows because no producer persists that field — synthesize the same default there).

- Alternatives: helm-only env enablement (leaves compose/bare-metal deployments dark; repeats the "wired nowhere" failure); web-ng auto-fallback to events when episodes are empty (masks a dead registry — the liveness tripwires in D7 are the honest fix).
- Risk accepted: cpu episodes become visible on device pages. Edge saturation gates (cpu ≥85%) and severity caps bound the noise; the original hide (7ebb225c3) predates those gates.

### D5. Stale-resolve consults episode liveness (defect 7, dedupe starvation)

Verified interplay: ingest excludes already-seen event ids from alert evaluation (`analytics_signals.ex:266-270`), addon heartbeats reuse the same event id and their states match neither firing nor recovery lists — so the engine sees nothing for a still-open episode after the first open, and detector semantics deliberately keep sustained anomalies open indefinitely (breaching samples are withheld from the baseline). `ResolveStaleAnomaliesWorker` (6h engine-visible silence) would therefore resolve live alerts and the id-dedupe prevents re-fire. Fix: before resolving, the worker checks `platform.anomaly_episodes` for an open episode matching the alert's finding (registry is ON per D4 and stale-close per D1 closes abandoned episodes) — resolve only when the episode is cleared/stale_closed/absent. This makes episode state the single source of truth for staleness instead of engine-visible re-fires.

- Alternatives: mint new event ids per heartbeat at the addon (regresses overhaul F12 idempotency and re-inflates row volume); enqueue replace-upserted heartbeat rows to the engine as refresh-only events (extends the engine API for a signal the episode table already carries).

### D6. Config projection: schedule it, default it ON (defect from `SERVICERADAR_ANOMALY_EDGE_CONFIG_PROJECTION`)

The spec requires unconditionally that operator Settings reach the edge; today the projector is default-off AND its cron doesn't exist in the deployed release — so the entire `SERVICERADAR_ANOMALY_*` env family on the core deployment is dead config, and an operator loosening thresholds in Settings is silently ignored. Decision: include the projector cron in D1's shared crontab and flip the env default to `"true"`. Safety: projector writes only the reserved `managed` sub-key; operator-explicit top-level params still win (`anomaly-detection` spec, "Operator configuration reaches the edge detector"); per-class and global kill switches remain.

- Alternative: keep default-off and amend the spec to say projection is opt-in — rejected; it institutionalizes the "Settings UI silently does nothing" trap the overhaul's RC8 identified.

### D7. Liveness in both directions (defect 6)

Three tripwires, all coordinator-scheduled:
1. **Alert-path liveness**: `AnomalyAlertLivenessCheck` (already implements synthetic open→alert→clear→resolve plus `assert_rule_contract`, which detects D2-class drift) runs on a cron (e.g. every 6h); failure emits an operational health event/alert. The existing mix task stays as the deploy-gate entry point.
2. **Ingest silence**: if zero anomaly-detection upserts for N hours (default 6) while `timeseries_metrics` ingest is alive, emit a health event. Mirrors the existing over-rate tripwire.
3. **Baseline-delivery liveness**: if no enabled anomaly profile carries a fresh `seasonal_baselines` payload (producer stamps a reconcile timestamp), emit a health event; surface the addon-side `drift_inactive_no_baseline` counter on the health page so "bounded silence" is visibly different from "broken".

### D8. Capacity opt-in reachability + skip visibility (defect 5)

Wire `default_source_opt_ins` end to end: env `SERVICERADAR_CAPACITY_FORECASTING_SOURCE_OPT_INS` (comma-separated source names, validated against `Source.all/0`) in both runtime.exs; new `default_source_opt_ins` array field on `CapacityForecastConfig` + `AnomalyConfigRuntime` mapping + Settings UI multi-select (DB wins over env, same precedence as other knobs). Do not change the default set (memory+disk is the overhaul's deliberate soundness decision). Surface skips: shipped SRQL queries drop the phantom `at_risk,exhaustion_projected` tokens; the Observability→Health capacity card gets a "N series skipped (top reasons)" line sourced from a `status:skipped` aggregate so "no forecasts" is explainable in-product.

### D9. Verdict durability and explicit consumer ownership (defect 7, NATS)

`signals.analytics.predictions.>` historically rode the shared `events` stream with MaxAge 30m — a >30m core/EventWriter outage permanently discarded all verdicts (episodes then stale-close and re-open, but transitions were lost). The implemented choice provisions a dedicated `analytics_predictions` stream with ≥24h age and bounded bytes; existing deployments require the subject-transfer procedure in `runbook-demo.md`. Realign the stale `falco_events` registration to the existing `events` stream and `falco.logs` subject.

`ATTRIBUTED_FLOW` is not a dormant pipeline awaiting a producer. It is a legacy EventWriter registration for the retired demo-canary subject `flow.attributed.>`. Production attribution now persists agent-up process observations, correlates them with independently ingested raw flows in CNPG, and stamps `event_type = "attributed_flow"` on the existing OCSF row. Remove the release registration; default and release configuration MUST NOT provision an attributed-flow subject, stream, or durable, and rollback MUST NOT recreate one. A verified-empty orphan durable or `attributed_flow` stream may be deleted after the registration is gone.

`NETFLOW_RAW` and `SFLOW_RAW` are active logical consumer names for `flows.raw.netflow` and `flows.raw.sflow`, not nonexistent stream names and not part of attributed-flow cleanup. `scale-netflow-ingest-isolation` owns their dedicated `flows` stream, consumer lifecycle, subject transfer, and rollback. This change MUST leave that raw-flow ownership untouched.

### D10. Seeder correctness on fresh installs (defect 7, config)

Helm renders `SERVICERADAR_ANOMALY_METRIC_CLASS_OVERRIDES_JSON` default `{}`, which the seeder accepts as valid and stores — discarding the code's per-class drift_mode defaults even on brand-new installs. Fix: treat empty/absent override env as "use code defaults" at seed time. Singletons remain operator-owned after first boot (Settings UI is the update path); document this in the ops docs, and add a demo runbook task to refresh the 2026-06-13-era rows through Settings.

## Risks / Trade-offs

- **Scheduling `ResolveStaleAnomaliesWorker` before D5 lands would auto-resolve live long-lived anomalies** (the exact failure it was built to prevent, inverted). Mitigation: land D5 in the same release, or gate the cron entry on the episode-liveness check being present (task ordering enforces this).
- Episodes ON changes `ocsf_events` write patterns (updates folded into episodes, ≤12 rows/finding/hour) — this *reduces* row volume; risk is the stale-close/heartbeat margin, addressed before enablement (D4).
- Projection ON (D6) could surprise deployments whose profiles carry stale explicit top-level params — operator-explicit params win by design, so behavior only changes where operators never touched the profile (i.e., where Settings were silently ignored). Release notes must call this out.
- Rule reconciliation (D2) touches operator-editable rows; the managed-marker + leave-diverged-rules-alone rule bounds the blast radius.
- CPU rows visible on device pages (D4) may re-add noise on saturated fleets; bounded by edge saturation gates and severity caps; revert lever is the per-class kill switch.

## Migration Plan

1. Phase A (P0, one release): D1 (crons incl. projector, minus resolve-stale until D5 merges), D2 migration + seeder reconcile, D3 gateway opt-out + loud shards, D4 margin fix + episodes default ON. Verify on demo: rule matches live finding; shards all on core nodes with rules_count>0; `anomaly_episodes` populating; device panel shows episodes; seasonal workers running at :47/:53; baselines appear on profiles (host classes first; interface drift stays off pending overhaul 4.5).
2. Phase B (P1): D5, then enable the resolve-stale cron; D7 tripwires; D8 capacity opt-in + skip surfacing.
3. Phase C (P2): D9 prediction-stream provisioning and FALCO realignment; remove the retired `ATTRIBUTED_FLOW` registration and verified-empty orphan state without touching raw-flow consumers owned by `scale-netflow-ingest-isolation`; D10 seeder fixes; profile-uniqueness validation; spec-debt deltas archive.
4. Rollback: every new default has an env kill switch (`EVENT_WRITER_ANOMALY_EPISODES=false`, `SERVICERADAR_ANOMALY_EDGE_CONFIG_PROJECTION=false`, per-cron `*_ENABLED=false`); the rule migration is forward-only but the seeder reconcile can re-stamp; gateway opt-out is a config revert.

## Open Questions

- Demo's `capacity_forecast_configs.minimum_history_points` reads **24** live while every code/helm/seeder path defaults 72 — the row predates or was edited outside any current code path. Refresh via Settings during the demo runbook step; no code change needed (24 is looser, not a suppressor).
- Should the gateway also set `join_process_registry: false` (web-ng parity), or does it legitimately register cluster-visible processes? Verify during D3.
- Dedicated predictions stream (D9): implementation chose the separate `analytics_predictions` stream plus the existing-deployment subject transfer in `runbook-demo.md`. This choice does not reopen `flow.attributed.>`; that retired namespace remains unprovisioned, while raw-flow stream decisions remain with `scale-netflow-ingest-isolation`.
