## Context
Agents advertise a flat list of capability strings in their hello and status
pushes. Core stores it on `Agent.capabilities`. Several capabilities are
already reported as an explicit pair: `addon.native.host` /
`addon.native.host.unavailable`, `sweep.banner_grab.available` /
`sweep.banner_grab.unavailable`. Web-NG already separates `*.unavailable`
markers from usable capabilities, and SRQL `in:agents` already filters on
`capabilities`.

The agent already withheld `icmp` and `mtr` when a socket probe failed, but
the probe used `mtr.NewRawSocket`, which on Linux falls back to unprivileged
datagram ICMP. The sweep ICMP scanner has no such fallback. Core ignored the
capability when compiling sweeps in any case.

## Decisions
- **Explicit negative marker, not absence.** Core treats an agent as ineligible
  only when it reports `icmp.unavailable` (or `mtr.unavailable`). An agent that
  reports neither predates the marker, and core keeps its current behavior for
  it. Treating a missing `icmp` as ineligible would stop ICMP for every older
  agent the moment core upgrades, because older agents whose probe failed
  omitted `icmp` but cannot be told apart from agents that never reported it.
  This follows `addon.native.host.unavailable`.
- **The ICMP probe is the sweep scanner's own socket setup.** `scan.ProbeICMPSockets`
  opens and closes the sockets `NewICMPSweeper` opens, through the same code.
  `icmp` is advertised when either address family works, because the scanner
  runs with whichever family it opened. Per-family state is logged at startup
  but not sent to core.
- **MTR keeps its own probe.** MTR is not raw-socket-only on Linux: it falls
  back to unprivileged ICMP when `net.ipv4.ping_group_range` allows it. So an
  agent can report `icmp.unavailable` and `mtr` together. On-demand MTR already
  requires the `mtr` capability at dispatch; this change gates the sweep `mtr`
  mode on `mtr.unavailable` the same way it gates `icmp`.
- **Probe once.** Socket permission is fixed for the life of the process, so
  the probe runs once and its result is reused by every capability report.
- **Filtering happens per agent at compile time.** The sweep config is already
  compiled and cached per agent, so dropping a mode there changes nothing for
  other agents of the same group. The modes are filtered before targets are
  built, so per-device `sweep_modes` match the group.

## Risks / Trade-offs
- A compiled config is cached for the ConfigCache TTL. An agent restarted with
  different socket permissions can keep its previous sweep config for up to
  that TTL. Socket permission changes only on a restart, so this was accepted
  rather than adding capability-driven cache invalidation.
- A group whose only selected agent is ineligible never runs on it. Core logs a
  warning at each compile for that agent, and the existing missed-sweep monitor
  still reports that the group is not producing results.
- Run-now and ad-hoc scans do not consult the marker yet: run-now dispatches a
  group id the agent may not have, and the agent reports that failure.

## Migration Plan
None. Older agents keep every mode; upgraded agents report the marker on their
next hello.
