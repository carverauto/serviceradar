## ADDED Requirements

### Requirement: Host-network-visibility capability is registered and queryable

The agent registry SHALL recognise `host-network-visibility` as a
first-class entry in the agent capability vocabulary. Agents whose
supervised `netprobe` sidecar is registered and healthy MUST advertise
the capability as `enabled`; agents whose sidecar is unable to load
eBPF programs (older kernels, verifier rejection) MUST advertise it as
`degraded`; agents on platforms without the sidecar binary, with the
sidecar circuit-broken, or whose capture-interface allowlist is empty
MUST advertise it as `unavailable`. The capability MUST be addressable
via SRQL agent queries (e.g.
`in:agents capabilities:host-network-visibility`).

#### Scenario: SRQL query returns agents with the capability
- **WHEN** an operator runs
  `in:agents capabilities:host-network-visibility`
- **THEN** the result set contains every agent whose registry record
  advertises `host-network-visibility` as `enabled` or `degraded`

#### Scenario: Degraded vs enabled distinction is preserved
- **WHEN** an operator runs
  `in:agents capabilities:host-network-visibility=enabled`
- **THEN** the result set excludes agents currently in `degraded` state

### Requirement: Sidecar runtime metadata surfaced on agent records

The agent registry SHALL persist the sidecar runtime metadata reported
in the agent status response (per `agent-sidecar-runtime`) so the Agent
Detail UI and operators using SRQL can inspect sidecar state without
contacting the agent directly. At minimum, the registry MUST surface
the netprobe sidecar's `state`, `restart_count`, `last_health_at`,
`last_error`, and the kernel `flow_attribution_available` indicator.

#### Scenario: Agent detail page reflects netprobe state
- **WHEN** the Agent Detail UI loads an agent that runs netprobe
- **THEN** the page renders the sidecar's current state, restart count,
  last health timestamp, last error (if any), and the kernel BPF
  support indicator using fields sourced from the agent registry
