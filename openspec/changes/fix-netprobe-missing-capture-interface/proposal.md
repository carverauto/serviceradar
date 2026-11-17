# Change: Degrade netprobe on an absent capture interface instead of crash-looping

## Why

A netprobe add-on assigned a capture interface that does not exist on its host
restarts forever, and the operator is told the wrong cause.

Interface names are host-local facts, but they are configured on add-on
profiles that target a whole fleet (`in:agents`). A profile written for virtual
machines, whose NIC is a virtio name such as `ens18`, reaches a bare-metal
hypervisor whose NICs are bridges and bonds. There, four independent faults
compound:

1. netprobe treats an absent capture interface as fatal at startup
   (`rust/netprobe/src/capture.rs` `open_allowlisted_interfaces`, and
   `af_xdp::resolve_interfaces` in the eBPF runtime) and exits 1. That also
   kills flow attribution, which needs no capture interface at all.
2. The unit's `Restart=on-failure` with `RestartSec=5` never reaches systemd's
   default start limit (5 starts in 10 s), so the loop never stops.
3. The agent's systemd reconcile reinstalls and restarts any inactive add-on
   unit on every config cycle, so a start limit alone would be defeated.
4. The agent reports the symptom, not the cause: add-on status shows
   `unhealthy` with `dial netprobe socket: ... no such file or directory`. The
   agent probes the legacy IPC `Ping` and never calls the AddonService `Health`
   RPC, and netprobe's `Health` always answers `HEALTHY`.

## What Changes

- netprobe resolves its configured `capture_interfaces` against the host's
  interfaces at startup. It captures on the ones present, runs attribution-only
  when none are, and reports `DEGRADED` through AddonService `Health`. The
  reason names the absent interfaces and the ones the host does have, and
  structured `details` carry the same lists. An absent interface is never
  fatal. Empty `capture_interfaces` keeps its meaning: attribution-only, healthy.
- netprobe's restart-required check compares a pushed config against the
  *requested* startup interface list, so a degraded netprobe does not refuse
  every identical config push.
- The agent's netprobe attach manager calls AddonService `Health` after a
  successful liveness probe and reports `degraded` plus the reason in the
  add-on status. A degraded netprobe still counts as running for capability
  gating. Core records a `degraded` add-on as active.
- The netprobe unit gets `StartLimitIntervalSec=300` / `StartLimitBurst=5`. The
  agent reports a unit that hit its start limit as `circuit_open` and does not
  reinstall it while the assignment's artifact and config are unchanged. A
  changed assignment clears the unit's failed state before restarting it.
- Follow-up (separate PR): core flags agents whose assigned capture interfaces
  are absent from the interface inventory the agent reports.

## Impact

- Affected specs: `agent-configuration` (ADDED requirements only).
- Affected code: `rust/netprobe` (startup capture planning, AddonService
  `Health`), `go/pkg/agent/netprobe/attach_manager.go`,
  `go/pkg/agent/push_loop_addons.go`, `go/pkg/agent/push_loop_capabilities.go`,
  `go/pkg/agent/addon_systemd.go`, `addons/netprobe/serviceradar-netprobe.service`,
  `elixir/serviceradar_core/lib/serviceradar/plugins/addon_status_ingestor.ex`.
- No schema or wire-format change: `HealthResponse` already carries
  `STATUS_DEGRADED`, `degradation_reason` and `details`.
- Operators: a host assigned an absent interface keeps flow attribution, and its
  add-on row shows the misconfiguration. Clearing the degraded state still needs
  the operator to give that host a correct interface (or none).
