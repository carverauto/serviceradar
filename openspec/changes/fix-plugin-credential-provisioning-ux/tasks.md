# Tasks — fix-plugin-credential-provisioning-ux

## 1. Unlock camera credential rules in the UI (hotfix tier)
- [x] 1.1 `network_credential_rules_live.ex`: include `api_key` in auth methods (:21) and `camera_inventory`/`camera_stream` in purposes (:22); provider presets for `unifi-protect` and `axis` (defaults, target-query templates) alongside proxmox
- [x] 1.2 Camera/API-key secret creation modal (parity with Proxmox-token and SSH modals; stop hardcoding `provider: "proxmox"` in `normalize_secret_params`)
- [x] 1.3 Rewrite page copy to be provider-neutral (currently proxmox-specific)
- [ ] 1.4 On demo: create the UniFi Protect rule, verify the materializer emits `serviceradar.plugin_inputs.v1` assignments, camera checks go green, and the camera dashboard tiles resolve
- [x] 1.5 Regression test: camera rule → materialized envelope → unifi-protect `decodeConfig` per-target host derivation succeeds

## 2. Proxmox materialization regression
- [x] 2.1 Diagnose why Proxmox Inventory reports "API token is required" with an enabled rule + running reconciler (manual assignment shadowing? grant refresh failure? `35f7716d9` regression? untested secret?)
- [x] 2.2 Fix + pinned regression test (rule → materialized inputs → plugin decode) for both proxmox and camera profiles
- [ ] 2.3 Rule "Test" action wired for all providers (page currently shows "Not tested" with no signal)

## 3. Materialization observability
- [x] 3.1 Reconcile logs/telemetry carry counts: rules matched, targets resolved, assignments written, skips with reasons (replace count-free "Reconciled X credential rules")
- [x] 3.2 Per-rule materialization status on the rules page: which agents/plugins the rule currently feeds, last materialized at
- [x] 3.3 "Effective inputs" preview: rule + SRQL targets → rendered plugin_inputs envelope (debugging surface)

## 4. Assignment-time validation
- [x] 4.1 Schema annotation (`x-serviceradar-credential-materialized`) on camera `host` and analogous fields; republish camera plugins
- [x] 4.2 `plugin_config_form.ex`: render annotated fields as "provided by credential rules" (not silently hidden/optional); enforce schema `required` arrays where present
- [x] 4.3 Assignment save: warn (override-able, persistent) when annotated inputs have no enabled matching rule for the target agent; surface the same warning in plugin health/fleet views
- [x] 4.4 Wire the ratified "Auth metadata and credential linkage validation" requirement for camera schemas (auth-required stream without credential reference fails validation)

## 5. Credential push-down unification
- [ ] 5.1 Spec + implement per-provider `resolution_location` flag defaulting to current behavior; move `unifi-protect`/`axis` profiles to `:agent` live resolution where the plugin runtime supports it
- [ ] 5.2 Verify in-memory-only handling on the agent (no secret material in persisted config for `:agent` providers); short grant TTLs for remaining `:control_plane` providers
- [ ] 5.3 Document the model + exceptions for provider-profile authors

## 6. Camera dashboard coherence
- [ ] 6.1 Split "Available" into labeled dimensions: inventory-available vs stream-operable (relay/agent state); combined health chip with reason ("available, not streamable: agent offline")
- [ ] 6.2 Reconcile the three sources (`camera_sources.availability_status`, live relay resolution, `camera_relay_sessions`) or label their provenance in the panel
- [ ] 6.3 Playwright: panel never shows green Available beside "Agent offline" without the explanatory state
