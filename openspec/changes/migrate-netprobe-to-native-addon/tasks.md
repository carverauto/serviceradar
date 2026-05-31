## 1. Add-on manifest & bundle

- [ ] 1.1 Author `addons/netprobe/addon.yaml` (kind: capability; delivery: pushed-artifact; supervision: systemd-service; host-network-visibility capability id; `requires` the `cap_net_raw,cap_bpf,cap_perfmon` file capabilities + linux platforms) and `addons/netprobe/config.schema.json` mirroring the `monitoring.VisibilityConfig` operator surface (capture interfaces, DPI toggle, default sample interval, flow-table max entries)
- [ ] 1.2 Validate `addons/netprobe/addon.yaml` against the manifest JSON-Schema + validator from `add-native-addon-build-signing`
- [ ] 1.3 Wire a `netprobe` bundle into `build/native_addons/addon_inventory.bzl` (the `//rust/netprobe` binary + systemd unit + config) producing per-arch signed bundles; confirm the Rust binary is packaged per `(os, arch)`
- [ ] 1.4 Retire base-package delivery of netprobe: remove `serviceradar-netprobe` from `build/packaging/packages.bzl` / `build/packaging/agent/BUILD.bazel` and move the `setcap cap_net_raw,cap_bpf,cap_perfmon` step out of the agent post-install into the add-on install path; confirm the base `serviceradar-agent` package installs no netprobe binary, unit, or capability grant

## 2. Agent delivery & supervision (consumes delivery-models)

- [ ] 2.1 Activate the signed netprobe artifact via the root-owned `agent-updater`: stage under the versioned `current`-symlink layout, verify sha256 + signature, apply the required file capabilities (`setcap`), then install/enable the systemd service (privileged steps never run by the agent) — depends on delivery-models `systemd-service` supervision (task 6.6) and pushed-artifact file-capability application (task 6.5)
- [ ] 2.2 Gate the agent's netprobe sidecar lifecycle and `VisibilityConfig` push on the `AddonAssignment` (enabled/disabled + approved-capability subset) instead of the always-on base-agent visibility path; preserve the local-override/cache fallback when the control plane is unreachable
- [ ] 2.3 Report per-add-on state (installed/active/degraded + version/arch + capture status) for netprobe through the merged `AddonStatus` read model so Edge Ops drift reflects it
- [ ] 2.4 On activation/capability-application/launch failure, roll back to the prior `current` version and do NOT leave a half-installed/enabled unit or a running-but-incapable process

## 3. Control plane & Edge Ops (reuses merged work)

- [ ] 3.1 Seed/import a netprobe `AddonPackage` (staged → approved with the host-network-visibility capability) so it is selectable/targetable in Edge Ops
- [ ] 3.2 Confirm `AgentConfigGenerator` compiles the netprobe assignment (delivery=pushed-artifact, supervision=systemd-service, per-arch artifact reference, schema-validated `VisibilityConfig` params) into agent config
- [ ] 3.3 Confirm netprobe appears as a selectable feature-set in onboarding + per-cohort targeting + the assigned/installed/active drift card (no new UI beyond `add-native-addon-edge-ops`)

## 4. Verification

- [ ] 4.1 Go unit tests: assignment-gated sidecar start/stop + config push enable/disable; rollback on bad-signature or failed-`setcap` activation; IPC ingest unchanged
- [ ] 4.2 Elixir DB-backed tests (srql-fixtures scratch DB): netprobe `AddonPackage`/`AddonAssignment` compile + status ingest + drift
- [ ] 4.3 e2e on a **scratch** agent rolled from a current build (NOT the live dusk01 agent): enable via Edge Ops → binary staged + `setcap` + unit enabled → IPC connect → fingerprint/DPI/flow events ingested → status reported → disable stops capture → rollback restores prior version
- [ ] 4.4 `openspec validate migrate-netprobe-to-native-addon --strict`
