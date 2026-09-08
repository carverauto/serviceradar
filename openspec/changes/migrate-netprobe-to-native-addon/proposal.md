# Change: Migrate netprobe host-network-visibility sidecar to a native add-on

## Why

netprobe (`add-host-network-visibility-sidecar`, #3439) ships today as part of the base
`serviceradar-agent` package: the `serviceradar-netprobe` binary is installed by the agent
deb/rpm (`build/packaging/packages.bzl`), granted file capabilities
(`cap_net_raw,cap_bpf,cap_perfmon=+ep`) by the agent post-install, and launched by the agent
over a bespoke length-framed IPC (`go/pkg/agent/netprobe`, the `NetprobeFrame` protocol). The
native add-on framework (#3425) now provides signed, discoverable, Edge-Ops-governed delivery
for optional agent capabilities, and the umbrella explicitly tracks moving
"host-network-visibility/netprobe … onto the contract."

netprobe needs elevated Linux capabilities for eBPF/AF_XDP capture (`CAP_NET_RAW`, `CAP_BPF`,
`CAP_PERFMON` — see `rust/netprobe/src/capabilities.rs`), applied via `setcap` at install time,
so it **cannot** be a plain unprivileged `agent-sidecar` go-plugin add-on. It also speaks its
own IPC and has its own agent-side client, not the add-on gRPC contract. The capability should
therefore keep its capability-granted, IPC-based runtime — but be *delivered, signed,
versioned, targeted, and drift-observed* as a native add-on instead of being baked into the
base agent, so operators can turn host-network visibility on per-cohort from Edge Ops rather
than shipping it to every agent unconditionally.

## What Changes

- Add `addons/netprobe/addon.yaml` (+ `config.schema.json`) declaring netprobe as a
  `capability` add-on: `delivery: pushed-artifact` (primary; `os-package` fallback for
  air-gapped hosts), `supervision: systemd-service`, the host-network-visibility capability id,
  `requires` the `cap_net_raw,cap_bpf,cap_perfmon` file capabilities, and a `config.schema.json`
  mirroring the existing `VisibilityConfig` operator surface (capture interfaces, DPI toggle,
  sample interval, flow-table sizing).
- Deliver and activate the **signed** netprobe artifact through the root-owned `agent-updater`
  (per `add-native-addon-delivery-models`): the privileged install path stages the binary under
  the versioned `current`-symlink layout, **applies the required file capabilities** (`setcap`),
  and installs/enables the `systemd-service`. The non-root agent never gains those capabilities
  itself.
- Gate the netprobe sidecar's lifecycle and config push on the `AddonAssignment` (enabled /
  disabled / approved-capability subset) instead of the always-on base-agent
  `VisibilityConfig` path, and report per-add-on state and drift through the merged
  `AddonStatus` read model. The existing `NetprobeFrame` IPC and the agent-side
  `go/pkg/agent/netprobe` client remain the data channel.
- Surface netprobe as a selectable feature-set / add-on in Edge Ops, reusing the merged
  `AddonPackage` / `AddonAssignment` resources and Edge Ops UI (no new control-plane schema).
- **BREAKING (packaging):** stop bundling `serviceradar-netprobe` and its `setcap` post-install
  step in the base `serviceradar-agent` package. The binary, its capability grant, and its
  systemd unit ship inside the signed add-on bundle instead. A freshly installed base agent runs
  with no host-network-visibility sidecar until the netprobe add-on is delivered.

## Impact

- **Affected specs:** `agent-configuration` — ADDED "Netprobe Host-Network-Visibility Sidecar
  Delivered As A Native Add-on" (the sidecar's *runtime behavior* — eBPF/AF_XDP capture, passive
  fingerprinting, DPI, flow attribution, and the events it forwards — is unchanged from
  `add-host-network-visibility-sidecar`; only its delivery/packaging/governance changes).
- **Affected code:** `addons/netprobe/`, `build/native_addons/` (inventory + bundle rule),
  `build/packaging/agent/` + `build/packaging/packages.bzl` (remove netprobe from the base
  package and move the `setcap` step into the add-on install path), `go/pkg/agent/netprobe/*`
  (gate sidecar start/stop + config on the assignment), `go/pkg/agent/addon*` +
  `go/pkg/agent/addon_activation.go` (`systemd-service` supervision + capability application,
  delivered by delivery-models), and a control-plane netprobe `AddonPackage` seed/manifest
  import.
- **Depends on:** `add-native-addon-delivery-models` (**`systemd-service` supervision +
  pushed-artifact file-capability application via the root-owned `agent-updater` — both not yet
  implemented**), `add-native-addon-build-signing` (sign + publish the bundle; manifest schema +
  validator), `add-agent-feature-sets` (manifest + assignment contract), `add-native-addon-edge-ops`
  (targeting + drift UI). Builds on `add-host-network-visibility-sidecar` (#3439).
- **Non-goal:** rewriting netprobe to speak the add-on gRPC contract (`proto/agent/addon/v1`) or
  run as a go-plugin `agent-sidecar`; changing what netprobe captures, the fingerprint/DPI/flow
  pipelines, or the eBPF verifier — all delivered by #3439 and reused as-is.
