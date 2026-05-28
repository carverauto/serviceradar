# Tasks: Add agent feature sets (native add-on framework)

> Scope: build the framework/contract. Migrating Bumblebee,
> host-network-visibility/netprobe, and remote-access onto the contract is tracked
> in follow-up changes owned by the maintainer.

## 1. Manifest & in-repo registry
- [ ] 1.1 Define the `addon.yaml` manifest schema (id, name, version, kind,
  delivery, supervision, capabilities, requires, artifacts, exec, state_dirs,
  config_schema) and a JSON-Schema validator for it.
- [ ] 1.2 Establish the `addons/<id>/` source layout convention
  (`addon.yaml`, `config.schema.json`, sources, `BUILD.bazel`, `README.md`).
- [ ] 1.3 Add `build/native_addons/addon_inventory.bzl` (analogous to
  `build/wasm_plugins/plugin_inventory.bzl`) listing build targets + bundle
  definitions per add-on.
- [ ] 1.4 Document the author checklist (mirror the WASM plugin author flow).

## 2. Build, signing & discovery (capability: native-addon-builds)
- [ ] 2.1 Bazel rules to build per-`(os, arch)` add-on binaries and assemble a
  deterministic bundle + `sha256` + `metadata.json` per arch.
- [ ] 2.2 Reuse `scripts/cosign_common.sh` to Cosign-sign the OCI artifact (Rekor
  tlog by default); add the native-addon media-type constant and (recommended) a
  distinct `COSIGN_KEY_REF` (e.g. `hashivault://cosign-native-addons`).
- [ ] 2.3 Reuse the ed25519 upload-signature tool with a native-addon key id; fail
  the build closed if signing keys are unset.
- [ ] 2.4 Generate `serviceradar-native-addon-index.json` (per-arch digests) and
  publish it as a release asset; add a release-job presence assertion.
- [ ] 2.5 Verify-before-release job (digest + Cosign + upload-signature).
- [ ] 2.6 Confirm no signing keys/secrets are committed; only public trust material.

## 3. Base / add-on packaging boundary
- [ ] 3.1 Carve the base `serviceradar-agent` package to contain only the core
  agent (no optional capability binaries baked in via alternate targets).
- [ ] 3.2 Define the signed `pushed-artifact` tarball format and the optional
  `os-package` add-on package template (depends on `serviceradar-agent`, dormant on
  install).
- [ ] 3.3 Keep the arch field real (amd64 now; arm64 additive without contract
  changes).

## 4. Control-plane catalog (Ash, core-elx)
- [ ] 4.1 `AddonPackage` resource (staged→approved→revoked state machine,
  provenance, per-arch artifacts, delivery/supervision/requires metadata,
  config schema). Migration in `platform` schema.
- [ ] 4.2 `AddonAssignment` resource (target = agent uid | cohort, enabled,
  validated params, overrides). Block assigning non-approved packages.
- [ ] 4.3 (If first-class) feature-set bundle resource grouping add-ons; else a
  UI-side grouping.
- [ ] 4.4 Importer: reuse the WASM verify-then-mirror pipeline (trusted-host
  allowlist, bounded fetch, digest + Cosign + upload-signature) for the native-addon
  index; mirror artifacts into ServiceRadar object storage.

## 5. Config compilation & delivery
- [ ] 5.1 Add a typed `AddonAssignmentConfig` (repeated) to
  `AgentConfigResponse` in `proto/monitoring.proto`.
- [ ] 5.2 `AgentConfigGenerator`: load enabled+approved assignments for the agent,
  select the per-arch artifact, emit the typed section, include it in the
  `config_version` hash, and gate inclusion on agent capability/deliverability.
- [ ] 5.3 `DependencyCatalog` entry binding `AddonAssignment` →
  `config_type: :addon`, affected-agents resolver, dispatch `:push_affected_agents`;
  declare any `secret_fields`.
- [ ] 5.4 `AgentCommandBus` mapping for the add-on config type (capability filter for
  targeted push).

## 6. Agent-side delivery & supervision
- [ ] 6.1 Agent add-on manager: dispatch an assignment to its delivery model
  (config-toggle / pushed-artifact fetch+verify+activate / os-package activate).
- [ ] 6.2 Generalize `go/pkg/agent/sidecar/manager.go` from a fixed boot-time list +
  wholesale start/stop to per-add-on dynamic registration with independent
  enable/disable.
- [ ] 6.3 `pushed-artifact` activation: reuse `release_runtime.go` staged-dir +
  `current`-symlink + rollback; verify sha256 + signature; apply file capabilities
  per `requires.os_capabilities` via the root-owned `agent-updater`.
- [ ] 6.4 Wire the supervision models: `agent-sidecar` (UDS), `systemd-service`,
  `systemd-timer` (spool ingest), `ephemeral-helper`, `config-toggle`.
- [ ] 6.5 Last-known-good cache + local override for add-on assignments (mirror the
  existing config override/cache pattern).

## 7. Reporting & reconciliation
- [ ] 7.1 Extend the `agent_capabilities` StatusResponse + `SidecarStatus` to report
  per-add-on installed/available/active/unhealthy + degradation reason and arch.
- [ ] 7.2 Surface installed/active add-ons per agent in the agent registry read model
  (and SRQL where relevant).

## 8. Edge Ops UI (web-ng)
- [ ] 8.1 New "Add-ons / Feature Sets" surface under Settings > Agents (sub-nav +
  route), gated by an edge-management permission.
- [ ] 8.2 Available-add-on catalog panel (reuse the first-party discovery panel) +
  approval review.
- [ ] 8.3 Config form from `config.schema.json` (reuse `PluginConfigForm`).
- [ ] 8.4 Target selection: per-agent (assign-to-agent form) and per-cohort
  (reuse the release cohort + compatibility-preview pattern).
- [ ] 8.5 Per-agent detail: show assigned vs. installed vs. active add-ons + drift.
- [ ] 8.6 Deploy-time: allow selecting an initial feature set in the onboarding
  package flow.

## 9. Reference-consumer validation (contract proof, not migration)
- [ ] 9.1 Author an `addon.yaml` for each reference consumer (remote-access =
  compiled-in/config-toggle; Bumblebee = os-package/systemd-timer; fingerprintd =
  pushed-artifact/agent-sidecar) and confirm the contract expresses each without
  gaps.

## 10. Validation & docs
- [ ] 10.1 `openspec validate add-agent-feature-sets --strict` passes.
- [ ] 10.2 Author/operator docs: how to publish an add-on; how to select/target
  feature sets in Edge Ops.
- [ ] 10.3 Coordination notes for migrating Bumblebee / host-network-visibility /
  remote-access onto the contract (follow-up changes).
