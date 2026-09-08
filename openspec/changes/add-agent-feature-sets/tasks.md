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
- [x] 1.1 Define the `addon.yaml` manifest schema (id, name, version, kind,
  delivery, supervision, capabilities, requires, artifacts, exec, state_dirs,
  config_schema) and a JSON-Schema validator for it.
  — Done: `addons/native-addon-manifest.schema.json` plus
  `go/tools/addon-manifest-validator`; wired through `make validate_addon_manifests`
  and `//build/native_addons:validate_addon_manifests_test`.
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
- [x] 2.2 Reuse `scripts/cosign_common.sh` to Cosign-sign the OCI artifact (Rekor
  tlog by default); add the native-addon media-type constant and (recommended) a
  distinct `COSIGN_KEY_REF` (e.g. `hashivault://cosign-native-addons`).
  — Done: `scripts/sign-native-addon-publish.sh` uses `scripts/cosign_common.sh`;
  `.forgejo/workflows/native-addons.yml` signs through OpenBao with
  `COSIGN_KEY_REF=hashivault://cosign-release`.
- [x] 2.3 Reuse the ed25519 upload-signature tool with a native-addon key id; fail
  the build closed if signing keys are unset.
  — Done differently: native add-ons sign each per-arch pushed artifact with the
  agent release ed25519 key via `build/native_addons/addon_artifact_signature_tool`.
  `build/native_addons/publish_addon.sh` fails closed when
  `SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY` is unset.
- [x] 2.4 Generate `serviceradar-native-addon-index.json` (per-arch digests) and
  publish it as a release asset; add a release-job presence assertion.
  — Done: `scripts/generate-native-addon-import-index.sh` plus
  `.forgejo/workflows/native-addons.yml`; the workflow now re-queries the release
  after upload and fails if the index asset is absent.
- [x] 2.5 Verify-before-release job (digest + Cosign + upload-signature).
  — Done: `scripts/verify-native-addon-publish.sh` verifies OCI type, bundle layer,
  Cosign signature, and per-arch artifact ed25519 signatures; the workflow also runs
  `scripts/test-verify-native-addon-publish-negative.sh`.
- [x] 2.6 Confirm no signing keys/secrets are committed; only public trust material.
- [x] 2.7 Build hygiene: keep method dead-code elimination enabled with a
  `whydeadcode` guard; forbid importing the Go stdlib `plugin` package in agent/add-on
  builds; add a per-artifact binary-size regression gate (`go-size-analyzer`).
  — Done: `scripts/check-addon-deadcode-elimination.sh`,
  `scripts/check-addon-no-stdlib-plugin.sh`, and `scripts/check-addon-binary-size.sh`
  are wired through `make addon_build_gates` / `//build/native_addons:build_gates_test`.
- [x] 2.8 Dependency-isolation CI gate: assert (via `go list`/`goda`) that the base
  agent's transitive package set does not include any add-on implementation package.
  — Done: `scripts/check-addon-dependency-isolation.sh` and
  `//build/native_addons:dependency_isolation_test`.

## 3. Base / add-on packaging boundary
- [x] 3.1 Carve the base `serviceradar-agent` package to contain only the core
  agent (no optional capability binaries baked in via alternate targets).
  — Done: netprobe is delivered as a pushed-artifact add-on, the RDP-enabled
  managed-agent runtime archive was removed, and `serviceradar-rdp-adapter` now ships
  as the `rdp` pushed-artifact / ephemeral-helper native add-on resolved by
  remote-access at session-open time.
- [x] 3.2 Define the signed `pushed-artifact` tarball format and the optional
  `os-package` add-on package template (depends on `serviceradar-agent`, dormant on
  install).
  — Done: `build/native_addons/assemble_addon_bundle.py` emits deterministic
  per-arch pushed-artifact tarballs, and `build/packaging/addon-template/` defines
  the dormant os-package template.
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
- [x] 4.4 Importer: reuse the WASM verify-then-mirror pipeline (trusted-host
  allowlist, bounded fetch, digest + Cosign + upload-signature) for the native-addon
  index; mirror artifacts into ServiceRadar object storage.
  — Done: `ServiceRadarWebNG.Plugins.NativeAddonImporter` fetches and verifies the
  native index/OCI layers, then calls `ServiceRadar.Plugins.NativeAddonImporter`;
  `ServiceRadar.Plugins.NativeAddonArtifactMirror` mirrors verified per-arch
  artifacts into object storage and records object keys/digests/signatures.

## 5. Config compilation & delivery
- [x] 5.1 Add a typed `AddonAssignmentConfig` (repeated) to
  `AgentConfigResponse` in `proto/monitoring.proto`.
- [x] 5.2 `AgentConfigGenerator`: load enabled+approved assignments for the agent,
  select the per-arch artifact, emit the typed section, include it in the
  `config_version` hash, and gate inclusion on agent capability/deliverability.
  — Done: `ServiceRadar.Edge.AgentConfigGenerator` emits only deliverable
  assignments, selects the matching per-arch artifact, omits pushed-artifact
  assignments without verified object storage metadata, and gates inclusion by
  `requires.platforms` plus the `requires.base_agent` floor; the filtered add-on set
  remains part of the config-version hash.
- [x] 5.3 `DependencyCatalog` entry binding `AddonAssignment` →
  `config_type: :addon`, affected-agents resolver, dispatch `:push_affected_agents`;
  declare any `secret_fields`.
  — Done differently: entries exist for both `AddonAssignment` and `AddonPackage` with
  `dispatch: :push_affected_agents` and `secret_fields: [:params]`, under
  `config_type: :agent` (add-ons ride in `AgentConfigResponse`) rather than a dedicated
  `:addon` type.
- [x] 5.4 `AgentCommandBus` mapping for the add-on config type (capability filter for
  targeted push).
  — Status: done differently — targeted delivery is achieved via per-agent/cohort
  assignment + the `:agent` config push; a dedicated `:addon` command-bus type was not added.

## 6. Agent-side delivery & supervision
- [x] 6.1 Agent add-on manager: dispatch an assignment to its delivery model
  (config-toggle / pushed-artifact fetch+verify+activate / os-package activate).
  — Done: the agent dispatches `config-toggle`, `pushed-artifact`, `os-package`,
  `systemd-service`, `systemd-timer`, `ephemeral-helper`, and `agent-sidecar` models;
  see `go/pkg/agent/addon_activation.go`, `go/pkg/agent/addon_systemd.go`, and
  `go/pkg/agent/push_loop_addons.go`.
- [x] 6.2 Adopt `github.com/hashicorp/go-plugin` for the `agent-sidecar` model;
  define the add-on gRPC service contract + handshake (magic cookie,
  `VersionedPlugins` / app protocol version) in `proto/`.
- [x] 6.3 Refactor/generalize `go/pkg/agent/sidecar/manager.go` to manage one
  go-plugin client per add-on with per-add-on dynamic registration and independent
  enable/disable (replacing the fixed boot-time list + wholesale start/stop and the
  bespoke framed-protobuf UDS protocol).
  — Done: `go/pkg/agent/addon.Manager` is the go-plugin supervisor with one runner per
  assigned add-on and dynamic `Apply` reconciliation. The legacy
  `go/pkg/agent/sidecar/manager.go` process launcher, process helpers, and launcher tests
  were removed; `go/pkg/agent/sidecar` now only owns shared status/proto types. Netprobe's
  remaining framed-protobuf IPC is scoped to `go/pkg/agent/netprobe.AttachManager`, which
  attaches to the externally supervised `systemd-service` add-on and never execs optional
  capability binaries from the base agent.
- [x] 6.4 Configure go-plugin transport: Unix-domain socket under a restricted dir +
  AutoMTLS for host↔plugin gRPC; layer health checks, restart backoff, and circuit
  breaker on top.
- [x] 6.5 `pushed-artifact` activation: reuse `release_runtime.go` staged-dir +
  `current`-symlink + rollback; verify sha256 + signature; apply file capabilities
  per `requires.os_capabilities` via the root-owned `agent-updater`.
  — Done: staged activation verifies sha256 + ed25519 signature, updates
  `current`, rolls back on failure, and applies file capabilities through
  `agent-updater`.
- [x] 6.6 Wire the remaining supervision models: `systemd-service`, `systemd-timer`
  (spool ingest), `ephemeral-helper`, `config-toggle`.
  — Done: systemd unit install/enable/disable, ephemeral helper registration, and
  config-toggle acknowledgement are implemented in the agent.
- [x] 6.7 Last-known-good cache + local override for add-on assignments (mirror the
  existing config override/cache pattern).
  — Done: agent-side last-known-good spec reuse and `addons.local.json` override are
  implemented and covered by agent tests.

## 6b. Native add-on SDK
- [x] 6b.1 Go SDK wrapping go-plugin server boilerplate (handshake, gRPC serving over
  UDS, AutoMTLS, health, config decode from the typed assignment, result submission
  via host services).
- [x] 6b.2 Rust handshake + gRPC-contract helper/crate (or documented contract) so
  Rust add-ons (e.g. `netprobe`) interoperate with the agent's go-plugin client.
  — Done: `rust/addon-sdk` implements the go-plugin handshake, AutoMTLS, and gRPC
  contract helper.
- [x] 6b.3 Reference add-on (one Go, one Rust) proving the SDK + contract end to end.
  — Done: Go reference add-on exists at `go/cmd/serviceradar-sample-addon`; Rust
  reference add-on exists at `rust/addon-sdk/src/bin/rust_sample_addon.rs` with
  `addons/rust-sample-addon/addon.yaml`.

## 7. Reporting & reconciliation
- [x] 7.1 Extend the `agent_capabilities` StatusResponse + `SidecarStatus` to report
  per-add-on installed/available/active/unhealthy + degradation reason and arch.
  — Done — `SidecarStatus` gained `version` + `arch` fields; the add-on manager reports both
  (`ToProtoStatuses`, arch from `runtime.GOARCH`) and the core `AddonStatusIngestor` populates the
  read model's `version`/`arch` columns. netprobe's sidecar-path version/arch + capture status is
  wired in `migrate-netprobe-to-native-addon` §2.3.
- [x] 7.2 Surface installed/active add-ons per agent in the agent registry read model
  (and SRQL where relevant).
  — Done: `ServiceRadar.Plugins.AddonStatus` / `AddonStatusIngestor` persist
  per-agent observed status, and SRQL exposes `in:addon_statuses`.

## 8. Edge Ops UI (web-ng)
- [x] 8.1 New "Add-ons / Feature Sets" surface under Settings > Agents (sub-nav +
  route), gated by an edge-management permission.
- [x] 8.2 Available-add-on catalog panel (reuse the first-party discovery panel) +
  approval review.
  — Done: `/settings/agents/addons` lists packages and supports staged package
  approval/denial with approved-capability narrowing.
- [x] 8.3 Config form from `config.schema.json` (reuse `PluginConfigForm`).
- [x] 8.4 Target selection: per-agent (assign-to-agent form) and per-cohort
  (reuse the release cohort + compatibility-preview pattern).
  — Done: the Add-ons LiveView supports target modes for explicit agents and cohorts
  with a compatibility preview and fan-out tests.
- [x] 8.5 Per-agent detail: show assigned vs. installed vs. active add-ons + drift.
  — Done: the agent detail LiveView reconciles assignments against `AddonStatus` and
  surfaces not installed, not active, unhealthy, architecture-unsupported, and
  observed-unassigned drift.
- [x] 8.6 Deploy-time: allow selecting an initial feature set in the onboarding
  package flow.
  — Done: the onboarding package flow can select approved add-ons and creates
  initial `AddonAssignment` rows for agent packages.

## 9. Reference-consumer validation (contract proof, not migration)
- [x] 9.1 Author an `addon.yaml` for each reference consumer (remote-access =
  compiled-in/config-toggle; Bumblebee = os-package/systemd-timer; rust-sample =
  pushed-artifact/agent-sidecar) and confirm the contract expresses each without
  gaps.
  — Done: `addons/remote-access` proves `compiled-in` / `config-toggle`,
  `addons/bumblebee-scan` proves timer/spool delivery, `addons/rust-sample-addon`
  proves Rust `agent-sidecar`, and `addons/netprobe` proves the real
  capability-granted `systemd-service` host-visibility model.

## 10. Validation & docs
- [x] 10.1 `openspec validate add-agent-feature-sets --strict` passes.
- [x] 10.2 Author/operator docs: how to publish an add-on; how to select/target
  feature sets in Edge Ops.
  — Done: `docs/docs/native-addons.md` now covers publishing, approval,
  assignment, cohort targeting, reconciliation, and operator validation.
- [x] 10.3 Coordination notes for migrating Bumblebee / host-network-visibility /
  remote-access onto the contract (follow-up changes).
  — Done: `docs/docs/native-addons.md` now has "Reference consumer coordination"
  notes for Bumblebee, netprobe/host-network-visibility, and remote-access/RDP
  adapter boundaries.
