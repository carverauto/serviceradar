# Tasks — stacked PRs (jj, off `update/plugin`)

Each `## N.` is one small, independently reviewable stacked PR. Build/test with `.agents/skills` codex skills (no release). Verify live on demo (cnpg-21 psql, ssh `192.168.1.62`/`10.0.2.8`). Order = dependency/value; PR1–PR3 are independent and land first.

## 1. PR1 — capacity-forecast math (`fix(capacity): bound exhaustion projections and reject SNMP counter-reset contamination`) — **IMPLEMENTED** (jj `fix-capacity-forecast-math`, 30 tests pass)
- [x] 1.1 `model.ex`: `exhaustion_at` already-crossed-in-window → `nil` (no past date); crossing beyond a generous multiple (10×) of the horizon → `nil` (kills year-5256), preserving plausible beyond-horizon crossings the worker's warning-horizon logic needs
- [x] 1.2 `worker.ex`: drop converted interface utilization above a sane ceiling (counter-wrap artifacts) before the model sees them; clamp implausible `projected_value` (>10× threshold) → skip `implausible_projection`
- [ ] 1.3 `source.ex`: add `metric_name` filter to the interface source query → eliminate 699 `unsupported_interface_metric` rows — **DEFERRED** (kept PR1 surgical; SRQL IN/OR predicate needs verifying; the 699 are harmless skipped rows, not user-facing garbage)
- [ ] 1.4 `worker.ex`: clearer `speed_bps=0` skip reason / unit metadata — **DEFERRED** (already skipped as `missing_interface_capacity`; cosmetic)
- [x] 1.5 tests: counter-wrap spike must not project > threshold (`worker_test` `InterfaceWrapRunner`); near-zero slope → `nil`; already-crossed in-window → `nil` (`model_test`)
- [ ] 1.6 verify live: local `mix test` ✅ (30 pass); after deploy, `SELECT count(*) FROM platform.capacity_forecasts WHERE status='projected' AND (projected_value>10*exhaustion_threshold OR projected_exhaustion_at<=forecasted_at OR projected_exhaustion_at>forecasted_at+(horizon_seconds||' seconds')::interval)` = 0 — **PENDING DEPLOY**

## 2. PR2 — device-detail UI gating + contrast (`fix(web-ng): gate Software tab to agent hosts; fix warning banner contrast`) — **IMPLEMENTED** (jj `fix-device-detail-ui`, compiles + formatted)
- [x] 2.1 `show_template.ex`: `software_tab_visible?/2` now gates on `DeviceStateData.agent?(device_row)` (ocsf_agents flag, same as the bolt badge) + real inventory/error fallbacks; dropped the always-true `is_map` and the wrong `agent_id`-based `device_has_agent?` clauses. Render guard `:268` already reuses `@software_tab_visible`.
- [x] 2.2 `endpoint_inventory_components.ex`: `text-warning-content` → `text-warning` in `software_state_class(:warning)` (`:881`) and the inline row-mismatch banner (`:72`)
- [ ] 2.3 `device_live_test.exs`: non-agent router omits the Software tab — **FOLLOW-UP** (DB-gated `SERVICERADAR_REQUIRE_DB_TESTS=1`; the `agent?` predicate is already covered by the existing "marks only registered agent devices with bolt" case)
- [ ] 2.4 verify: web-ng compiles ✅ + `mix format` ✅; live screenshots of farm01 (no Software tab) + an agent host — **PENDING DEPLOY**

## 3. PR3 — anomaly sysmon subject + durable recreation (`fix(anomaly): terminal metrics.sysmon.> wildcard + recreate stale durable`)
- [ ] 3.1 confirm `config.ex` default stream + `values-demo.yaml` enabledSubjects use `metrics.sysmon.>` (done by `jj poslmosr` — own/verify)
- [ ] 3.2 detect `filter_subject` drift on the existing durable and delete+recreate (NATS can't `CONSUMER.UPDATE` `filter_subject`); document the operational step
- [ ] 3.3 tests: `config_test.exs`/`pipeline_test.exs` assert `subject_enabled?("metrics.sysmon.cpu.cpu_usage_percent")` and stream subject `metrics.sysmon.>`
- [ ] 3.4 **operational**: delete durable `serviceradar-anomaly-analysis-metrics`; verify core logs show `sysmon:*` ContextOwner series and `ocsf_events` class_uid 2004 from `anomaly_detection` > 0

## 4. PR4 — agent config re-apply storm + sysmon collector init (`fix(agent): idempotent config apply; disabled-boot sysmon init`)
- [ ] 4.1 `push_loop_config.go`: skip full re-apply when incoming `ConfigVersion == applied` (still send `ConfigAck`)
- [ ] 4.2 `agent_command_bus.ex` / `dependency_dispatcher.ex`: guard core push on the agent's acked version; debounce/coalesce dependency fan-out
- [ ] 4.3 include working-tree `sysmon_service.go` disabled-boot→enabled-remote collector create + idempotency guard
- [ ] 4.4 tests: Go version-guard unit (unchanged version → no re-apply, still ACKs); `mix test` for agent_command_bus
- [ ] 4.5 verify live (10.0.2.8): `journalctl -u serviceradar-agent` "Applied new config" drops to ~1/real-change; "collector not initialized" gone; `sysmon.process` series appear. Update bazel BUILD if imports change

## 5. PR5 — addon systemd self-heal (`fix(agent): reconcile addon systemd units so process-listeners self-heal`)
- [ ] 5.1 `addon_systemd.go`/addon delivery: on each delivery/heartbeat, if an enabled addon's `.service`/`.timer` is missing or inactive, re-install+enable+restart (backoff; only addon-owned units; keep path-safety guards)
- [ ] 5.2 tests: reconcile re-creates a missing unit, no-ops a healthy one, backs off a crash loop
- [ ] 5.3 **operational**: re-install netprobe unit on `10.0.2.11/12/13` + `192.168.1.62`; verify `local_processes.observed_at` refreshes + Process Listeners tab shows fresh snapshot

## 6. PR6 — endpoint-inventory enablement + delivery (`fix(endpoint-inventory): deliver per-agent enablement so agents actually scan`)
- [ ] 6.1 provide enabled `endpoint_inventory` config for node/bare-metal agents (canonical path: per-agent config row and/or addon-profile reconcile — pick one, see design Open Questions)
- [ ] 6.2 fix delivery so an enabled config reaches the agent (`delivery_count` stuck at 0, `runtime.json` never flips to `enabled:true`)
- [ ] 6.3 fix corrupt string-typed assignment params for `agent-sr-test-pve04`; emit typed bool/int/array
- [ ] 6.4 helm `values-demo.yaml`: add `scalibr-endpoint-inventory` to `nativeAddonImport.autoApproveAddonIds` **iff** it is meant to roll out (else document staged)
- [ ] 6.5 **verify object-store delivery** (design Open Question): confirm the endpoint-inventory blob resolves; if a persistent 404, classify as permanent failure so it stops wedging the config ack
- [ ] 6.6 **operational**: enable + install `serviceradar-endpoint-inventory.timer` on target agents; confirm a real scan ingests (`upload_reason<>'validation'`, `package_count`≈rows, real artifact row)

## 7. PR7 — endpoint-inventory ingest hardening (`fix(endpoint-inventory): never wipe full inventory on partial/unchanged uploads; reconcile count`)
- [ ] 7.1 `ingestor.ex`: `unchanged` upload with no prior `current` scan → request a full upload or rehydrate rows from the stored SBOM artifact blob; never explode `[]`
- [ ] 7.2 `ingestor.ex`: `promote_current` merge-by-coordinate, not wholesale replace; do not treat partial/validation as fully successful (`scan_state/1` default)
- [ ] 7.3 `ingestor.ex`: reconcile scan `package_count` to actual exploded current rows (or store reported vs loaded distinctly)
- [ ] 7.4 `go/pkg/endpointinventory/collect.go`: set `CollectorVersion` on the legacy collector (kill 1.2.99/0.1.1 confusion)
- [ ] 7.5 tests: synthetic unchanged-no-prior-current payload must not write 0 rows over a prior full set; partial scan must not wipe; count reconciliation
- [ ] 7.6 **operational**: remove the 3 hand-seeded `upload_reason='validation'` scan rows

## 8. PR8 — add-on fleet reporting (`feat(addons): fleet view of which agent runs which add-on at which version/hash/state`)
- [ ] 8.1 SRQL/Ash read surface over `addon_packages` + `addon_assignments` + `addon_statuses`: agent × add-on × version × content-hash/digest × approved × assigned × running/active × last_delivered_at × last status report (+ last scan for collectors)
- [ ] 8.2 web page (daisyUI) listing the fleet matrix with filters (per-agent, per-add-on, stale/mismatched), surfacing `delivery_count=0` / unit-missing / version-drift
- [ ] 8.3 tests + live screenshot of the demo fleet (must show endpoint-inventory 0.1.1 running on node agents, stopped on pve04, scalibr staged)

## 9. PR9 — SNMP interface chart UX (`fix(web-ng): explain down/no-data interfaces instead of silent 0.0 B/s`)
- [ ] 9.1 `interface_data.ex`/`interface_components.ex`: distinguish oper-down (`discovered_interfaces.if_oper_status=2`), empty SRQL result (uncollected), and real idle 0 B/s
- [ ] 9.2 test + live: favorite farm01 `if31` → ~2–3 MB/s renders; `if4` shows "interface down"

## 10. PR10 — agent-host link integrity (`fix(identity): repair stale unavailable agent links so routers lose the Agent badge`)
- [ ] 10.1 `agent_link_repair_worker.ex`: widen repair to re-verify `unavailable`/`stale` agents (or one-shot remediation) and repoint/tombstone `device_uid` mislinks
- [ ] 10.2 test + live: `ocsf_agents` JOIN for tonka01 returns 0 rows after remediation (badge gone); coordinate with DIRE owners

## Live progress (2026-06-15, autonomous run)
- PR1 capacity — **IMPLEMENTED+PUSHED** PR #3835 (30 tests pass)
- PR2 device-detail UI — **IMPLEMENTED+PUSHED** PR #3836 (compiles/formatted)
- PR3 anomaly durable recreate — **IMPLEMENTED+PUSHED** PR #3837 (5 tests pass)
- PR4 agent config re-apply storm — **IMPLEMENTED+PUSHED** PR #3838 (go test pass)
- PR5 addon systemd self-heal — **IMPLEMENTED+PUSHED** PR #3839 (full agent suite pass)
- PR6 endpoint enablement — **IMPLEMENTED+PUSHED** PR #3840 (compiles; DB tests gated)
- PR7 endpoint ingest hardening — **DELEGATED** (background agent, branch fix-endpoint-inventory-ingest)
- PR8 add-on fleet reporting — TODO (data exists in addon_packages/assignments/statuses)
- PR9 SNMP interface UX — TODO (low priority; charts are technically correct)
- PR10 stale agent-link repair — **DEFERRED to DIRE**: the repair worker only follows tombstoned-device merges; a live-but-wrong link (tonka01) needs behavioral host-matching (DIRE domain, avoid hostname band-aids). PR2 already hides tonka01's Software tab; badge persists until the DIRE data fix.
- DEPLOY: core-elx + web-ng image build **IN PROGRESS** (background) from fix-endpoint-inventory-enablement tip → covers capacity/anomaly/endpoint/UI. Node-agent fixes (churn/sysmon/listeners) are release-gated (apt-upgrade), not deployable via image roll tonight.
- Stack (jj, off update/plugin): fix-sysmon-process-metrics-visibility(peer) ← fix-capacity-forecast-math ← fix-device-detail-ui ← fix-jetstream-durable-recreate ← fix-agent-config-reapply-storm ← fix-addon-systemd-self-heal ← fix-endpoint-inventory-enablement

## 11. Proposal hygiene
- [ ] 11.1 `openspec validate fix-staging-observability-addon-regressions --strict`
- [ ] 11.2 keep `tasks.md` checkboxes in sync as PRs land
