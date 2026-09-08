# Design — fix-plugin-credential-provisioning-ux

## Context

Investigation 2026-07-04 (live demo + v1.4.0 source), key verified facts:

- The credential-rule **data model is already provider-general**:
  `network_credential_rule.ex` — free-string `provider` (:191), purposes incl.
  `:camera_inventory`/`:camera_stream` (:211-224), `auth_method` incl.
  `:api_key` (:197-209), SRQL `target_query` (:226), `priority` +
  `enabled_for_scope` ordering (:82-93), scope agent/gateway/partition
  (:232-242).
- The **materializer is generalized and shipped** (v1.4.0):
  `plugin_assignment_materializer.ex` over `CredentialProviderProfile`
  behaviour; camera entry points `reconcile_camera_{inventory,stream}_for_agent`
  (:58-71); profiles for proxmox/unifi-protect/axis; camera reconcile worker
  scheduled and running on demo ("Reconciled camera credential rules" —
  count-free info logs).
- The **camera envelope-host fix is shipped**: `6efada817` — unifi-protect
  `config_envelope.go` `decodeConfig` accepts flat config OR
  `serviceradar.plugin_inputs.v1` envelope with per-target host derivation
  (:82-135); `config.schema.json` hides `host`
  (`x-serviceradar-ui-hidden`, no `required` array).
- The **UI is the blocker**: `network_credential_rules_live.ex` — auth methods
  without `api_key` (:21), purposes without camera values (:22), proxmox-only
  secret modals (:133-139, :860, :886), proxmox-seeded defaults (:909, :929).
  No camera rule can be created → no materialized envelope → the flat-config
  path hits `cfg.Host == ""` → "host is required"
  (`go/cmd/wasm-plugins/unifi-protect/main.go:24-27,121-125`).
- **Push-down split**: proxmox `resolution_location: :agent` → live gateway
  RPC resolution, material in agent memory for action-mode HTTP inject
  (`credential_broker_resolver.go:31-60`); cameras
  `resolution_location: :control_plane` (`camera_profile_helpers.ex:13-36`) →
  secret resolved at config-gen and delivered inside the pushed agent config
  (`credential_broker_delivery.ex`).
- **Dashboard split-brain**: `camera_panel.ex:30` "Available" ←
  `platform.camera_sources.availability_status` (`data/camera.ex:7-41`);
  tile captions ← live `CameraMultiview.open_preview_tiles/2` relay
  resolution (`index.ex:215-221`, error mapping `camera_panel.ex:151-166`);
  "Recording" ← `platform.camera_relay_sessions` (`data/camera.ex:54-74`).
  Three sources, no reconciliation.
- **Proxmox regression open question**: rule exists + enabled ("Not tested"),
  reconciler runs, plugins still report "Proxmox API token is required" for
  every PVE target. Candidate causes to test during implementation: manual
  flat-config assignment shadowing/racing the materialized policy assignment;
  grant refresh failure at config-gen (`refresh_embedded_grant`); regression
  from the 2026-06-30 generalization (`35f7716d9`); or the rule's secret
  failing resolution (never tested).

## Goals / Non-Goals

- Goals:
  - An operator can create a working UniFi Protect / Axis credential rule
    entirely in the UI, and cameras stream without hand-editing configs.
  - Misconfiguration is visible at assignment time (or on the rule/fleet
    pages), never only as runtime check failures.
  - Materialization is observable: counts, skip reasons, per-rule status.
  - One documented credential push-down model with explicit, justified
    exceptions.
- Non-Goals:
  - The full provider-neutral credentials UI overhaul
    (`refactor-unified-credential-management` owns it).
  - New camera features (streaming, events — ratified camera specs own those).
  - Non-plugin credential consumers (discovery/SNMP profiles).

## Decisions

- **Decision: unlock the existing model in the existing LiveView rather than
  wait for the unified-credentials overhaul.** The rules page needs option
  lists + secret modals + presets — small, shippable, unblocks cameras now;
  the unified change (0/21, unstarted) can absorb it later. Alternative —
  block on the overhaul — leaves cameras dead indefinitely.
- **Decision: schema-driven "provided by credential rules" annotation.**
  Extend plugin config schemas with the existing `x-serviceradar-*` vendor
  keys (e.g. `x-serviceradar-credential-materialized: true`) so the assignment
  form can render the field state and the validator can check rule coverage,
  instead of hardcoding per-plugin knowledge in the UI.
- **Decision: assignment-time rule-coverage check is a warning that can be
  overridden, not a hard block** — a rule may be created after the
  assignment; blocking would force ordering. The warning persists on the
  assignment (and plugin health) until a matching rule materializes.
- **Decision: target the agent-side live-resolution model for cameras too,
  flag-gated per provider profile.** The broker resolver already exists
  agent-side; camera profiles move `resolution_location` to `:agent` where the
  plugin runtime can perform the inject/fetch. Where a provider genuinely
  cannot (documented constraint), `:control_plane` remains but the spec names
  it and grants stay short-TTL. Alternative — spec the status quo — leaves
  secrets baked in configs, which contradicts the platform's stated model.
- **Decision: dashboard shows two labeled dimensions, not one merged
  boolean.** Availability (inventory) and stream-operability (relay/agent)
  are genuinely different facts; the fix is explicit labeling + a combined
  health chip ("available, not streamable: agent offline"), not forcing one
  source to win silently.

## Risks / Trade-offs

- Unlocking `api_key`/camera purposes in the rules UI before the unified
  overhaul creates a second UI iteration later → acceptable; the overhaul is
  unstarted and cameras are dead today.
- Moving camera resolution agent-side changes the secret exposure surface
  (agent memory vs config file) → net improvement; gate per provider and keep
  grant TTLs short.
- Schema annotations require plugin re-publish → camera plugins already
  re-published for the envelope fix; piggyback on the same pipeline.

## Migration Plan

1. UI unlock (auth methods, purposes, camera secret modal, presets) +
   materialization observability counts. Create the demo camera rule; verify
   UniFi Protect checks go green and the envelope path engages.
2. Diagnose/fix the Proxmox materialization regression with a pinned
   rule→inputs→decode regression test.
3. Assignment-time validation + schema annotations + camera plugin republish.
4. Push-down unification behind per-provider flags; camera providers first.
5. Dashboard coherence.
Rollback: each step independent; step 4 flags default to current behavior.

## Open Questions

- Should credential rules and plugin assignments share one "effective inputs"
  preview (rule + SRQL targets + assignment → rendered plugin_inputs
  envelope) for debugging? (Likely yes — it would have made this outage
  diagnosable in minutes.)
- Does the AWX/`base_url` failure family belong to this change (credential
  rules for AWX) or to `add-ansible-integration` (0/91)? Provisionally: the
  validation/observability requirements here apply to all plugins; AWX
  presets belong to `refactor-unified-credential-management`.
