## Context

`capture_interfaces` is an optional allowlist in the netprobe package config
(`addons/netprobe/config.schema.json`): empty means no packet capture, and eBPF
flow attribution still runs. Operators set it on add-on profiles, which target
agents by SRQL query, so one value fans out to every matching host. Names differ
between hosts (a VM's `ens18` against a hypervisor's bridges and bonds), so a
fleet-wide value is wrong on some hosts by construction.

netprobe is a systemd-supervised add-on. The agent attaches to it over a unix
socket (legacy IPC plus the generic AddonService on `addon.sock`), and reports
its state as an `addon:netprobe` sidecar status that core stores in
`platform.addon_statuses`.

## Goals / Non-Goals

- Goals: an absent interface never crashes netprobe or loses attribution; the
  operator sees which interface is absent and which exist; a deterministic
  crash loop of any systemd add-on is bounded and visible.
- Non-Goals: choosing an interface automatically. Auto-selecting the
  default-route interface would change the meaning of an empty list, and
  netprobe already refuses AF_XDP on that interface because a redirect would
  cut the host off. Host-agnostic tokens (for example `default-route`) are a
  possible later change.

## Decisions

- **Resolve at startup, against the host's interface list.** netprobe lists the
  host's interfaces once (`/sys/class/net` on Linux) and splits the configured
  list into present and absent. Capture handles, the interface allowlist map
  and the TC/XDP/AF_XDP attachment use only the present names. Hot-plug is not
  handled in-process: capture interfaces are already startup-only, and a
  restart (any assignment change, or the operator restarting the unit) picks up
  an interface that appears later.
- **Degraded, not unhealthy.** netprobe is running and doing its main job, so
  `Health` answers `DEGRADED`, matching the generic add-on runner, which keeps
  degraded distinct from unhealthy so a host-side gap does not fail a rollout.
  The prose reason is for the operator. `details` carries
  `capture_interfaces.missing`, `capture_interfaces.active` and
  `capture_interfaces.available` (comma-separated, bounded) for anything that
  needs to read it. The available list excludes loopback and is capped, with a
  count of the omitted names.
- **Requested list is the startup identity.** The pushed config still names the
  absent interface, so `restart_required` and `RuntimeConfig::apply` compare
  against the requested list. Comparing against the effective list would refuse
  every push and invite a restart loop driven from the agent.
- **The agent reads Health after liveness.** The legacy IPC `Ping` still decides
  reachability. When it succeeds, the attach manager asks AddonService `Health`.
  `DEGRADED` becomes sidecar state `degraded` with the reason as `last_error`.
  An unreachable or older AddonService leaves the state `running`; it is not an
  error, because an older netprobe does not serve it.
- **The unit state outranks the IPC state when the process is down.** When the
  systemd unit is not running, its state (`circuit_open`, `unhealthy` with the
  exit status) is reported instead of the IPC dial failure, which is only a
  symptom of the dead process.
- **Bounded restarts, with an agent-side circuit.** The unit sets
  `StartLimitIntervalSec=300` and `StartLimitBurst=5` (five starts at the 5 s
  restart delay, then systemd stops). The agent maps
  `ActiveState=failed, Result=start-limit-hit` to `circuit_open`, and its
  reconcile does not reinstall an unchanged assignment whose unit is in that
  state. Activation runs `systemctl reset-failed` on the primary unit before
  `enable --now` / `restart`, so a changed assignment always gets a fresh start
  budget.
- **Core counts degraded as active.** `AddonStatusIngestor` set
  `active: state == "running"`, so any degraded add-on read as not running and
  `AddonRolloutArtifact.supervision_state_ready?/2`, which already accepts
  `degraded`, could never be satisfied for it.

## Risks / Trade-offs

- `/sys/class/net` reflects the network namespace sysfs was mounted in. For the
  systemd unit that is the host namespace, which is the namespace capture opens
  in. If the listing cannot be read, netprobe keeps the previous behaviour and
  lets the open fail, rather than guessing.
- An operator who restarts the unit by hand after a start-limit stop gets one
  more burst of five attempts. That is intended.

## Follow-up: assignment-time check in core

The agent reports `host_interfaces` in its gateway hello, but core uses them
only transiently for identity and does not persist the names. The follow-up
persists the latest interface names per agent and has add-on profile reconcile
record, per target agent, any configured capture interface absent from that
list, so the profile and assignment views show it before netprobe ever starts.
