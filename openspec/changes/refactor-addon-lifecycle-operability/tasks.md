# Tasks — refactor-addon-lifecycle-operability

## 1. Restore flow attribution (hotfix tier)
- [x] 1.1 Remediate corrupt string-typed `AddonAssignment.params` rows (`capture_interfaces` scalar string) — coordinate with `fix-staging-observability-addon-regressions` PR6.3 so it's done once
- [x] 1.2 Delivery-path coercion: wire schema-driven param coercion (`ConfigSchema.normalize_params` / `split_list`) into the deliverable-config path (`agent_config_generator.ex` `to_proto_addons`/`normalize_map`) so params are coerced against the package `config_schema` before `config_json` encoding
- [x] 1.3 Agent: tolerant `capture_interfaces` decoding in `go/pkg/agent/netprobe/config.go` (string → single-element []string with compatibility notice); unit tests for both forms
- [ ] 1.4 Roll fixed agent + core to demo; verify netprobe config applies, agent resumes config acks, `flow_process_attribution_current` repopulates

## 2. Sectioned config apply: specify + close the gaps
- [x] 2.1 Fix transient early-returns: a transient failure in the add-on-assignment or visibility sections (`push_loop_config.go:195-201,225-231`) no longer skips evaluating the remaining sections in the same cycle
- [x] 2.2 Permanent-failure state: persist (config_version, section, error, since) on the agent; re-evaluate only when the section payload hash changes; escalate once at error level (replaces per-cycle info/warn logs)
- [x] 2.3 Protocol: extend `ConfigAck` with per-section status (backward compatible: core treats ack-without-sections as legacy whole-version ack)
- [x] 2.4 Tests: wedge regressions for both incident shapes (Bumblebee staging permission-denied = transient path; netprobe params parse error = permanent path) proving other sections apply and acks flow

## 3. Config wedge detection + surfacing
- [x] 3.1 Gateway/core: persist per-agent last-acked config version + per-section status (replace debug-only logging in `control_stream_session.ex:226`)
- [x] 3.2 Config-health evaluation: connected agent with no ack within window, or reporting a permanent section failure → config-unhealthy; health events + telemetry on wedge/unwedge
- [x] 3.3 Synthesize unhealthy `AddonStatus` for config-apply failures (parity with `addonDeliveryFailureStatuses` for artifact failures) so a config-broken-but-running add-on stops reading as healthy in the fleet view
- [x] 3.4 web-ng: agent detail shows last-acked config version, per-section status, failing-section error verbatim with start time; fleet view surfaces config-unhealthy agents
- [ ] 3.5 Alert rule/runbook: config-unhealthy agents alarm instead of living in journald only

## 4. Typed add-on config contracts
- [x] 4.1 Enforce `AddonAssignmentParams` schema validation on every params write path (manual assignment, `addon_profile_reconciler.ex`, package seeders); backfill-validate legacy rows persisted before the guards existed; decide behavior for packages with empty `config_schema` (today validation silently skips)
- [x] 4.2 Delivery refuses uncoercible params with a visible per-assignment validation error (never ships known-undecodable `config_json`)
- [x] 4.3 CI: contract test suite decoding representative core-emitted `config_json` with the real Go decoders for all bundled add-ons (netprobe, otel-collector, anomaly, bumblebee, endpoint-inventory, workload-identity, rdp)
- [x] 4.4 Document compatibility-form rules (scalar→list coercion) for add-on authors

## 5. Add-on fleet UI overhaul (`addon_fleet_live` / `addon_fleet.ex`)
- [x] 5.1 Rework fleet read model presentation: one row per (agent, add-on) with assigned version, running version, health; historical/unassigned versions behind the add-on detail view
- [x] 5.2 Separate catalog-only inventory from fleet status (kill "— (catalog only)" rows in the fleet table)
- [x] 5.3 Drift rendering: comparison form ("running 0.1.19 → assigned 0.1.20"); suppressed when unassigned or unreported (never "drift: 0.0.0"); attention badges sized to content (no clipped text)
- [x] 5.4 Layout: fit 1440px without horizontal scroll; long diagnostics (e.g. "resource limits not enforced: …") expandable to full text in a detail drawer
- [x] 5.5 Playwright coverage: no horizontal overflow, no truncated badges, drift render rules, catalog-only separation

## 6. Catalog import UX (add-on catalog AND WASM plugin catalog "Plugins Manager")
- [x] 6.1 Import action reflects state (nothing-to-import → disabled/relabeled with count); idempotent server-side — both catalogs
- [x] 6.2 Progress indication while running + completion summary (imported / skipped / failed) — both catalogs
- [x] 6.3 Tests for repeated import (second run reports all-skipped, UI shows already-imported state) — both catalogs

## 7. Version presentation model
- [x] 7.1 Assignment/deploy flows preselect latest approved version; older versions only via add-on detail drill-in
- [x] 7.2 Explicit "up to date" indicator when running == latest approved
- [x] 7.3 Fleet/list views stop enumerating stale versions as peer rows

## 8. Rollout & verification
- [ ] 8.1 Ship tier-1 (1.x) to demo; confirm attribution restored and acks resume
- [ ] 8.2 Ship 2.x–4.x behind protocol-compat gating; verify mixed-version fleet (old agent + new core, new agent + old core)
- [ ] 8.3 Ship 5.x–7.x; before/after screenshots of catalog + fleet pages in the change record
