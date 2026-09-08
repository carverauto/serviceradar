## 1. Add-on manifest & bundle

- [x] 1.1 Author `addons/netprobe/addon.yaml` (kind: native; delivery: pushed-artifact; supervision: systemd-service; `host-network-visibility` capability; `requires` `CAP_NET_RAW,CAP_BPF,CAP_PERFMON` + linux platforms) and `addons/netprobe/config.schema.json` mirroring the `VisibilityAgentConfig` operator surface (capture_interfaces, dpi toggle+protocols, default/per-device sample interval, flow_table_max_entries, process_snapshot_interval_s, external_flow_match_window_ms, device_bindings).
  — `kind: capability` in the original wording is `kind: native` per the schema enum.
- [x] 1.2 Validate `addons/netprobe/addon.yaml` against the manifest JSON-Schema + validator (`go/tools/addon-manifest-validator`) — passes (`OK addons/netprobe/addon.yaml`).
- [x] 1.3 Wire a `netprobe` bundle into `build/native_addons/addon_inventory.bzl`
  (`netprobe_addon_bundle`: `//rust/netprobe:netprobe`, `binary_name`
  `serviceradar-netprobe`, linux amd64/arm64, manifest + config, `pushed_artifact_tarball`)
  producing per-arch pushed-artifact tarballs. **Done, incl. the systemd unit.** The
  standalone-vs-agent-launched **open question is resolved to `systemd-service`**: netprobe
  binds its own IPC socket (`UnixListener::bind` in `rust/netprobe/src/server.rs`) and the
  agent connects as a client, and `--config` is optional (netprobe starts with lifecycle IPC
  available and stays disabled until configured over IPC) — so config keeps flowing over the
  existing IPC, and the only change vs. the agent-launched sidecar is who starts the process.
  `addons/netprobe/serviceradar-netprobe.service` now ships in the bundle via the
  `unit_entries` plumbing (`defs.bzl` → assembler `--entry`, flat at 0644 in the per-arch
  tarball — verified). The unit is installed **verbatim** by the root-owned agent-updater
  (`InstallAddonSystemdUnits`, no `ExecStart` templating), so its `ExecStart` hardcodes the
  fixed staged path `/var/lib/serviceradar/agent/addons/netprobe/current/serviceradar-netprobe
  --socket /run/serviceradar/netprobe/ipc.sock`; a Go contract test
  (`netprobe_systemd_unit_test.go`) pins that path to `resolveAddonArtifactRoot` so the unit
  and staging layout can't drift. Caps (`CAP_NET_RAW,CAP_BPF,CAP_PERFMON`) are granted ambient
  in-unit + bounded; eBPF-hostile hardening (`MemoryDenyWriteExecute`,
  `SystemCallFilter=~@privileged`, `PrivateDevices`) is deliberately omitted. The unit is
  **inert until §2.2** wires assignment-gated activation; final hardening is locked by the
  §4.3 scratch-agent e2e.
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
  - **Building block landed**: the sidecar supervisor (`go/pkg/agent/sidecar/manager.go`) now has an
    **attach mode** (`StartAttach`, vs launch `Start`; `Mode()` reports started+attach). In attach
    mode the manager does NOT exec/restart the process — systemd owns it — and instead runs the
    health loop against the well-known socket, wiring the client into the sidecar via `OnHealthy`
    (config push + event ingest work identically, ingest being launch-decoupled) and reconnecting on
    loss. This is the mechanism the systemd-service netprobe path connects through. Additive + race-
    tested; no caller yet (zero production behavior change).
  - **Cutover landed**: `push_loop_config.go` `applyVisibilityConfig` now takes `systemdManaged bool`
    (from `netprobeSystemdAssignmentPresent(configResp.GetAddons())` — an enabled netprobe
    systemd_service assignment) and routes: present → `applyVisibilityConfigSystemd` (Mode()-based
    switch launch→attach via Stop+StartAttach, then `SetDesiredConfig`, always returns true so the
    apply never aborts before `applyAddonAssignments` installs the unit); absent →
    `applyVisibilityConfigLaunched` (the original launch path, byte-for-byte for un-assigned fleets,
    plus a Stop+`SetDesiredConfig(nil)` revert if coming from attach). Handoff stops the agent-launched
    child before systemd owns the socket. **Apply-on-connect** (`netprobe/sidecar.go`): `SetDesiredConfig`
    stores the latest `VisibilityAgentConfig` (atomic) + async `pushDesired` (serialized via `applyMu`,
    applies newest — last-write-wins); `setClient` re-triggers it on every (re)connect, so the full
    config (incl. device bindings, which the bootstrap file omits) is re-delivered after a systemd
    restart, independent of the gateway poll cadence. `sidecarLifecycleManager` gained `Mode()` +
    `StartAttach`. Unit-tested (routing→attach + revert→stop; assignment detection table;
    apply-on-connect applies + nil-clears) `go test -race` green; golangci-lint clean.
  - **Remaining**: the local-override/cache fallback across an AGENT restart while the control plane is
    unreachable (the in-memory `desiredConfig` is lost on agent restart — relies on the agent's general
    cached-config replay; verify in §4.x), and the full-flow validation is the §4.3 scratch-Linux-agent
    e2e (systemd installs+starts netprobe → agent attaches → config pushed → events ingested → restart
    re-applies). Bundles can't build/run on darwin.
- [ ] 2.3 Report per-add-on state (installed/active/degraded + version/arch + capture status) for netprobe through the merged `AddonStatus` read model so Edge Ops drift reflects it
  — Partial — the agent now synthesizes an `addon:netprobe` capability entry (state from the
  netprobe sidecar, installed version from the activation `current` symlink, arch from
  `runtime.GOARCH`) so netprobe lands in the `AddonStatus` read model / Edge Ops drift; a
  running-but-incapable netprobe surfaces via state + last_error. Remaining: explicit
  capture-active reporting needs a netprobe IPC signal (no capture-active frame exists today;
  `StartRemoteCapture` is a Phase-5 TODO) → follow-up.
- [x] 2.4 On activation/capability-application/launch failure, roll back to the prior `current` version and do NOT leave a half-installed/enabled unit or a running-but-incapable process
  — Done — all three failure classes roll `current` back to the prior version: capability
  application (`stageAndCapability` rolls back on `applyStagedAddonCapabilitiesViaUpdater`
  failure) and unit discovery/selection/install (the post-stage orchestration, extracted to a
  testable `reconcileStagedSystemdUnits` with an injectable installer + runtime root). Covered by
  `push_loop_addon_rollback_test.go`: install-failure → rollback (no remembered units), no-units →
  rollback without an install attempt, success → stays on the new version + records units.

## 3. Control plane & Edge Ops (reuses merged work)

- [ ] 3.1 Seed/import a netprobe `AddonPackage` (staged → approved with the host-network-visibility capability) so it is selectable/targetable in Edge Ops
  — Seeder landed — `ServiceRadar.Plugins.NetprobeAddonPackageSeeder` (mirrors the Bumblebee
  seeder Agent B added in #3493): a `DelayedSeeder` that creates + approves the netprobe
  `AddonPackage` (`delivery: :pushed_artifact`, `supervision: :systemd_service`, capability
  `host-network-visibility`, `os_capabilities` `CAP_NET_RAW/CAP_BPF/CAP_PERFMON`,
  `run_as: serviceradar`, config schema from `addons/netprobe/config.schema.json`) from configured
  per-arch artifact refs. Registered in `coordinator_children`. Intentionally a **no-op until
  `:netprobe_native_addon_package` is configured** with real mirrored+signed artifacts — so the
  remaining step is running the publish lane (Linux CI) + mirroring + wiring those refs on the
  target instance. DB-backed test in `netprobe_addon_package_seeder_test.exs` (seed→approve→compile
  assignment→proto). Compiles + credo clean.
- [x] 3.2 Confirm `AgentConfigGenerator` compiles the netprobe assignment (delivery=pushed-artifact, supervision=systemd-service, per-arch artifact reference, schema-validated `VisibilityConfig` params) into agent config
  — Done (confirm-via-test; the generic add-on path already handles netprobe — no code change). DB-backed
  test in `agent_config_generator_test.exs`: a netprobe `AddonPackage` (`addon_id: "netprobe"`,
  `delivery: :pushed_artifact`, `supervision: :systemd_service`, `requires.os_capabilities`, per-arch
  `artifacts["linux/amd64"]`) + an enabled `AddonAssignment` → `generate_config/1` emits an addon with
  `addon_id "netprobe"`, `:pushed_artifact`/`:systemd_service`, the approved capability subset, the
  os_capabilities, and the per-arch artifact ref. Critically it asserts the **cross-system contract**:
  `to_proto_response/1` stringifies `:systemd_service` → `"systemd_service"` (the exact constant the
  agent's `classifyAddonSupervision` matches to route netprobe onto the attach path — a hyphen/format
  drift would silently break the §2.2 cutover), and the `VisibilityConfig` rides in the SAME response
  (the agent reads both: the assignment to decide attach, VisibilityConfig for capture). Run via the
  `srql-fixtures` scratch DB; full `agent_config_generator_test.exs` 38/38 green, mix format + credo clean.
- [ ] 3.3 Confirm netprobe appears as a selectable feature-set in onboarding + per-cohort targeting + the assigned/installed/active drift card (no new UI beyond `add-native-addon-edge-ops`)

## 4. Verification

- [ ] 4.1 Go unit tests: assignment-gated sidecar start/stop + config push enable/disable; rollback on bad-signature or failed-`setcap` activation; IPC ingest unchanged
- [ ] 4.2 Elixir DB-backed tests (srql-fixtures scratch DB): netprobe `AddonPackage`/`AddonAssignment` compile + status ingest + drift
- [ ] 4.3 e2e on a **scratch** agent rolled from a current build (NOT the live dusk01 agent): enable via Edge Ops → binary staged + `setcap` + unit enabled → IPC connect → fingerprint/DPI/flow events ingested → status reported → disable stops capture → rollback restores prior version
- [ ] 4.4 `openspec validate migrate-netprobe-to-native-addon --strict`
