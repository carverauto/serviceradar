# Change: Unblock credential-rule-driven plugin provisioning (camera providers, assignment-time validation, live push-down)

## Why

Most WASM plugins on the demo fleet fail at runtime with missing-config errors
(UniFi Protect Camera: `configuration error: host is required`; Proxmox
Inventory: `Proxmox API token is required` for every PVE target; AWX:
`base_url is required`) — and the failures are only discoverable after the
fact, as cryptic per-check FAILs. Investigation (2026-07-04, verified against
v1.4.0 and the live demo) found the runtime machinery largely EXISTS and is
DEPLOYED; what's broken is activation, validation, and legibility:

1. **The camera "host is required" fix shipped but cannot be activated.**
   `35f7716d9` (generalize plugin credential materializer to camera providers)
   and `6efada817` (camera plugins read host per-target from the
   `serviceradar.plugin_inputs.v1` envelope) are both in v1.4.0, and the
   camera reconcile workers run on demo ("Reconciled camera credential rules"
   in core logs). But the envelope path only engages when a **camera
   credential rule exists**, and the Settings UI cannot create one:
   `network_credential_rules_live.ex:21` hardcodes auth methods without
   `api_key`, `:22` hardcodes purposes without
   `camera_inventory`/`camera_stream`, and the secret modals only create
   Proxmox tokens or SSH keys (`:133-139, :860, :886`). The data model is
   already fully general (`network_credential_rule.ex`: free-string provider,
   camera purposes, `api_key` auth, SRQL `target_query`, priority, scoping) —
   the UI is the only blocker. Manual plugin assignments therefore deliver a
   flat config whose `host` is schema-hidden
   (`x-serviceradar-ui-hidden`, no `required` array) → runtime
   "host is required", forever.
2. **No assignment-time validation.** The plugin assignment form derives
   required-ness solely from the schema `required` array
   (`plugin_config_form.ex:25,91`); camera schemas have none, and nothing
   warns that a plugin expects credential-rule-materialized inputs that no
   rule currently provides for the target agent. The ratified requirement
   "Auth metadata and credential linkage validation"
   (`plugin-configuration-ui`) is never triggered because the schemas don't
   mark the fields. Operators discover misconfiguration only as runtime FAILs.
3. **The Proxmox plugin regressed from working to "API token is required"**
   despite an enabled proxmox rule (scope agent:agent-sr-test-pve04, "Not
   tested") and a running reconciler. Needs diagnosis: manual flat-config
   assignment shadowing the materialized policy, grant resolution failure, or
   a regression introduced by the 2026-06-30 materializer generalization.
   Reconcile logs are count-free ("Reconciled Proxmox credential rules") so
   no-ops are indistinguishable from real work.
4. **Split credential push-down models, undocumented.** Proxmox resolves
   grants live agent-side via gateway RPC with material held in memory
   (`resolution_location: :agent`, `go/pkg/agent/credential_broker_resolver.go`)
   — the desired model. Camera providers resolve at the control plane and
   **bake secrets into the pushed agent config**
   (`camera_profile_helpers.ex:30`, `credential_broker_delivery.ex`),
   contradicting the credentials-only-in-plugin-memory expectation. No spec
   documents either model or when each applies.
5. **Camera dashboard contradicts itself**: "Available 2" comes from
   `platform.camera_sources.availability_status` (inventory) while the same
   panel's tiles say "Agent offline" / "No relay" from live relay-session
   resolution (`camera_multiview.ex`) — two independent state sources with no
   reconciliation or explanation, so cameras read as simultaneously fine and
   broken.

## What Changes

- **Unlock credential rules for all modeled providers**: the credential-rules
  Settings UI exposes the full model — `api_key` auth, camera purposes,
  camera/API-key secret creation, provider presets for `unifi-protect` and
  `axis` (mirroring the proxmox preset), SRQL `target_query` first-class. The
  rules page becomes the credential **catalog**: rules list shows which
  plugins/agents each rule currently materializes for (consumer visibility).
- **Assignment-time validation**: plugin config schemas declare required and
  credential-linked fields; the assignment UI blocks (or loudly warns) when a
  plugin's inputs are expected from credential-rule materialization and no
  enabled rule matches the target agent; runtime-hidden fields (like camera
  `host`) display as "provided by credential rules" instead of silently absent.
- **Materialization observability**: reconcile logs/telemetry carry counts
  (rules matched, targets resolved, assignments written, skips with reasons);
  a rule's "Last Test" and per-rule materialization status are visible.
- **Diagnose and fix the Proxmox materialization regression** (worked →
  "API token is required"); add a regression test pinning rule → materialized
  inputs → plugin decode for both proxmox and camera profiles.
- **Unify (or explicitly spec) credential push-down**: extend agent-side live
  grant resolution (in-memory, per-execution) to camera providers where
  feasible; where control-plane resolution must remain, the spec states it
  and the constraint is documented — no silent secret-baking into configs.
- **Camera dashboard coherence**: availability and relay/agent state come from
  reconciled sources or are explicitly labeled (inventory-available vs
  stream-operable), never a green "Available" beside "Agent offline" without
  explanation.

## Impact

- Affected specs: `plugin-configuration-ui`, `wasm-plugin-system`,
  `camera-streaming`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/network_credential_rules_live.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/components/plugin_config_form.ex`
  - `elixir/serviceradar_core/lib/serviceradar/credentials/{plugin_assignment_materializer.ex,provider_profiles/*,credential_broker_delivery.ex}`
  - `go/cmd/wasm-plugins/{unifi-protect,axis}/` (schema annotations),
    `go/pkg/agent/credential_broker_resolver.go`
  - `elixir/web-ng/.../dashboard_live/index/camera_panel.ex`,
    `.../dashboard_live/data/camera.ex`, `camera_multiview.ex`
- Relationship to in-flight changes:
  - `refactor-unified-credential-management` (0/21, not started): owns the
    provider-neutral credentials UI vision (presets for AWX/Proxmox/SNMP/SSH/
    HTTP-token/username-password/certificate/opaque) but omits cameras,
    plugin materialization, and push-down semantics entirely. This change is
    scoped to *plugin activation* (camera presets, assignment-time validation,
    materialization visibility, push-down model). If that change starts first,
    fold this change's UI requirements into it as camera/plugin deltas; the
    `wasm-plugin-system` and `camera-streaming` deltas here stand regardless.
    This change deliberately writes NO `credential-management` capability
    deltas (that capability has no baseline until the unified change lands).
  - `add-proxmox-plugin-credential-rules` (58/58, complete): the proxmox-only
    origin of this subsystem; its spec deltas did not cover cameras.
- **BREAKING**: none. UI unlock + validation + observability; push-down
  unification is flag-gated per provider.
