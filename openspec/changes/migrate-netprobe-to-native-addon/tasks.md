## 1. Add-on manifest & bundle

- [x] 1.1 Author `addons/netprobe/addon.yaml` (kind: native; delivery: pushed-artifact; supervision: systemd-service; `host-network-visibility` capability; `requires` `CAP_NET_RAW,CAP_BPF,CAP_PERFMON` + linux platforms) and `addons/netprobe/config.schema.json` mirroring the `VisibilityAgentConfig` operator surface (capture_interfaces, dpi toggle+protocols, default/per-device sample interval, flow_table_max_entries, process_snapshot_interval_s, external_flow_match_window_ms, device_bindings).
  — `kind: capability` in the original wording is `kind: native` per the schema enum.
- [x] 1.2 Validate `addons/netprobe/addon.yaml` against the manifest JSON-Schema + validator (`go/tools/addon-manifest-validator`) — passes (`OK addons/netprobe/addon.yaml`).
- [ ] 1.3 Wire a `netprobe` bundle into `build/native_addons/addon_inventory.bzl`
  (`netprobe_addon_bundle`: `//rust/netprobe:netprobe`, `binary_name`
  `serviceradar-netprobe`, linux amd64/arm64, manifest + config, `pushed_artifact_tarball`)
  producing per-arch pushed-artifact tarballs. **Partial:** the systemd **unit** is not
  shipped in the bundle yet — netprobe's unit `ExecStart`/socket lifecycle is the
  standalone-vs-agent-launched **open question** (netprobe's `--socket` is required and
  the agent currently owns that socket; see Open Questions). Deferred to §2.1 so a wrong
  lifecycle is not baked into a shipped unit.
- [x] 1.4 Retire base-package delivery of netprobe: removed `//rust/netprobe` from
  `build/packaging/packages.bzl` and both release-runtime archives in
  `build/packaging/agent/BUILD.bazel`, and removed the `setcap cap_net_raw,cap_bpf,cap_perfmon`
  step from the agent post-install (capabilities are now applied to the staged add-on
  binary by the root-owned `agent-updater` per the assignment's `os_capabilities`). The
  base `serviceradar-agent` package installs no netprobe binary or capability grant
  (no netprobe refs remain under `build/packaging`); the `//rust/netprobe` build target
  is retained for the add-on bundle. Also tracked as delivery-models §1.1.

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
