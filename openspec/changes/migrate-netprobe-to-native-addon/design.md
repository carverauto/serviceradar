## Context

Two things are already true and constrain this change:

1. **#3439 shipped netprobe's runtime.** The Rust sidecar (`rust/netprobe/*` — passive
   fingerprinting via p0f/JA4/HASSH/recog, DPI, eBPF process attribution, AF_XDP capture,
   on-demand pcapng), the agent-side client and bespoke `NetprobeFrame` IPC
   (`go/pkg/agent/netprobe/*`: `sidecar.go`, `client.go`, `framing.go`, `translator.go`), and the
   event-forwarding path (`FingerprintEvent` / `DpiEvent` / `FlowAttributionEvent` → `push_loop`)
   are implemented. Today the binary is bundled in the base `serviceradar-agent` package
   (`build/packaging/packages.bzl`), `setcap cap_net_raw,cap_bpf,cap_perfmon=+ep` is applied in the
   agent post-install, it runs as the non-root `serviceradar` user, and the agent launches it as a
   child sidecar driven by `monitoring.VisibilityConfig`.

2. **#3425 shipped the framework + control plane.** `AddonPackage` / `AddonAssignment` /
   `AddonStatus` and `AgentConfigGenerator` add-on compilation are merged and DB-validated,
   including `pushed-artifact` per-arch artifact references. `delivery-models` defines the generic
   supervision models and pushed-artifact activation/rollback via the root-owned `agent-updater`.

This change is the **seam** between the two: make netprobe a concrete consumer of the framework's
`pushed-artifact` path with a capability-granted long-running supervision model, and stop baking
it into the base agent.

## Goals / Non-Goals

- **Goals:** one signed, versioned netprobe artifact; Edge-Ops-driven enable/target/drift after
  the initial agent install; the base agent ships without netprobe and without the netprobe
  `setcap` step; the existing IPC + capture/fingerprint/DPI/flow behavior preserved unchanged.
- **Non-Goals:** an agent-launched go-plugin (`agent-sidecar`) netprobe; rewriting netprobe to the
  add-on gRPC contract; changing capture scope, the fingerprint/DPI/flow pipelines, or the eBPF
  verifier; macOS packaging (Linux only, as in #3439).

## Decisions

- **Decision: `systemd-service` supervision, not `agent-sidecar` (go-plugin).** netprobe needs
  `CAP_NET_RAW` / `CAP_BPF` / `CAP_PERFMON` (eBPF + AF_XDP), applied as file capabilities at
  install time, and it speaks the bespoke `NetprobeFrame` IPC with its own agent-side client — not
  the add-on gRPC contract the go-plugin client dispenses. Running it as a capability-granted
  `systemd-service` (with a dedicated unit and `AmbientCapabilities`/file-caps) is the honest
  privilege boundary and avoids rewriting a working transport. *Alternative considered:*
  agent-sidecar go-plugin — rejected because (a) the go-plugin client expects the add-on gRPC
  contract, which netprobe does not speak, and (b) granting `CAP_BPF`/`CAP_PERFMON` to an
  agent-launched child still requires the root-owned updater to `setcap` the binary, so no
  isolation is gained over a managed service.

- **Decision: `pushed-artifact` is the primary delivery model; `os-package` is an air-gapped
  fallback.** The agent already runs the signed-release pipeline (root-owned `agent-updater`,
  Ed25519 release key, versioned `current`-symlink). `pushed-artifact` reuses that exact shape with
  no per-update apt/dnf transaction. *Alternative considered:* `os-package` as primary — rejected
  because it requires a host package transaction per update; kept as a fallback for hosts that
  cannot fetch artifacts.

- **Decision: the existing `NetprobeFrame` IPC remains the data channel.** The `AddonAssignment`
  governs enable/disable/config and the capability subset; netprobe continues to stream
  fingerprint/DPI/flow events to the agent over its Unix-socket IPC, which the existing
  `go/pkg/agent/netprobe` client ingests and forwards via `push_loop`. This reuses a tested,
  high-throughput pipeline. *Alternative considered:* re-expressing netprobe over the add-on gRPC
  contract — deferred; it would discard the working transport for no governance benefit.

- **Decision: privileged install (binary stage, `setcap`, unit install/enable) is performed by the
  root-owned `agent-updater`, never by the agent.** Applying file capabilities and managing the
  systemd unit are privileged operations; the non-root agent (no sudo) requests them via the
  assignment, and the updater applies them. The add-on process never sets its own capabilities.

- **Decision: carve netprobe out of the base agent package.** The base `serviceradar-agent`
  package stops shipping `serviceradar-netprobe` and its `setcap` post-install step; both move into
  the signed add-on bundle. This aligns with `add-native-addon-delivery-models` §1 ("base package
  still bundles cli/netprobe → carve out") and keeps the base agent core-only.

## Risks / Trade-offs

- **`systemd-service` supervision and pushed-artifact file-capability application do not exist
  yet.** They are tracked in `add-native-addon-delivery-models` (tasks 6.6 and 6.5) and are unstarted.
  → This change is **blocked** on those landing; it cannot be implemented end-to-end before them.
- **Capability application is a new privileged primitive.** A delivered netprobe binary must be
  `setcap`'d by the updater before the unit starts, and a failed/partial `setcap` must not leave a
  running-but-incapable or half-enabled unit. → reuse delivery-models' versioned-symlink rollback;
  on activation failure keep the previous version current and do not enable a half-installed unit.
- **Two active changes touch `agent-configuration` (#3439 not yet archived).** → This change ADDS a
  framework-delivery requirement and documents that it supersedes the base-package delivery of
  netprobe; reconcile the `specs/` merge when both archive.
- **e2e requires an agent build that contains the #3425 add-on manager.** The live `dusk01` agent
  (v1.2.83) predates it. → e2e must target a scratch/test agent rolled from a current build, not the
  production agent.
- **Signature + capability gate.** The netprobe artifact must be signed with the key matching the
  agent's `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY`; a mis-signed bundle is rejected (good) and a key
  mismatch would block delivery. → verify-before-release gate (build-signing).

## Migration Plan

1. Land `addons/netprobe/addon.yaml` + bundle; keep the base agent able to build the netprobe
   binary target but stop installing it / `setcap`-ing it in the base package.
2. Seed/import a netprobe `AddonPackage` (staged → approved) so Edge Ops can target it.
3. Gate the agent's netprobe sidecar start/stop + `VisibilityConfig` push on the assignment; fall
   back to the local-override/cache path when the control plane is unreachable.
4. Roll a current agent build (with the add-on manager) to a **scratch test agent**; enable the
   netprobe add-on via Edge Ops; confirm binary staging, `setcap`, unit install/enable, IPC
   connect, fingerprint/DPI/flow events ingested, status/drift reporting, and rollback.
5. Deprecate base-package delivery of netprobe in release notes.

**Rollback:** disable the assignment (the updater disables the unit; the agent stops the sidecar
client) or roll the add-on back to the prior `current` version; base-package delivery remains
available as a break-glass until the deprecation completes.

## Open Questions

- ~~Process model: a standalone `systemd-service` unit netprobe (decoupled from the agent process),
  or keep the agent-launched sidecar lifecycle?~~ **Resolved (§1.3): standalone `systemd-service`.**
  The code coupling settles it: netprobe binds its own IPC socket (`UnixListener::bind`,
  `rust/netprobe/src/server.rs`) and the agent connects as a client (`go/pkg/agent/netprobe/client.go`
  `Dial`); `--config` is optional, so netprobe starts with lifecycle IPC available and is configured
  over IPC after launch. So the migration keeps the existing config-over-IPC + ingest path and only
  moves process supervision from the agent's sidecar manager to systemd. The unit
  (`addons/netprobe/serviceradar-netprobe.service`) ships in the bundle; the agent-side
  assignment-gated install/connect rework is §2.2.
- Capability id naming: `host-network-visibility` vs `netprobe` — should match what the agent
  advertises upward.
- Default delivery for shipped fleets: `pushed-artifact` everywhere, or `os-package` for specific
  air-gapped cohorts?
