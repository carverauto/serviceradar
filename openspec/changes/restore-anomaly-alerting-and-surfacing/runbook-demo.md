# Demo rollout runbook — restore-anomaly-alerting-and-surfacing

Cluster-side steps that code cannot do. Run top to bottom after the release containing this change rolls to demo. Also folds in the still-open ops items from the active `overhaul-anomaly-engine-reliability` change (0.3, 4.5, 6.2, 6.7) that this change unblocks.

## 1. Post-roll verification (tasks 1.4 / 2.4 / 3.4 / 4.4)

```
# crontab now contains the five anomaly workers (+ tripwires)
kubectl exec -n demo deploy/serviceradar-core -- /app/bin/serviceradar_core_elx rpc \
  'Oban.config().plugins |> inspect(limit: :infinity) |> IO.puts()'

# rules repaired: subject_prefix must be signals.analytics.predictions
kubectl exec -n demo cnpg-29 -- psql -U postgres -d serviceradar -tAc \
  "SELECT name, match->>'subject_prefix' FROM platform.stateful_alert_rules WHERE name LIKE 'causal_%';"

# shards all on core nodes with rules loaded (repeat after a second restart)
#   rpc: ProcessRegistry lookups for StatefulAlertEngine shards 0..7 -> node(pid), :sys.get_state rules_count

# episodes populating (within ~1h of anomaly churn)
kubectl exec -n demo cnpg-29 -- psql -U postgres -d serviceradar -tAc \
  "SELECT status, count(*) FROM platform.anomaly_episodes GROUP BY 1;"

# seasonal chain alive: state rows after the :47 run, baselines key on the profile after :53
kubectl exec -n demo cnpg-29 -- psql -U postgres -d serviceradar -tAc \
  "SELECT count(*) FROM platform.seasonal_disposition_states;"
kubectl exec -n demo cnpg-29 -- psql -U postgres -d serviceradar -tAc \
  "SELECT id, params ? 'seasonal_baselines' FROM platform.addon_profiles WHERE addon_id='anomaly' AND enabled;"

# alert path end-to-end (overhaul task 6.7 — first real execution)
kubectl exec -n demo deploy/serviceradar-core -- /app/bin/serviceradar_core_elx rpc \
  'Mix.Tasks.Serviceradar.AnomalyAlertLiveness.run([])'   # or run the mix task from a release console per its docs
```

Device pages should now show episodes; Observability → Health unchanged (already read events).

## 2. Config singleton refresh (Settings → Anomaly Detection)

The DB singletons are operator-owned and frozen at their 2026-06-13 state:
- `minimum_history_points`: currently **24**, set to **72** (matches every code/helm default; origin of 24 unexplained).
- Per-class drift modes: set cpu/memory/interface `deseasonalized_only`, disk/icmp/other `off` (these now actually reach the edge via the projector).
- Review denylist / emission values against helm intent.

## 3. Profile hygiene + damping decision (overhaul task 0.3 + this change's 8.2)

Two enabled anomaly profiles are assigned to every agent: `197e30c8` (n_sigma 3.0 / confirm 5 — currently winning on the wire) and `e89a5f67` (Phase-0 damping, 4.0 / 8). **Migration `20260713010000` auto-resolves this at roll time**: it keeps the deterministic delivery winner (lowest priority, then most recently updated — on demo that is `197e30c8`, i.e. 3.0/5), disables the rest, and adds a partial unique index so exactly one anomaly profile can be enabled from then on.

Decision aid: current flap rate is ~50–120 rows/series/day on ~20 SNMP counter series (gate: ≤20/day). The migration's default outcome is **keep 3.0/5**. Options:
- **Ratify damping instead**: disable `197e30c8`, then enable `e89a5f67` (4.0/8) → immediate flap reduction, fewer marginal opens. (The index allows exactly one enabled at a time, so disable first.)
- **Keep 3.0/5** (migration default): rely on episodes folding + seasonal deseasonalization (weeks away) + central tuning via the now-working projector — with projection live, n_sigma/confirm can also be raised from Settings without touching profiles.

Either way, record the outcome against overhaul task 0.3. Re-check per-series volume 24h later (§6).

## 4. Signed 0.2.0 addon package (overhaul task 6.2)

The fleet runs hand-swapped 0.2.0 binaries inside the signed 0.1.20 package slot; any re-delivery can revert them. Requires `SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY` (operator-held):

```
SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY=... scripts/publish_addon.sh anomaly 0.2.0   # verify exact invocation in the script
```

Then: retire the 0.1.20/0.1.19 assignments (keep one enabled 0.2.0 path per §3), confirm `addon_statuses` reports 0.2.0 running fleet-wide, and delete the canary note from overhaul tasks 6.2.a-c.

## 5. Interface drift enablement (overhaul task 4.5)

No switch to flip: `deseasonalized_only` drift auto-activates per series once baselines are delivered. After §1 shows `seasonal_baselines` present:
- Measure profile/assignment params payload sizes (task 4.5's gate) — `SELECT id, octet_length(params::text) FROM platform.addon_profiles WHERE addon_id='anomaly';` and same for assignments; compare against the per-agent cap.
- Interface baselines need ≥3 weeks of history per hour-of-week bucket — expect first interface drift findings no earlier than ~3 weeks after baselines start accumulating; host cpu/memory baselines may qualify sooner.
- When drift findings appear, verify volume against the gates before checking 4.5 off.

## 6. Volume + soak gates (overhaul tasks 6.1/6.5 spirit)

24h and 7d after the roll:
- fleet-wide anomaly rows/day < 1,000; no series > 20 rows/day; Critical share < 5%; alert-queue overflow = 0.
- `anomaly_episodes` open-count stable (no stale_close flapping of live episodes).
- Liveness worker green; silence tripwire quiet; baseline tripwire quiet.

## 7. NATS hygiene (task 8.3)

### 7.1 One-time migration: move verdicts onto the dedicated `analytics_predictions` stream

The release moves the `ANALYTICS_PREDICTIONS` consumer to a dedicated `analytics_predictions` stream (limits / file / discard-old, 1 GiB, 24h MaxAge) so verdicts survive core outages >30m. **Fresh installs converge automatically** (nothing owns the subject, EventWriter creates the stream on boot). **Existing deployments — demo included — do not**: the `events` stream still owns `signals.analytics.>`, JetStream forbids subject overlap across streams, so core logs `Requested stream not matched by subject; using discovered stream` and keeps consuming from `events` (30m MaxAge) until an operator releases the subject.

Run in order, from the authed `nats` CLI in the `serviceradar-tools` pod. Keep the gap between steps 1 and 2 short: while no stream owns the subject, correlation-engine JetStream publishes error out and the addon-spine's plain publishes are dropped (episodes re-confirm within minutes once the stream exists).

```
# 0. Confirm current ownership (expect signals.analytics.> in the subject list)
kubectl exec -n demo serviceradar-tools -- nats stream info events

# 1. Release the subject: re-set the events subject list to the step-0 list MINUS
#    signals.analytics.>. With the current demo list that is:
kubectl exec -n demo serviceradar-tools -- nats stream edit events -f \
  --subjects "events.>,logs.>,otel.traces.>,otel.metrics.>,pdns.ocsf,pdns.ocsf.>,falco.logs"
#    (drop falco.logs from the list only if step 0 does not show it)

# 2. Restart core so EventWriter provisions the dedicated stream and moves the durable
kubectl rollout restart -n demo deploy/serviceradar-core

# 3. Verify stream + durable
kubectl exec -n demo serviceradar-tools -- nats stream info analytics_predictions
#    expect: subject signals.analytics.predictions.>, limits/file/discard-old,
#    MaxBytes 1 GiB, MaxAge 24h
kubectl exec -n demo serviceradar-tools -- nats consumer info analytics_predictions \
  serviceradar-event-writer-analytics-predictions

# 4. Remove the orphaned durable left behind on the events stream
kubectl exec -n demo serviceradar-tools -- nats consumer rm events \
  serviceradar-event-writer-analytics-predictions -f
```

Nothing re-adds the subject afterwards: the helm `serviceradar-config.yaml` events subject list no longer includes `signals.analytics.>` (this change), and the otel collector's reconciler only removes subjects covered by its own wildcards. Verdicts already sitting in `events` under `signals.analytics.*` age out via that stream's retention; the new stream starts from new publishes.

### 7.2 Consumer ownership and retired-attribution cleanup

- `falco_events` fixes itself with this release: the core_elx FALCO consumer was realigned to the provisioned `events` stream / `falco.logs` subject (was `falco_events` / `falco.>`, which never exists). Verify the 404 polls stop post-roll; if a stale `falco_events` stream exists, `nats stream rm falco_events -f` and restart core so the durable converges onto `events`.
- Task 8.3 left `ATTRIBUTED_FLOW` as-is; its checked state is not evidence that this cleanup happened. After task 8.3a lands, verify the release no longer registers `flow.attributed.>` and the associated 404 poll does not return after a core restart. The subject has no production publisher or supported consumer: do not create a stream or durable to silence the error.
- If an orphan `attributed_flow` stream or attributed-flow durable exists, first verify that it is empty and scoped only to the retired `flow.attributed.>` canary namespace, then remove it after the release registration is absent. The string `attributed_flow` remains valid as the CNPG OCSF row's `event_type`; it is not a NATS route.
- Do not remove or provision `NETFLOW_RAW` / `SFLOW_RAW` here. They are logical EventWriter consumer names for the active raw subjects `flows.raw.netflow` / `flows.raw.sflow`, and `scale-netflow-ingest-isolation` owns their dedicated `flows` stream migration, obsolete-`events` durable drain, and rollback checks.
