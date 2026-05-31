# Tasks: Add agent feature sets (native add-on framework)

> Scope: build the framework/contract. Migrating Bumblebee,
> host-network-visibility/netprobe, and remote-access onto the contract is tracked
> in follow-up changes owned by the maintainer.

> **Status (reconciled 2026-05-28 against the implementation on
> `feat/3425-agent-feature-sets-proposal`).** The `agent-sidecar` spine is complete
> and proven end to end; the remaining work is additive and carved into four
> follow-up changes: `add-native-addon-build-signing`, `add-native-addon-delivery-models`,
> `add-native-addon-rust-sdk`, `add-native-addon-edge-ops`. `[x]` = implemented;
> `[ ]` carries a `— Status` note (partial / not-started / done-differently / deferred)
> with the follow-up that tracks it.

## 1. Manifest & in-repo registry
- [ ] 1.1 Define the `addon.yaml` manifest schema (id, name, version, kind,
  delivery, supervision, capabilities, requires, artifacts, exec, state_dirs,
  config_schema) and a JSON-Schema validator for it.
  — Status: partial — manifest shape exists in `addons/sample-addon/addon.yaml`; the
  JSON-Schema validator is pending → `add-native-addon-build-signing` §1.
- [x] 1.2 Establish the `addons/<id>/` source layout convention
  (`addon.yaml`, `config.schema.json`, sources, `BUILD.bazel`, `README.md`).
- [x] 1.3 Add `build/native_addons/addon_inventory.bzl` (analogous to
  `build/wasm_plugins/plugin_inventory.bzl`) listing build targets + bundle
  definitions per add-on.
- [x] 1.4 Document the author checklist (mirror the WASM plugin author flow).
  — `docs/docs/native-addons.md`.

## 2. Build, signing & discovery (capability: native-addon-builds)
- [x] 2.1 Bazel rules to build per-`(os, arch)` add-on binaries and assemble a
  deterministic bundle + `sha256` + `metadata.json` per arch.
- [ ] 2.2 Reuse `scripts/cosign_common.sh` to Cosign-sign the OCI artifact (Rekor
  tlog by default); add the native-addon media-type constant and (recommended) a
  distinct `COSIGN_KEY_REF` (e.g. `hashivault://cosign-native-addons`).
  — Status: not started → `add-native-addon-build-signing` §2 (needs a Cosign key ref).
- [ ] 2.3 Reuse the ed25519 upload-signature tool with a native-addon key id; fail
  the build closed if signing keys are unset.
  — Status: not started → `add-native-addon-build-signing` §2 (needs an upload-signing secret).
- [ ] 2.4 Generate `serviceradar-native-addon-index.json` (per-arch digests) and
  publish it as a release asset; add a release-job presence assertion.
  — Status: not started → `add-native-addon-build-signing` §2.
- [ ] 2.5 Verify-before-release job (digest + Cosign + upload-signature).
  — Status: not started → `add-native-addon-build-signing` §2.
- [x] 2.6 Confirm no signing keys/secrets are committed; only public trust material.
- [ ] 2.7 Build hygiene: keep method dead-code elimination enabled with a
  `whydeadcode` guard; forbid importing the Go stdlib `plugin` package in agent/add-on
  builds; add a per-artifact binary-size regression gate (`go-size-analyzer`).
  — Status: not started → `add-native-addon-build-signing` §3 (needs CI tooling).
- [ ] 2.8 Dependency-isolation CI gate: assert (via `go list`/`goda`) that the base
  agent's transitive package set does not include any add-on implementation package.
  — Status: not started → `add-native-addon-build-signing` §3.

## 3. Base / add-on packaging boundary
- [ ] 3.1 Carve the base `serviceradar-agent` package to contain only the core
  agent (no optional capability binaries baked in via alternate targets).
  — Status: partial — the base package still bundles cli/netprobe → `add-native-addon-delivery-models` §1.
- [ ] 3.2 Define the signed `pushed-artifact` tarball format and the optional
  `os-package` add-on package template (depends on `serviceradar-agent`, dormant on
  install).
  — Status: partial — tarball/os-package template pending → `add-native-addon-delivery-models` §1.
- [x] 3.3 Keep the arch field real (amd64 now; arm64 additive without contract
  changes).

## 4. Control-plane catalog (Ash, core-elx)
- [x] 4.1 `AddonPackage` resource (staged→approved→revoked state machine,
  provenance, per-arch artifacts, delivery/supervision/requires metadata,
  config schema). Migration in `platform` schema.
- [x] 4.2 `AddonAssignment` resource (target = agent uid | cohort, enabled,
  validated params, overrides). Block assigning non-approved packages.
- [x] 4.3 v1: feature sets are a UI multi-select grouping over add-ons (each recorded
  as an individual AddonAssignment); no first-class bundle resource. (Deferred.)
  — A first-class bundle resource remains deferred by design.
- [ ] 4.4 Importer: reuse the WASM verify-then-mirror pipeline (trusted-host
  allowlist, bounded fetch, digest + Cosign + upload-signature) for the native-addon
  index; mirror artifacts into ServiceRadar object storage.
  — Status: not started → `add-native-addon-build-signing` §4 (needs 2.4 index).

## 5. Config compilation & delivery
- [x] 5.1 Add a typed `AddonAssignmentConfig` (repeated) to
  `AgentConfigResponse` in `proto/monitoring.proto`.
- [ ] 5.2 `AgentConfigGenerator`: load enabled+approved assignments for the agent,
  select the per-arch artifact, emit the typed section, include it in the
  `config_version` hash, and gate inclusion on agent capability/deliverability.
  — Status: partial — load/emit/version-hash done; per-arch artifact selection and
  capability/deliverability gating pending → `add-native-addon-build-signing` (per-arch)
  + capability gating.
- [x] 5.3 `DependencyCatalog` entry binding `AddonAssignment` →
  `config_type: :addon`, affected-agents resolver, dispatch `:push_affected_agents`;
  declare any `secret_fields`.
  — Done differently: entries exist for both `AddonAssignment` and `AddonPackage` with
  `dispatch: :push_affected_agents` and `secret_fields: [:params]`, under
  `config_type: :agent` (add-ons ride in `AgentConfigResponse`) rather than a dedicated
  `:addon` type.
- [ ] 5.4 `AgentCommandBus` mapping for the add-on config type (capability filter for
  targeted push).
  — Status: done differently — targeted delivery is achieved via per-agent/cohort
  assignment + the `:agent` config push; a dedicated `:addon` command-bus type was not added.

## 6. Agent-side delivery & supervision
- [ ] 6.1 Agent add-on manager: dispatch an assignment to its delivery model
  (config-toggle / pushed-artifact fetch+verify+activate / os-package activate).
  — Status: partial — only `agent-sidecar` is dispatched; other delivery models log as
  unsupported → `add-native-addon-delivery-models` §2.
- [x] 6.2 Adopt `github.com/hashicorp/go-plugin` for the `agent-sidecar` model;
  define the add-on gRPC service contract + handshake (magic cookie,
  `VersionedPlugins` / app protocol version) in `proto/`.
- [ ] 6.3 Refactor/generalize `go/pkg/agent/sidecar/manager.go` to manage one
  go-plugin client per add-on with per-add-on dynamic registration and independent
  enable/disable (replacing the fixed boot-time list + wholesale start/stop and the
  bespoke framed-protobuf UDS protocol).
  — Status: partial — a new `go/pkg/agent/addon` manager implements per-add-on go-plugin
  clients with dynamic registration/enable-disable; retiring the legacy
  `sidecar/manager.go` UDS transport is follow-up cleanup.
- [x] 6.4 Configure go-plugin transport: Unix-domain socket under a restricted dir +
  AutoMTLS for host↔plugin gRPC; layer health checks, restart backoff, and circuit
  breaker on top.
- [ ] 6.5 `pushed-artifact` activation: reuse `release_runtime.go` staged-dir +
  `current`-symlink + rollback; verify sha256 + signature; apply file capabilities
  per `requires.os_capabilities` via the root-owned `agent-updater`.
  — Status: not started → `add-native-addon-delivery-models` §2.2.
- [ ] 6.6 Wire the remaining supervision models: `systemd-service`, `systemd-timer`
  (spool ingest), `ephemeral-helper`, `config-toggle`.
  — Status: not started → `add-native-addon-delivery-models` §3.
- [ ] 6.7 Last-known-good cache + local override for add-on assignments (mirror the
  existing config override/cache pattern).
  — Status: not started → `add-native-addon-delivery-models` §4.

## 6b. Native add-on SDK
- [x] 6b.1 Go SDK wrapping go-plugin server boilerplate (handshake, gRPC serving over
  UDS, AutoMTLS, health, config decode from the typed assignment, result submission
  via host services).
- [ ] 6b.2 Rust handshake + gRPC-contract helper/crate (or documented contract) so
  Rust add-ons (e.g. `netprobe`) interoperate with the agent's go-plugin client.
  — Status: not started → `add-native-addon-rust-sdk` §1.
- [ ] 6b.3 Reference add-on (one Go, one Rust) proving the SDK + contract end to end.
  — Status: partial — the Go reference add-on exists (`go/cmd/serviceradar-sample-addon`);
  the Rust reference is pending → `add-native-addon-rust-sdk` §2.

## 7. Reporting & reconciliation
- [ ] 7.1 Extend the `agent_capabilities` StatusResponse + `SidecarStatus` to report
  per-add-on installed/available/active/unhealthy + degradation reason and arch.
  — Status: partial — per-add-on state/health is reported in the `agent_capabilities`
  payload; arch reporting and the structured surfacing are pending → `add-native-addon-edge-ops` §1.
- [ ] 7.2 Surface installed/active add-ons per agent in the agent registry read model
  (and SRQL where relevant).
  — Status: not started → `add-native-addon-edge-ops` §1.

## 8. Edge Ops UI (web-ng)
- [x] 8.1 New "Add-ons / Feature Sets" surface under Settings > Agents (sub-nav +
  route), gated by an edge-management permission.
- [ ] 8.2 Available-add-on catalog panel (reuse the first-party discovery panel) +
  approval review.
  — Status: partial — catalog/selection exists; the approval-review surface is pending
  → `add-native-addon-edge-ops` §2.1.
- [x] 8.3 Config form from `config.schema.json` (reuse `PluginConfigForm`).
- [ ] 8.4 Target selection: per-agent (assign-to-agent form) and per-cohort
  (reuse the release cohort + compatibility-preview pattern).
  — Status: partial — per-agent assignment exists; per-cohort targeting is pending
  → `add-native-addon-edge-ops` §2.2.
- [ ] 8.5 Per-agent detail: show assigned vs. installed vs. active add-ons + drift.
  — Status: partial — the per-agent assignment card exists; the assigned-vs-active drift
  view is pending → `add-native-addon-edge-ops` §2.3.
- [ ] 8.6 Deploy-time: allow selecting an initial feature set in the onboarding
  package flow.
  — Status: not started → `add-native-addon-edge-ops` §2.4.

## 9. Reference-consumer validation (contract proof, not migration)
- [ ] 9.1 Author an `addon.yaml` for each reference consumer (remote-access =
  compiled-in/config-toggle; Bumblebee = os-package/systemd-timer; rust-sample =
  pushed-artifact/agent-sidecar) and confirm the contract expresses each without
  gaps.
  — Status: partial — `addons/sample-addon` proves the contract; the remote-access /
  Bumblebee / rust-sample manifests are pending (rust-sample → `add-native-addon-rust-sdk` §3).
  The real host-visibility consumer is `netprobe` (`systemd-service`, capability-granted),
  migrated by `migrate-netprobe-to-native-addon`.

## 10. Validation & docs
- [x] 10.1 `openspec validate add-agent-feature-sets --strict` passes.
- [ ] 10.2 Author/operator docs: how to publish an add-on; how to select/target
  feature sets in Edge Ops.
  — Status: partial — the author flow is documented (`docs/docs/native-addons.md`); the
  operator "select/target in Edge Ops" guide lands with the UI → `add-native-addon-edge-ops` §3.
- [ ] 10.3 Coordination notes for migrating Bumblebee / host-network-visibility /
  remote-access onto the contract (follow-up changes).
  — Status: not started — to be written alongside the maintainer-owned migration changes.
