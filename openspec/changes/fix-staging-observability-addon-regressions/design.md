## Context

Live-verified root causes from three parallel investigations (transcripts: `staging-regression-rootcause`, `endpoint-software-pipeline-deepdive`, `native-addon-supply-chain-audit`). Deployed demo = v1.3.3. Tenant schema = `platform` on cnpg-21 (primary). Working tree carries `jj poslmosr` (sysmon process-metrics visibility — correct, keep).

## Confirmed root causes (evidence)

### Capacity forecasting — `capacity_forecasting/{model,source,worker}.ex`
Five coupled bugs producing 8e8% projections, past-dated and year‑5256 exhaustion:
- **Counter-reset contamination (dominant):** `interface_rate` source forecasts `avg_rate_per_second` of monotonic SNMP octet counters; the hourly CAGG has wrap/reset spikes (live max `1.728e14` B/s = 138,319,944% util at 1Gbps vs ~1% normally). Conversion to `utilization_percent` (`interface_capacity.ex:60`) is correct, but the spike poisons Holt-Winters `level`/`trend` (`model.ex:131,313-322`) → projects 6e8–8.4e8% over the 90-day horizon. `current_value` (`List.last`) is clean (~0.04%), hence the current≈0.04 vs projected≈8e8 tell.
- **Exhaustion in the past:** `seasonal_exhaustion_at` (`model.ex:277-295`) returns the first in-window step ≥ threshold (already crossed) and `exhaustion_at` (`model.ex:256`) returns the last-sample timestamp when crossed in-window → renders a past date (8 live rows ≤ `forecasted_at`).
- **Year 5256 / no horizon cap:** `exhaustion_at` (`model.ex:249-262`) computes `cross_x=(threshold-intercept)/slope` with no bound; near-zero slope → `cross_x≈1.0e11s` → `DateTime.add` → 5256-01-19.
- **Self-inconsistent units** and **699 `unsupported_interface_metric`** skips (broad query has no `metric_name` filter; `worker.ex:438` rejects non-octet); **286 `missing_interface_capacity`** (`speed_bps=0` on 247,490 `discovered_interfaces`).

Fix: cap exhaustion to `[now, now+horizon]`→`nil` outside; reject/winsorize counter-reset samples (>~100–200% util on a bounded metric is definitionally a counter artifact); clamp implausible `projected_value`; add a `metric_name` filter to the source query.

### Anomaly = 0 — `anomaly_detection/config.ex` + helm
`metrics.sysmon.*` (3 tokens) never matches the gateway's 4-token `metrics.sysmon.{type}.{name}` subject (`*` = exactly one token). Live: 14k+ sysmon samples in `timeseries_metrics`, but 0 `ocsf_events` class_uid 2004 from `anomaly_detection` (all 2108 are falco). Code already fixed on disk to `metrics.sysmon.>` by `jj poslmosr`. **Operational catch:** the existing JetStream durable `serviceradar-anomaly-analysis-metrics` was created with the broken `filter_subject`; NATS forbids changing it via `CONSUMER.UPDATE`, so a redeploy is inert until the durable is **deleted and recreated**. Code should detect `filter_subject` drift and recreate.

### Config churn — `agent/push_loop_config.go` + core push path
A control-stream re-apply *storm*, not version nondeterminism (live: version is deterministic, stable `v953b6eda` across polls). Mechanism: `applyConfigResponse` only short-circuits on `NotModified` (`push_loop_config.go:120`), never compares incoming `ConfigVersion` to the applied one; core always sets `not_modified:false` (`agent_config_generator.ex:222`) and `DependencyDispatcher` fans a full re-push to every online agent on **every** `AddonPackage`/`PluginPackage` write; the demo's otel-collector package "no approved package" reconcile flaps every few minutes → burst of re-pushes → full re-apply (sweep clear, sysmon, plugins, netprobe) + re-ACK each cycle. Fix: idempotent apply on equal version (still ACK), core push guard on acked version, dispatcher debounce. Plus the working-tree `sysmon_service.go` disabled-boot→enabled-remote collector-init fix.

### Endpoint inventory — the big one (two layers)
**Supply chain is healthy** (do NOT chase a "rebuild" theory): endpoint-inventory 0.1.1 (== HEAD source) built amd64+arm64, cosign/OpenBao-signed, published at v1.3.3, imported `verified`, `approved`, assigned to all 13 agents, and `addon_statuses` shows it **running** on the k8s node agents. The "1.2.99" the UI showed is the *agent* release banner, not the add-on version. `.forgejo/workflows/native-addons.yml` publish succeeded for v1.3.3.

**Layer 1 — activation (why nothing scans):**
- No real scan has *ever* been ingested demo-wide: 3 hand-seeded `upload_reason=validation` scans (synthetic PK `1111…`, fake `sha256:pve04-validation`, `artifact_count=1` with 0 artifacts, `state=completed` which `scan_state/1` can never emit, `scan_history=0`). The "487 vs 2" is seed column-vs-rows, **not** a runtime loss. The installed v0.1.1 collector run live yields 1296 packages, full SBOM, `upload_reason=changed` — agent does not truncate.
- The gateway generates a **disabled** `EndpointInventoryConfig` for every agent with no per-agent `endpoint_inventory` config row (`agent_config_generator.ex:2032-2048` → `enabled:false`); `endpoint_inventory_settings` is empty and the endpoint-inventory addon **profile reconciler never ran** (`last_reconciled_at=NULL`). Agent then writes `runtime.json {enabled:false}` and never starts the spool service.
- `sr-test-pve04`: systemd timer/service units are **not installed** (`/etc/systemd/system/serviceradar-endpoint-inventory*` absent) despite the staged binary → stopped/stale; plus corrupt string-typed assignment params for that agent.
- In-cluster `agent_id=k8s-agent` pod is **architecturally excluded** from native add-ons (`push_loop_addons.go:232`); the systemd **node** agents (`agent-k8s-cp2-worker1`) are **not** excluded — they run the add-on, just disabled. The `assignments:0` log is the **WASM plugin** count (red herring for native add-ons).
- `scalibr-endpoint-inventory 0.1.0` is published but **staged/unapproved** (only `netprobe`,`workload-identity` in `autoApproveAddonIds`) → zero assignments.

**Layer 2 — latent ingest correctness (will bite once real scans flow):**
- Scan `package_count` column is set from the collector's reported integer (`ingestor.ex:141`) and never reconciled to exploded rows → the column can lie.
- The collector omits the SBOM on `unchanged` (hash-gated) uploads (`collect.go:143-154`); core's `normalize_packages` then yields `[]`. The only guard (`package_replacement_noop?`, `ingestor.ex:611`) requires a prior `current` scan with matching hash — otherwise it explodes `[]` → 0 rows while stamping the high count.
- `promote_current` **replaces, not merges** (`ingestor.ex:497-528`): a smaller successful scan demotes all prior current rows → a 2-package upload wipes a 487-package inventory. `scan_state/1` defaults unknown states to `scanned` (successful), so partial/validation uploads trigger the wipe.

### Process listeners — `agent/addon_systemd.go`
Not a regression and not all hosts. The `serviceradar-netprobe` systemd sidecar that produces `local_processes.*` is **missing/inactive on 4/7 hosts** (`10.0.2.11/12/13`, `192.168.1.62`) — binary staged, `.service` unit never installed, no self-heal; the 3 cp2 hosts run it and report fresh snapshots (DB `lp_observed` matches netprobe state 1:1). Predates the merge. Fix: agent reconciles desired-vs-actual addon unit state.

### SNMP interface charts (farm01) — `device_live/interface_data.ex`
Not a bug. Read path + counter-rate math are correct (other devices show real MB/s). farm01's favorited interfaces are `if4` (oper down, flat counters) and `if46/47` (not in the polled set `{4,11,31,32,33}`); the busy interfaces `if31/33` are not favorited → faithful `0.0 B/s`. Fix is UX: surface down/no-data state. (Open: why `if46/47` aren't polled — separate agent-side SNMP discovery question.)

### Device identity / agent badge — `inventory/agent_link_repair_worker.ex` + web
Two defects: (1) tonka01's badge is **bad data** — two stale `ocsf_agents` rows (`agent-dusk`,`agent-agent-dusk`, host `192.168.2.22`) have `device_uid=tonka01`; status `unavailable` is excluded from `AgentLinkRepairWorker` repair statuses so it never heals. (2) the Software tab predicate is literally `is_map(device_row)` (`show_template.ex:469`) → always true, so it shows on every device; Process Listeners/MTR are already correctly gated.

## Goals / Non-Goals
- **Goals:** restore correct capacity/anomaly output; make endpoint software inventory actually run and ingest a *real* scan on at least the bare-metal + node agents; stop the config storm; self-heal addon systemd units; give operators fleet add-on visibility; gate agent-only UI to real agent hosts.
- **Non-Goals:** containerized endpoint inventory for the in-cluster `k8s-agent` pod (deliberate exclusion — separate product decision); rebuilding/republishing add-ons (supply chain is healthy); the broader DIRE reconciliation overhaul (only the targeted link-repair-status widening here); `speed_bps=0` inventory backfill.

## Risks / Trade-offs
- **Counter-reset rejection** could drop a legitimate spike — safe for a *bounded* percentage metric (anything >100% is a counter artifact); gate strictly to the interface octet path.
- **Idempotent config apply** must still send the `ConfigAck` on the control path or the gateway keeps retrying.
- **Endpoint enablement** adds periodic root-owned package scans (12h cadence) — modest IO.
- **Ingest no-wipe guard** must not block legitimate full replacements — key off `upload_reason`/coverage + presence of an SBOM/component list, and prefer rehydrating from the stored artifact blob over skipping.
- **Addon systemd reconciliation** runs privileged `systemctl` — keep unit-name path-safety guards, only touch addon-owned units, back off on crash loops.

## Open questions (verify during implementation — supply-chain agents partially disagreed)
- **Object-store 404 vs working delivery:** one agent observed a gateway `NOT_FOUND` for the endpoint-inventory blob + intermittent mTLS x509; another found delivery working on 11/12 hosts (running per `addon_statuses`). Likely the 404/x509 is the **WASM plugin-blob** path for the in-cluster pod, not the native add-on. **Verify** before asserting an artifact-integrity fix; if real, classify a persistent object-store 404 as a *permanent* delivery failure so it stops wedging the config ack.
- **Profile reconciler:** is `addon_profiles → addon_assignments` reconciliation (`last_reconciled_at=NULL`) the intended enable path, or are assignments meant to be created directly? PR6 must pick the canonical one.

## Migration / rollback
Each PR is independently revertible. Operational DB/host steps are idempotent and read-safe to verify. Never direct-push staging — land via PR or hand the host action to the user (`feedback_never_push_staging`); after branching from `origin/staging` use explicit refspec `X:refs/heads/X` (`feedback_worktree_push_upstream_gotcha`); update bazel BUILD for new Go imports/test files (`feedback_bazel_build_deps_vs_gotest`).
