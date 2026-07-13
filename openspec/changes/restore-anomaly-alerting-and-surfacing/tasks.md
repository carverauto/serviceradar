# Tasks — restore-anomaly-alerting-and-surfacing

## 1. P0: Production scheduling parity (D1)

- [ ] 1.1 Extract observability/anomaly cron construction into a shared builder in `serviceradar_core` (env-gated entries for SeasonalDisposition.Worker "47 * * * *", SeasonalDisposition.EdgeBaselineProducer "53 * * * *", AnomalyAddonConfigProjector "57 * * * *", AnomalyEpisodeStaleCloseWorker "*/5", ResolveStaleAnomaliesWorker "*/30") and call it from `serviceradar_core/config/runtime.exs`.
- [ ] 1.2 Call the shared builder from `serviceradar_core_elx/config/runtime.exs` (release config). Gate the ResolveStaleAnomaliesWorker entry on task 5.1 having merged (do not schedule the 6h sweep before episode-liveness resolve exists).
- [ ] 1.3 Add a core_elx test that evaluates the release runtime config and asserts the Oban crontab contains every production-required worker (the five above + capacity forecasting + retention workers) — the anti-drift guard.
- [ ] 1.4 Verify on demo after roll: live `Oban.config()` crontab contains the entries; `seasonal_disposition_states` starts receiving rows; `seasonal_baselines` key appears on the enabled anomaly profile within one producer run.

## 2. P0: Alert rule contract repair (D2)

- [ ] 2.1 Migration: idempotent `jsonb_set` rewriting `match`/`recovery` `subject_prefix` `"signals.causal.predictions"` → `"signals.analytics.predictions"` on `stateful_alert_rules` (clone the `20260628224553` style).
- [ ] 2.2 Add `managed` marker + `template_version` to seeded rules; upgrade `RuleSeeder` to reconcile managed rules whose version is behind (pattern: `ZenRuleSeeder.reconcile_or_create`); never touch rules that diverged from the previous template or lost the marker; log skipped reconciles.
- [ ] 2.3 Test: a stored rule with the legacy subject_prefix is repaired at boot; an operator-modified rule is left alone; `RuleMatcher.rule_matches_event?` passes against a real v2 finding fixture for both anomaly and capacity rules.
- [ ] 2.4 Verify on demo: `stateful_alert_rule_states.last_seen_at` advances past 2026-06-30 for the anomaly rule; an anomaly open produces a `Monitoring.Alert`.

## 3. P0: Alert engine placement (D3)

- [ ] 3.1 Set `host_distributed_processes: false` in `serviceradar_agent_gateway` config; audit whether `join_process_registry: false` is also safe (what does the gateway register?) and apply if so.
- [ ] 3.2 `StatefulAlertEngine.load_rules`: once-per-shard `Logger.warning` + telemetry event when `repo_available?()` is false; export per-shard `rules_count` gauge.
- [ ] 3.3 Test: cluster with a repo-less member never places engine shards there (or shards there loudly report zero rules); telemetry emitted.
- [ ] 3.4 Verify on demo after roll: all 8 shards on core nodes; `rules_count > 0` on the shards owning the anomaly/capacity/falco rules across two consecutive restarts.

## 4. P0: Episodes on by default + surfacing (D4)

- [ ] 4.1 Raise `AnomalyEpisodeStaleCloseWorker` default stale threshold to ≥2× the configured episode heartbeat (default 1800s → 65 min threshold) or derive it from emission config; test the margin.
- [ ] 4.2 Flip `AnomalyEpisodeRegistry.enabled?` default to true (env/app-env become kill switches); update docs (`docs/docs/anomaly-engine.md` kill-switch section).
- [ ] 4.3 web-ng legacy events path: synthesize the same default `anomaly_disposition` the episode path uses so cpu-class rows are not unconditionally hidden (`anomaly_capacity_data.ex:954-968`); keep `:legacy_srql` documented as escape hatch.
- [ ] 4.4 Verify on demo: `platform.anomaly_episodes` populates; device page anomaly panel shows open/recent episodes; no stale_closed flapping of live episodes over 24h.

## 5. P1: Stale-resolve consults episode liveness (D5)

- [ ] 5.1 `ResolveStaleAnomaliesWorker`: skip alerts whose finding has an open episode with fresh `last_seen_at`; resolve only when cleared/stale_closed/absent. Tests for open-episode, cleared, and no-episode cases.
- [ ] 5.2 Enable the ResolveStaleAnomaliesWorker cron entry (1.2 dependency).

## 6. P1: Liveness tripwires (D7)

- [ ] 6.1 Schedule `AnomalyAlertLivenessCheck` (cron, coordinator-only); failure emits an operational health event/alert; keep the mix task as the deploy gate entry point.
- [ ] 6.2 Zero-ingest tripwire: health event when anomaly-detection upserts are 0 for N hours while timeseries ingest is alive (default N=6, env-tunable).
- [ ] 6.3 Baseline-delivery tripwire: producer stamps a reconcile timestamp; health event when no enabled anomaly profile has a fresh `seasonal_baselines` payload; surface `drift_inactive_no_baseline` counts on the Observability→Health page.
- [ ] 6.4 Verify on demo: intentionally break one leg in a scratch namespace (or dry-run harness) and confirm each tripwire fires.

## 7. P1: Capacity opt-in + skip visibility (D8)

- [ ] 7.1 Wire `SERVICERADAR_CAPACITY_FORECASTING_SOURCE_OPT_INS` (comma list, validated against `Source.all/0`) in both runtime.exs trees → worker `:default_source_opt_ins`.
- [ ] 7.2 Add `default_source_opt_ins` to `CapacityForecastConfig` + `AnomalyConfigRuntime` mapping + Settings→Anomaly Detection UI multi-select (DB overrides env, consistent precedence).
- [ ] 7.3 Remove phantom `at_risk,exhaustion_projected` tokens from shipped SRQL queries (health page, device panel); add a skipped-series summary (count + top skip reasons) to the health page capacity card.
- [ ] 7.4 Test: opting in `interface_rate` produces interface forecasts in a fixture run; default set unchanged when env/DB unset.

## 8. P2: Hardening

- [ ] 8.1 Seeder: treat empty/absent `metric_class_overrides` env as "apply code defaults" at first seed; docs note that singletons are operator-owned after first boot.
- [ ] 8.2 Enforce single enabled anomaly addon profile per fleet (validation or deterministic precedence + surfaced warning on duplicates).
- [ ] 8.3 NATS: move/extend retention for `signals.analytics.predictions.>` (≥24h, bounded bytes); remove or provision the four 404-ing consumers (falco_events, ATTRIBUTED_FLOW, SFLOW_RAW, NETFLOW_RAW).
- [ ] 8.4 Demo runbook: refresh 2026-06-13-era config singletons via Settings (incl. `minimum_history_points` 24→72, per-class drift modes); dedupe the duplicate enabled anomaly profile after overhaul task 0.3 decides the params.

## 9. P2: Spec debt

- [ ] 9.1 Apply the anomaly-detection REMOVED deltas (10 dead central-reasoner requirements) and MODIFIED operator-config requirement.
- [ ] 9.2 Apply the capacity-forecasting MODIFIED deltas (monotone defaults + reachable opt-in; de-causal naming); update the spec Purpose.
- [ ] 9.3 `openspec validate --strict` passes; archive per convention after deploy.
