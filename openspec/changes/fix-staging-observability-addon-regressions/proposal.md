# Change: Fix post-#3829 staging regressions (observability engines + add-on delivery/activation)

## Why

After the protobuf metric-envelope cutover + #3796 anomaly/capacity engines merged to staging (#3829, deployed as v1.3.3), the demo (`demo.serviceradar.cloud`) shows a wall of broken observability and inventory features. Three parallel root-cause investigations (live-verified against the demo CNPG, the agent hosts, and the code) found that the breakage is **two themes**, not one:

1. **Observability-engine math/wiring bugs** introduced by the cutover (capacity forecasting, anomaly subject wildcard, agent config churn, sysmon collector init).
2. **Add-on/config delivery + activation gaps** that pre-date or are orthogonal to the cutover — and account for *most* of the "endpoint software / process listeners doesn't work" symptoms. The add-on supply chain (build → sign → publish → import → approve → assign) is actually **healthy** (v1.3.3 published, verified, assigned, running at 0.1.1); the failures are in **enablement config delivery**, **per-host systemd-unit supervision**, **scalibr add-on left staged/unapproved**, and **latent ingest correctness bugs**. There is currently **no fleet visibility** into which agent runs which add-on at which version/state — which is exactly why this took three deep investigations to see.

This proposal captures every confirmed issue, its root cause, and a remediation as a **small, independently reviewable stacked PR** (jj, off `update/plugin`), plus operational steps that must be applied to the live demo.

## What Changes

Each bullet is a stacked PR (see `tasks.md` for ordering and `design.md` for evidence). **BREAKING**: none — these restore intended behavior or add capabilities.

- **PR1 — capacity-forecast math** (`capacity_forecasting/model.ex,source.ex,worker.ex`): cap exhaustion to `[now, now+horizon]` (kills past dates + the year‑5256 dates), reject SNMP counter-reset/wrap spikes before forecasting, clamp implausible projections for bounded-percentage metrics, and restrict the interface source query to supported octet metrics (kills 699 `unsupported_interface_metric` churn rows).
- **PR2 — device-detail UI** (`device_live/show_template.ex`, `endpoint_inventory_components.ex`): gate the Software tab on a real *hosts-an-agent* predicate instead of `is_map(device_row)` (always true), and fix the warning-banner contrast (`text-warning-content` on `bg-warning/10` → `text-warning`).
- **PR3 — anomaly sysmon subject** (`anomaly_detection/config.ex`, `values-demo.yaml`): finalize `metrics.sysmon.>` (4-token) wildcard (already partly on disk) **and** add delete-and-recreate of the JetStream durable when its `filter_subject` no longer matches (NATS forbids `CONSUMER.UPDATE` of `filter_subject`).
- **PR4 — agent config re-apply storm** (`agent/push_loop_config.go`, `edge/agent_command_bus.ex`, `agent_config/dependency_dispatcher.ex`): make config apply idempotent on unchanged `ConfigVersion` (still ACK), guard the core push path on the agent's acked version, and debounce dependency-driven fan-out. Includes the working-tree disabled-boot→enabled-remote sysmon collector-init fix.
- **PR5 — addon systemd self-heal** (`agent/addon_systemd.go`, addon delivery): reconcile desired-vs-actual systemd unit state so an enabled add-on whose `.service`/`.timer` is missing/inactive is re-installed (fixes process-listeners going silent on 4/7 hosts where the netprobe unit vanished).
- **PR6 — endpoint-inventory enablement + delivery** (`edge/agent_config_generator.ex`, addon profile reconcile, helm `autoApproveAddonIds`): deliver per-agent `enabled:true` for node agents so the collector actually scans; promote `scalibr-endpoint-inventory` from staged→approved if it is meant to roll out; fix the corrupt string-typed assignment params for `agent-sr-test-pve04`.
- **PR7 — endpoint-inventory ingest hardening** (`inventory/endpoint_inventory_ingestor.ex`, `endpoint_inventory_package_set.ex`, `go/pkg/endpointinventory`): never let an `unchanged` upload with no prior `current` scan (or a partial scan) wipe a full inventory; reconcile the scan `package_count` column with actual exploded rows; set `CollectorVersion` on the legacy collector.
- **PR8 — add-on fleet reporting** (web + SRQL view over `addon_packages`/`addon_assignments`/`addon_statuses`): a fleet view of *agent × add-on × version × content-hash × enabled × assigned × running × last-delivered × last-scan*. The missing observability behind this whole effort.
- **PR9 — SNMP interface chart UX** (`device_live/interface_data.ex`, `interface_components.ex`): distinguish "interface down", "no SNMP samples in range", and "real 0 B/s idle" instead of a silent flat `0.0 B/s` (the farm01 charts are faithful; the favorited interfaces are down/uncollected).
- **PR10 — agent-host link integrity** (`inventory/agent_link_repair_worker.ex` + one-shot remediation): re-verify/repoint/tombstone stale `ocsf_agents.device_uid` links (status `unavailable` is currently never repaired) so a router (tonka01) stops showing the Agent badge at the source.

**Operational (applied to the live demo, not code):** delete the stale `serviceradar-anomaly-analysis-metrics` JetStream durable; remove the 3 hand-seeded `upload_reason=validation` scan rows; (re)install the netprobe systemd unit on `10.0.2.11/12/13` + `192.168.1.62`; enable + install the endpoint-inventory timer on the target agents.

## Impact

- **Affected specs:** `capacity-forecasting`, `anomaly-detection`, `native-addon-delivery`, `endpoint-inventory`, `agent-config`, `device-detail-ui` (delta files in this change).
- **Affected code:** `elixir/serviceradar_core/lib/serviceradar/observability/capacity_forecasting/*`, `.../observability/anomaly_detection/*`, `.../inventory/endpoint_inventory_*`, `.../edge/agent_config_generator.ex`, `.../edge/agent_command_bus.ex`, `.../agent_config/*`, `.../inventory/agent_link_repair_worker.ex`; `elixir/web-ng/.../device_live/*`; `go/pkg/agent/{push_loop_config.go,addon_systemd.go,sysmon_service.go,push_loop_addons.go}`, `go/pkg/endpointinventory/*`; `helm/serviceradar/values-demo.yaml`.
- **Deployment:** current demo is v1.3.3. Fixes verified locally via `.agents/skills` codex skills (no release); agents scp'd to test boxes (`192.168.1.62`, `10.0.2.8`) for live verification; demo rolled per `demo-local-rollout`.
- **Coordination:** overlaps the in-flight working-tree change `jj poslmosr` (sysmon process-metrics visibility — keep, it is correct), the metric-contract / dependency-catalog PR stack (#3788), and DIRE device-identity work (PR10's data half).
